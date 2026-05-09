import 'dart:io';

import 'package:chat_transcribe_shorten/transcribe.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class TranscribePage extends StatefulWidget {
  const TranscribePage({super.key, required this.filePath, required this.onTranscriptionComplete, required this.audioJumpTo});

  final String filePath;
  final Function(String) onTranscriptionComplete;
  final Function(int) audioJumpTo;

  @override
  State<TranscribePage> createState() => _TranscribePageState();
}

class _TranscribePageState extends State<TranscribePage> {
  List<Segment> segments = [];
  bool loading = false;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      loading = true;
      segments = [
        for (int i = 0; i < 20; i++)
          Segment(
            text: 'Das ist ein Testsegment.',
            fromTs: Duration(seconds: i),
            toTs: Duration(seconds: i + 1),
          ),
      ];
    } else {
      transcribe();
    }
  }

  void transcribe() async {
    setState(() {
      segments = [];
      loading = true;
    });

    String? convertedPath;

    try {
      // Ensure model files are extracted to temp dir before spawning isolate.
      await getSherpaRecognizer();

      // Convert input to 16 kHz mono PCM WAV — still needed for arbitrary formats.
      final tempDir = await getTemporaryDirectory();
      convertedPath = '${tempDir.path}/converted_audio.wav';

      final convertSession = await FFmpegKit.execute('-y -i "${widget.filePath}" -ar 16000 -ac 1 -sample_fmt s16 -c:a pcm_s16le "$convertedPath"');
      if (!ReturnCode.isSuccess(await convertSession.getReturnCode())) {
        throw Exception('FFmpeg conversion failed');
      }

      // Stream segments as they arrive from the isolate.
      await for (final seg in transcribeStream(convertedPath)) {
        if (!mounted) break;
        setState(() => segments.add(seg));
      }

      if (mounted) {
        setState(() => loading = false);
        widget.onTranscriptionComplete(segments.map((s) => s.text).join(' '));
      }
    } catch (e, st) {
      if (kDebugMode) {
        print('Error during transcription: $e');
        print('Stack trace: $st');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error during transcription: $e')));
        setState(() {
          segments = [];
          loading = false;
        });
      }
    } finally {
      // Clean up the converted WAV.
      if (convertedPath != null) {
        final f = File(convertedPath);
        if (await f.exists()) await f.delete();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Card(
      color: Color.alphaBlend(Theme.of(context).colorScheme.surfaceTint.withOpacity(0.05), Theme.of(context).colorScheme.surface),
      surfaceTintColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SelectionArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: size.width, minHeight: size.height * 0.2, maxWidth: size.width),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: Wrap(
                        children: segments.map((seg) {
                          return TapRegion(
                            onTapInside: (_) => widget.audioJumpTo(seg.fromTs.inMilliseconds),
                            child: Text('${seg.text} ', style: Theme.of(context).textTheme.bodyLarge),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  if (loading) const Center(child: CupertinoActivityIndicator()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
