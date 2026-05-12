import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
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

// ─── Isolate message types ────────────────────────────────────────────────────

class _TranscribeRequest {
  final String filePath;
  final String modelDirPath;
  final SendPort sendPort;
  final bool streaming; // true → OnlineRecognizer, false → VAD + OfflineRecognizer

  const _TranscribeRequest(this.filePath, this.modelDirPath, this.sendPort, this.streaming);
}

// ─── Public API ──────────────────────────────────────────────────────────────

Stream<Segment> transcribeStream(String wavPath, String modelDirPath, {bool streaming = true}) async* {
  assert(
  streaming || await File('$modelDirPath/silero_vad.onnx').exists(),
  'Offline mode requires silero_vad.onnx in modelDirPath',
  );
  final receivePort = ReceivePort();
  final isolate = await Isolate.spawn(
    _transcribeIsolateEntry,
    _TranscribeRequest(wavPath, modelDirPath, receivePort.sendPort, streaming),
    errorsAreFatal: true,
  );
  await for (final msg in receivePort) {
    if (msg == null) break;
    yield msg as Segment;
  }
  receivePort.close();
  isolate.kill();
}

// ─── Isolate entry point ─────────────────────────────────────────────────────

void _transcribeIsolateEntry(_TranscribeRequest req) async {
  sherpa_onnx.initBindings();

  final bytes = await File(req.filePath).readAsBytes();
  final samples = _convertBytesToFloat32(bytes);

  if (req.streaming) {
    await _runOnline(req, samples);
  } else {
    await _runOfflineWithVad(req, samples);
  }

  req.sendPort.send(null); // sentinel: done
}

// ─── Online (streaming) path ──────────────────────────────────────────────────

Future<void> _runOnline(_TranscribeRequest req, Float32List samples) async {
  String p(String name) => '${req.modelDirPath}/$name';

  final config = sherpa_onnx.OnlineRecognizerConfig(
    model: sherpa_onnx.OnlineModelConfig(
      transducer: sherpa_onnx.OnlineTransducerModelConfig(
        encoder: p('encoder.onnx'),
        decoder: p('decoder.onnx'),
        joiner:  p('joiner.onnx'),
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

  final recognizer = sherpa_onnx.OnlineRecognizer(config);
  const int sampleRate = 16000;
  const int chunkSize = sampleRate ~/ 10; // 100 ms

  final stream = recognizer.createStream();
  String prevText = '';
  double chunkStartSec = 0.0;

  for (int offset = 0; offset < samples.length; offset += chunkSize) {
    final end = (offset + chunkSize).clamp(0, samples.length);
    final chunk = samples.sublist(offset, end);

    stream.acceptWaveform(samples: chunk, sampleRate: sampleRate);
    while (recognizer.isReady(stream)) recognizer.decode(stream);

    if (recognizer.isEndpoint(stream)) {
      final text = recognizer.getResult(stream).text.trim();
      if (text.isNotEmpty && text != prevText) {
        req.sendPort.send(Segment(
          text: text,
          fromTs: Duration(milliseconds: (chunkStartSec * 1000).round()),
          toTs: Duration(milliseconds: ((offset + chunk.length) / sampleRate * 1000).round()),
        ));
        prevText = text;
      }
      recognizer.reset(stream);
      chunkStartSec = (offset + chunk.length) / sampleRate;
    }
  }

  // Flush tail.
  stream.inputFinished();
  while (recognizer.isReady(stream)) recognizer.decode(stream);
  final finalText = recognizer.getResult(stream).text.trim();
  if (finalText.isNotEmpty && finalText != prevText) {
    req.sendPort.send(Segment(
      text: finalText,
      fromTs: Duration(milliseconds: (chunkStartSec * 1000).round()),
      toTs: Duration(milliseconds: (samples.length / 16000 * 1000).round()),
    ));
  }

  stream.free();
  recognizer.free();
}

// ─── Offline + VAD path ───────────────────────────────────────────────────────

Future<void> _runOfflineWithVad(_TranscribeRequest req, Float32List samples) async {
  String p(String name) => '${req.modelDirPath}/$name';
  const int sampleRate = 16000;

  // VAD
  final vadConfig = sherpa_onnx.VadModelConfig(
    sileroVad: sherpa_onnx.SileroVadModelConfig(
      model: p('silero_vad.onnx'),
      threshold: 0.5,
      minSpeechDuration: 0.25,
      minSilenceDuration: 0.5,
    ),
    sampleRate: sampleRate,
    numThreads: 2,
  );
  final vad = sherpa_onnx.VoiceActivityDetector(config: vadConfig, bufferSizeInSeconds: 60);

  // Offline recognizer (transducer — swap model block for Whisper/Paraformer as needed)
  final asrConfig = sherpa_onnx.OfflineRecognizerConfig(
    model: sherpa_onnx.OfflineModelConfig(
      transducer: sherpa_onnx.OfflineTransducerModelConfig(
        encoder: p('encoder.onnx'),
        decoder: p('decoder.onnx'),
        joiner:  p('joiner.onnx'),
      ),
      tokens: p('tokens.txt'),
      numThreads: 2,
    ),
    decodingMethod: 'greedy_search',
  );
  final recognizer = sherpa_onnx.OfflineRecognizer(asrConfig);

  final windowSize = vadConfig.sileroVad.windowSize; // samples per VAD step (e.g. 512)

  for (int offset = 0; offset < samples.length; offset += windowSize) {
    final end = (offset + windowSize).clamp(0, samples.length);
    vad.acceptWaveform(samples.sublist(offset, end));

    while (!vad.isEmpty()) {
      final seg = vad.front(); // SpeechSegment { samples, start }
      vad.pop();

      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: seg.samples, sampleRate: sampleRate);
      recognizer.decode(stream);

      final text = recognizer.getResult(stream).text.trim();
      if (text.isNotEmpty) {
        final fromMs = (seg.start / sampleRate * 1000).round();
        final toMs = ((seg.start + seg.samples.length) / sampleRate * 1000).round();
        req.sendPort.send(Segment(
          text: text,
          fromTs: Duration(milliseconds: fromMs),
          toTs: Duration(milliseconds: toMs),
        ));
      }
      stream.free();
    }
  }

  // Flush any trailing speech the VAD hasn't emitted yet.
  vad.flush();
  while (!vad.isEmpty()) {
    final seg = vad.front();
    vad.pop();

    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: seg.samples, sampleRate: sampleRate);
    recognizer.decode(stream);

    final text = recognizer.getResult(stream).text.trim();
    if (text.isNotEmpty) {
      final fromMs = (seg.start / sampleRate * 1000).round();
      final toMs = ((seg.start + seg.samples.length) / sampleRate * 1000).round();
      req.sendPort.send(Segment(
        text: text,
        fromTs: Duration(milliseconds: fromMs),
        toTs: Duration(milliseconds: toMs),
      ));
    }
    stream.free();
  }

  vad.free();
  recognizer.free();
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

Float32List _convertBytesToFloat32(Uint8List bytes, [Endian endian = Endian.little]) {
  final values = Float32List(bytes.length ~/ 2);
  final data = ByteData.view(bytes.buffer);
  for (var i = 0; i < bytes.length; i += 2) {
    values[i ~/ 2] = data.getInt16(i, endian) / 32768.0;
  }
  return values;
}