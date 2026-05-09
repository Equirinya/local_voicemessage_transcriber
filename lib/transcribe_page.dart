import 'dart:io';

import 'package:chat_transcribe_shorten/transcribe.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
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
    if(kDebugMode){
      //testData
      loading = true;
      segments = [
        for(int i = 0; i < 200; i++) Segment(text: "This is a test segment.", fromTs: Duration(seconds: i), toTs: Duration(seconds: i+1)),
      ];
    }
    else transcribe();
    super.initState();
  }

  void transcribe({String lang = 'auto'}) async {

    setState(() {
      segments = [];
      loading = true;
    });

    try {

      var recognizer = await getSherpaRecognizer();

      // --- Step 1: Convert to 16 kHz, mono, PCM 16-bit WAV ---
      final tempDir = await getTemporaryDirectory();
      final convertedPath = '${tempDir.path}/converted_audio.wav';

      final convertSession = await FFmpegKit.execute(
        '-y -i "${widget.filePath}" -ar 16000 -ac 1 -sample_fmt s16 -c:a pcm_s16le "$convertedPath"',
      );
      if (!ReturnCode.isSuccess(await convertSession.getReturnCode())) {
        throw Exception('FFmpeg conversion failed');
      }

      // --- Step 2: Get total duration ---
      final probeSession = await FFprobeKit.getMediaInformation(convertedPath);
      final durationSeconds =
          double.tryParse(probeSession.getMediaInformation()?.getDuration() ?? '0') ?? 0.0;

      // --- Step 3: Chunked transcription loop ---
      double chunkStart = 0.0;
      const double chunkDuration = 30.0;
      int chunkIndex = 0;

      while (chunkStart < durationSeconds) {
        final chunkPath = '${tempDir.path}/chunk_$chunkIndex.wav';

        final extractSession = await FFmpegKit.execute(
          '-y -ss $chunkStart -t $chunkDuration -i "$convertedPath"'
              ' -ar 16000 -ac 1 -sample_fmt s16 -c:a pcm_s16le "$chunkPath"',
        );
        if (!ReturnCode.isSuccess(await extractSession.getReturnCode())) {
          throw Exception('FFmpeg chunk extraction failed at chunk $chunkIndex');
        }

        final newSegments = await compute(transcribeFile,(chunkPath,recognizer));
        if (newSegments.isEmpty) break;

        // --- Find the last sentence-ending segment index ---
        int? lastSentenceIndex;
        for (int i = newSegments.length - 1; i >= 0; i--) {
          final text = newSegments[i].text.trim();
          if (text.endsWith('.') || text.endsWith('!') || text.endsWith('?')) {
            lastSentenceIndex = i;
            break;
          }
        }

        // If no sentence boundary found, take all but the last segment (may be cut off)
        // and advance by full chunk duration as fallback.
        final int cutoff = lastSentenceIndex ?? (newSegments.length - 1);
        final segmentsToAdd = newSegments.sublist(0, cutoff + 1);

        // Offset timestamps back to absolute time and append
        for (final seg in segmentsToAdd) {
          segments.add(seg.copyWith(
            fromTs: Duration(milliseconds: (seg.fromTs.inMilliseconds + (chunkStart * 1000).round())),
            toTs:   Duration(milliseconds: (seg.toTs.inMilliseconds   + (chunkStart * 1000).round())),
          ));
        }

        setState(() {});

        // --- Advance chunkStart to the absolute end of the last accepted sentence ---
        if (lastSentenceIndex == null) {
          // No clean boundary — skip ahead by full chunk to avoid infinite loop
          chunkStart += chunkDuration;
        } else {
          final lastSegRelativeEndSec =
              newSegments[lastSentenceIndex].toTs.inMilliseconds / 1000.0;
          chunkStart = chunkStart + lastSegRelativeEndSec;
        }

        chunkIndex++;

        final chunkFile = File(chunkPath);
        if (await chunkFile.exists()) await chunkFile.delete();
      }


      final convertedFile = File(convertedPath);
      if (await convertedFile.exists()) await convertedFile.delete();

      setState(() => loading = false);
      widget.onTranscriptionComplete(segments.map((s) => s.text).join(' '));
    } catch (e, st) {
      if (kDebugMode) print("Error during transcription: $e");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Error during transcription: $e"),
      ));
      print("Error during transcription: $e");
      print("Stack trace: $st");
      setState(() {
        segments = [];
        loading = false;
      });
    }
  }


  @override
  Widget build(BuildContext context) {
    var size = MediaQuery.of(context).size;
    return Card(
      color: Color.alphaBlend(
        Theme.of(context).colorScheme.surfaceTint.withOpacity(0.05),
        Theme.of(context).colorScheme.surface,
      ),
      surfaceTintColor: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SelectionArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: size.width, minHeight: size.height*0.2, maxWidth: size.width),
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
                            child: Text(
                              '${seg.text} ',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  if(loading) Center(
                    child: CupertinoActivityIndicator(),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
