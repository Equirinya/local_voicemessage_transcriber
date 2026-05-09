import 'dart:io';
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

  Segment copyWith({
    String? text,
    Duration? fromTs,
    Duration? toTs,
  }) {
    return Segment(
      text:   text   ?? this.text,
      fromTs: fromTs ?? this.fromTs,
      toTs:   toTs   ?? this.toTs,
    );
  }
}

// ─── Recognizer helper ───────────────────────────────────────────────────────

/// Call once and cache the result — initializing Whisper is expensive.
sherpa_onnx.OfflineRecognizer? _sherpaRecognizer;

Future<sherpa_onnx.OfflineRecognizer> getSherpaRecognizer() async {
  if (_sherpaRecognizer != null) return _sherpaRecognizer!;

  // Model files must be placed in assets/sherpa-onnx-whisper-small/
  // and declared in pubspec.yaml. Download from:
  // https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models
  // File: sherpa-onnx-whisper-small.tar.bz2
  Future<String> assetPath(String rel) async {
    final data = await rootBundle.load(rel);
    final bytes = data.buffer.asUint8List();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$rel');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file.path;
  }

  const modelDir = 'assets/sherpa-onnx-whisper-small';
  final encoder = await assetPath('$modelDir/small-encoder.int8.onnx');
  final decoder = await assetPath('$modelDir/small-decoder.int8.onnx');
  final tokens  = await assetPath('$modelDir/small-tokens.txt');

  final config = sherpa_onnx.OfflineRecognizerConfig(
    model: sherpa_onnx.OfflineModelConfig(
      whisper: sherpa_onnx.OfflineWhisperModelConfig(
        encoder: encoder,
        decoder: decoder,
        language: '',   // empty = multilingual auto-detect
        task: 'transcribe',
      ),
      tokens: tokens,
      modelType: 'whisper',
      numThreads: 2,
    ),
    decodingMethod: 'greedy_search',
  );

  _sherpaRecognizer = sherpa_onnx.OfflineRecognizer(config);
  return _sherpaRecognizer!;
}

// ─── Transcribe one WAV chunk via sherpa-onnx ────────────────────────────────

Future<List<Segment>> transcribeFile((String filePath, sherpa_onnx.OfflineRecognizer recognizer) input) async {

  var filePath = input.$1;
  var recognizer = input.$2;

  sherpa_onnx.initBindings();

  final bytes = await File(filePath).readAsBytes();

  final samples = convertBytesToFloat32(bytes);

  final stream = recognizer.createStream();
  stream.acceptWaveform(samples: samples, sampleRate: 16000);
  recognizer.decode(stream);
  final result = recognizer.getResult(stream);
  stream.free();

  if (result.text.trim().isEmpty) return [];

  // sherpa-onnx Whisper returns per-token timestamps in result.timestamps.
  // We reconstruct word-level segments from them; when unavailable we fall
  // back to a single segment covering the whole chunk.
  if (result.timestamps.isNotEmpty &&
      result.timestamps.length == result.tokens.length) {
    final segments = <Segment>[];
    final buffer = StringBuffer();
    double segStart = result.timestamps.first.toDouble();
    double segEnd   = segStart;

    for (int i = 0; i < result.tokens.length; i++) {
      final token = result.tokens[i];
      final t     = result.timestamps[i].toDouble();
      buffer.write(token);
      segEnd = t;

      final text = buffer.toString().trim();
      if (text.endsWith('.') || text.endsWith('!') || text.endsWith('?')) {
        segments.add(Segment(
          text:   text,
          fromTs: Duration(milliseconds: (segStart * 1000).round()),
          toTs:   Duration(milliseconds: (segEnd   * 1000).round()),
        ));
        buffer.clear();
        if (i + 1 < result.timestamps.length) {
          segStart = result.timestamps[i + 1].toDouble();
        }
      }
    }

    // Remaining text without a terminal punctuation becomes the last segment
    if (buffer.isNotEmpty) {
      segments.add(Segment(
        text:   buffer.toString().trim(),
        fromTs: Duration(milliseconds: (segStart * 1000).round()),
        toTs:   Duration(milliseconds: (segEnd   * 1000).round()),
      ));
    }

    return segments;
  }

  // Fallback: single segment
  return [
    Segment(
      text:   result.text.trim(),
      fromTs: Duration.zero,
      toTs:   Duration(seconds: samples.length ~/ 16000),
    ),
  ];
}

Float32List convertBytesToFloat32(Uint8List bytes, [endian = Endian.little]) {
  final values = Float32List(bytes.length ~/ 2);

  final data = ByteData.view(bytes.buffer);

  for (var i = 0; i < bytes.length; i += 2) {
    int short = data.getInt16(i, endian);
    values[i ~/ 2] = short / 32768.0;
  }

  return values;
}
