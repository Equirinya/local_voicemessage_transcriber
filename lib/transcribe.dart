import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

// ─── Segment model ───────────────────────────────────────────────────────────

class Segment {
  final String text;
  final Duration fromTs;
  final Duration toTs;

  const Segment({required this.text, required this.fromTs, required this.toTs});

  Segment copyWith({String? text, Duration? fromTs, Duration? toTs}) =>
      Segment(text: text ?? this.text, fromTs: fromTs ?? this.fromTs, toTs: toTs ?? this.toTs);
}

// ─── Recognizer helper (main isolate only) ────────────────────────────────────

sherpa_onnx.OnlineRecognizer? _sherpaRecognizer;

Future<sherpa_onnx.OnlineRecognizer> getSherpaRecognizer() async {
  if (_sherpaRecognizer != null) return _sherpaRecognizer!;

  Future<String> assetPath(String rel) async {
    final data = await rootBundle.load(rel);
    final bytes = data.buffer.asUint8List();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$rel');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file.path;
  }

  const modelDir = 'assets/kroko-de-fp32';
  final encoder = await assetPath('$modelDir/encoder.onnx');
  final decoder = await assetPath('$modelDir/decoder.onnx');
  final joiner = await assetPath('$modelDir/joiner.onnx');
  final tokens = await assetPath('$modelDir/tokens.txt');

  final config = sherpa_onnx.OnlineRecognizerConfig(
    model: sherpa_onnx.OnlineModelConfig(
      transducer: sherpa_onnx.OnlineTransducerModelConfig(encoder: encoder, decoder: decoder, joiner: joiner),
      tokens: tokens,
      numThreads: 2,
      modelType: 'zipformer2',
    ),
    decodingMethod: 'greedy_search',
    enableEndpoint: true,
    rule1MinTrailingSilence: 1.5,
    rule2MinTrailingSilence: 1.2,
    rule3MinUtteranceLength: 90.0,
  );

  _sherpaRecognizer = sherpa_onnx.OnlineRecognizer(config);
  return _sherpaRecognizer!;
}

// ─── Isolate message types ────────────────────────────────────────────────────

class _TranscribeRequest {
  final String filePath;
  final String tempDirPath; // ← resolved on the main isolate, passed in
  final SendPort sendPort;

  const _TranscribeRequest(this.filePath, this.tempDirPath, this.sendPort);
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Streams [Segment]s as they are recognised. Runs decode in a separate
/// isolate so the UI stays responsive.
Stream<Segment> transcribeStream(String wavPath) async* {
  // Resolve the temp dir HERE on the main isolate before spawning.
  final tempDir = await getTemporaryDirectory();

  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(_transcribeIsolateEntry, _TranscribeRequest(wavPath, tempDir.path, receivePort.sendPort), errorsAreFatal: true);

  await for (final msg in receivePort) {
    if (msg == null) break; // null sentinel = done
    yield msg as Segment;
  }

  receivePort.close();
  isolate.kill();
}

// ─── Isolate entry point ─────────────────────────────────────────────────────

void _transcribeIsolateEntry(_TranscribeRequest req) async {
  sherpa_onnx.initBindings();

  // Use the temp dir path passed from the main isolate — no platform channels.
  final recognizer = _createRecognizerInIsolate(req.tempDirPath);

  final bytes = await File(req.filePath).readAsBytes();
  final samples = _convertBytesToFloat32(bytes);

  const int sampleRate = 16000;
  const int chunkSize = sampleRate ~/ 10; // 100 ms per step

  final stream = recognizer.createStream();
  String prevText = '';
  double chunkStartSec = 0.0;

  for (int offset = 0; offset < samples.length; offset += chunkSize) {
    final end = (offset + chunkSize).clamp(0, samples.length);
    final chunk = samples.sublist(offset, end);

    stream.acceptWaveform(samples: chunk, sampleRate: sampleRate);

    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }

    if (recognizer.isEndpoint(stream)) {
      final result = recognizer.getResult(stream);
      final text = result.text.trim();

      if (text.isNotEmpty && text != prevText) {
        final fromMs = (chunkStartSec * 1000).round();
        final toMs = ((offset + chunk.length) / sampleRate * 1000).round();
        req.sendPort.send(
          Segment(
            text: text,
            fromTs: Duration(milliseconds: fromMs),
            toTs: Duration(milliseconds: toMs),
          ),
        );
        prevText = text;
      }

      recognizer.reset(stream);
      chunkStartSec = (offset + chunk.length) / sampleRate;
    }
  }

  // Flush remaining hypothesis after end-of-audio.
  stream.inputFinished();
  while (recognizer.isReady(stream)) {
    recognizer.decode(stream);
  }
  final finalResult = recognizer.getResult(stream);
  final finalText = finalResult.text.trim();
  if (finalText.isNotEmpty && finalText != prevText) {
    final fromMs = (chunkStartSec * 1000).round();
    final toMs = (samples.length / sampleRate * 1000).round();
    req.sendPort.send(
      Segment(
        text: finalText,
        fromTs: Duration(milliseconds: fromMs),
        toTs: Duration(milliseconds: toMs),
      ),
    );
  }

  stream.free();
  req.sendPort.send(null); // sentinel: done
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Creates the recognizer using only the pre-resolved [tempDirPath].
/// No platform channels used — safe to call inside an isolate.
sherpa_onnx.OnlineRecognizer _createRecognizerInIsolate(String tempDirPath) {
  const modelDir = 'assets/kroko-de-fp32';

  String p(String name) => '$tempDirPath/$modelDir/$name';

  final config = sherpa_onnx.OnlineRecognizerConfig(
    model: sherpa_onnx.OnlineModelConfig(
      transducer: sherpa_onnx.OnlineTransducerModelConfig(
        encoder: p('encoder.onnx'),
        decoder: p('decoder.onnx'),
        joiner: p('joiner.onnx'),
      ),
      tokens: p('tokens.txt'),
      numThreads: 2,
      modelType: 'zipformer2',
    ),
    decodingMethod: 'greedy_search',
    enableEndpoint: true,
    rule1MinTrailingSilence: 1.5,
    rule2MinTrailingSilence: 1.2,
    rule3MinUtteranceLength: 90.0,
  );

  return sherpa_onnx.OnlineRecognizer(config);
}

Float32List _convertBytesToFloat32(Uint8List bytes, [Endian endian = Endian.little]) {
  final values = Float32List(bytes.length ~/ 2);
  final data = ByteData.view(bytes.buffer);
  for (var i = 0; i < bytes.length; i += 2) {
    values[i ~/ 2] = data.getInt16(i, endian) / 32768.0;
  }
  return values;
}
