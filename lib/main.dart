import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:chat_transcribe_shorten/settings_page.dart';
import 'package:chat_transcribe_shorten/transcribe_page.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:system_theme/system_theme.dart';
import 'package:file_picker/file_picker.dart';

import 'model_manager.dart';
import 'model_settings.dart';

// also include file picker on app start
// also for web and then include links to appstore playstore and neostore

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sherpa_onnx.initBindings();
  SystemTheme.fallbackColor = Colors.teal;
  await SystemTheme.accentColor.load();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: SystemTheme.accentColor.accent)),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: SystemTheme.accentColor.dark, brightness: Brightness.dark),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late StreamSubscription _intentDataStreamSubscription;

  bool initialized = false;

  String? filePath;
  String? transcription;
  String? shortened;
  String? summary;

  int page = 0;
  int selectedText = 0;

  PlayerWaveStyle waveStyle = PlayerWaveStyle(scaleFactor: 120);
  PlayerController playerController = PlayerController();
  late StreamSubscription<PlayerState> playerStateSubscription;
  late StreamSubscription<int> playerDurationSubscription;
  Duration playerTime = Duration.zero;
  double playerRate = 1.0;

  @override
  void initState() {
    super.initState();
    asyncInit();
  }

  dispose() {
    super.dispose();
    _intentDataStreamSubscription.cancel();
    playerStateSubscription.cancel();
    playerDurationSubscription.cancel();
  }

  void asyncInit() async {
    final active = await ModelManager.getActiveModel();
    if (active == null) {
      await ModelDownloadDialog.show(context);
    }

    // For sharing images coming from outside the app while the app is in the memory
    _intentDataStreamSubscription = FlutterSharingIntent.instance.getMediaStream().listen(
      (value) {
        newFile(value.firstOrNull?.value);
        if (kDebugMode || true) {
          print("Shared: getMediaStream ${value.map((f) => f.value).join(",")}");
        }
      },
      onError: (err) {
        if (kDebugMode || true) {
          print("getIntentDataStream error: $err");
        }
      },
    );

    // For sharing images coming from outside the app while the app is closed
    FlutterSharingIntent.instance.getInitialSharing().then((value) {
      if (kDebugMode || true) {
        print("Shared: getInitialMedia ${value.map((f) => f.value).join(",")}");
      }
      newFile(value.firstOrNull?.value);
    });

    playerStateSubscription = playerController.onPlayerStateChanged.listen((playerState) async {
      setState(() {});
      playerTime = Duration(milliseconds: await playerController.getDuration(playerState.isPlaying ? DurationType.current : DurationType.max));
    });
    playerDurationSubscription = playerController.onCurrentDurationChanged.listen((ms) async {
      setState(() {
        playerTime = Duration(milliseconds: ms);
      });
    });

    setState(() {
      initialized = true;
    });
  }

  void reset() async {
    setState(() {
      filePath = null;
      transcription = null;
      shortened = null;
      summary = null;
      selectedText = 0;
    });
  }

  Future<void> newFile(String? path) async {
    if (path == null) return;
    playerController.preparePlayer(
      path: path,
      shouldExtractWaveform: true,
      noOfSamples: waveStyle.getSamplesForWidth(MediaQuery.of(context).size.width * 0.5),
    );
    setState(() {
      reset();
      filePath = path;
    });
  }

  void shorten() async {
    if (transcription == null || transcription!.isEmpty) {
      setState(() {
        shortened = null;
      });
      return;
    }

    setState(() {
      shortened = "";
    });

    setState(() {});
  }

  void summarize() async {
    if (transcription == null || transcription!.isEmpty) {
      setState(() {
        summary = null;
      });
      return;
    }
    setState(() {
      summary = "";
    });

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const Center(child: CupertinoActivityIndicator());
    return Scaffold(
      body: IndexedStack(
        index: page,
        children: [
          SafeArea(
            child: filePath != null
                ? Column(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: IntrinsicWidth(
                          child: Card(
                            color: Theme.of(context).colorScheme.tertiaryContainer,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    IconButton(
                                      onPressed: () async {
                                        playerController.playerState.isPlaying
                                            ? await playerController.pausePlayer()
                                            : await playerController.startPlayer();
                                        setState(() {});
                                      },
                                      icon: Icon(playerController.playerState.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                                    ),
                                    Expanded(
                                      child: AudioFileWaveforms(
                                        playerController: playerController,
                                        waveformType: WaveformType.fitWidth,
                                        animationDuration: const Duration(milliseconds: 100),
                                        playerWaveStyle: waveStyle,
                                        enableSeekGesture: true,
                                        size: Size(MediaQuery.of(context).size.width * 0.9 - (4 * 48), MediaQuery.of(context).size.height * 0.05),
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () async {
                                        final current = await playerController.getDuration(DurationType.current);
                                        await playerController.seekTo(max(0, current - 10000));
                                      },
                                      icon: const Icon(Icons.replay_10_rounded),
                                    ),
                                    IconButton(
                                      onPressed: () async {
                                        final current = await playerController.getDuration(DurationType.current);
                                        await playerController.seekTo(current + 10000);
                                      },
                                      icon: const Icon(Icons.forward_10_rounded),
                                    ),
                                    //set Player rate to 1x, 1.5x, 2x
                                    IconButton(
                                      onPressed: () async {
                                        playerRate = playerRate == 1.0
                                            ? 1.5
                                            : playerRate == 1.5
                                            ? 2.0
                                            : 1.0;
                                        await playerController.setRate(playerRate);
                                        setState(() {});
                                      },
                                      icon: Text("${playerRate}x", style: Theme.of(context).textTheme.labelSmall),
                                    ),
                                  ],
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        filePath!.split("/").last,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                      ),
                                      Text(
                                        "${playerTime.inHours > 0 ? "${playerTime.inHours}:" : ""}${playerTime.inMinutes.remainder(60).toString().padLeft(2, "0")}:${playerTime.inSeconds.remainder(60).toString().padLeft(2, "0")}",
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // SegmentedButton(
                      //   multiSelectionEnabled: false,
                      //   segments: const <ButtonSegment<int>>[
                      //     ButtonSegment(
                      //       value: 0,
                      //       icon: Icon(Icons.transcribe),
                      //       label: Text("Transcript"),
                      //     ),
                      //     ButtonSegment(
                      //       value: 1,
                      //       icon: Icon(Icons.short_text),
                      //       label: Text("Shortened"),
                      //     ),
                      //     ButtonSegment(
                      //       value: 2,
                      //       icon: Icon(Icons.summarize),
                      //       label: Text("Summary"),
                      //     ),
                      //   ],
                      //   selected: <int>{selectedText},
                      //   onSelectionChanged: (Set<int> newSelection) {
                      //     setState(() {
                      //       selectedText = newSelection.first;
                      //     });
                      //     if (selectedText >= 1 && [transcription, shortened, summary][selectedText] == null) [transcribe, shorten, summarize][selectedText]();
                      //   },
                      // ),
                      Expanded(
                        child: TranscribePage(
                          key: ValueKey(filePath),
                          filePath: filePath!,
                          onTranscriptionComplete: (text) {
                            setState(() {
                              transcription = text;
                            });
                          },
                          audioJumpTo: (int ms) async {
                            await playerController.seekTo(ms);
                          },
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Center(
                        child: SizedBox(
                          width: MediaQuery.of(context).size.width * 0.6,
                          child: Text("Share a voice message to get started or select from your files:", textAlign: TextAlign.center,),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () async {
                          final result = await FilePicker.pickFiles(type: FileType.audio, allowMultiple: false);

                          if (result != null && result.files.single.path != null) {
                            setState(() {
                              filePath = result.files.single.path;
                            });
                          }
                        },
                        icon: const Icon(Icons.audio_file),
                        label: const Text("Select File"),
                      ),
                    ],
                  ),
          ),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: page,
        onTap: (index) {
          setState(() {
            page = index;
          });
        },
        showSelectedLabels: false,
        showUnselectedLabels: false,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: "Home"),
          BottomNavigationBarItem(icon: Icon(Icons.settings_rounded), label: "Settings"),
        ],
      ),
    );
  }
}
