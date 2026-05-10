import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'model_manager.dart';
import 'model_settings.dart';


Future<void> openSettings(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => const SettingsPage()));

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});


  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late SharedPreferences prefs;
  bool initialized = false;

  @override
  void initState() {
    () async {
      prefs = await SharedPreferences.getInstance();
      setState(() {
        initialized = true;
      });
    }
    ();
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const CupertinoActivityIndicator();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings"),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 128),
        children: [
          ModelSettingsPage(onSelectionChanged: (ModelDefinition? selected) {}),
          SettingsSubPageCategory(title: "About", settings: [
            FutureBuilder<String>(
              future: ModelManager.downloadedModelsAttribution(),
              builder: (context, snap) {
                if(!snap.hasData) return CupertinoActivityIndicator();
                return AboutSettingsTile(
                extraText: snap.data,
              );
              },
            ),
            ListTile(
              title: const Text("Contact"),
              subtitle: const Text("Write me for feedback, bug reports or feature requests"),
              leading: const Icon(Icons.mail_outline),
              onTap: () => launchUrl(Uri.parse("mailto:equirinya@gmail.com")),
            ),
            ListTile(
              title: Text("Privacy Policy"),
              leading: Icon(Icons.shield_outlined),
              onTap: () => launchUrl(Uri.parse("https://raw.githubusercontent.com/Equirinya/local_voicemessage_transcriber/master/privacy_policy.md")),
            ),
          ])
        ],
      ),
    );
  }
}

class SettingsSubPage extends StatelessWidget {
  final Widget body;
  final String title;
  final String? subtitle;
  final IconData icon;
  final bool openOnLoad;

  SettingsSubPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required List<Widget> categories,
    this.openOnLoad = false,
  }) : body = ListView(
    padding: const EdgeInsets.only(bottom: 128),
    children: categories,
  );

  const SettingsSubPage.fullPage({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.body,
    this.openOnLoad = false,
  });

  @override
  Widget build(BuildContext context) {
    if (openOnLoad)
      Future.delayed(const Duration(milliseconds: 500),
              () => Navigator.of(context).push(MaterialPageRoute(builder: (context) => Scaffold(body: body))));
    return ListTile(
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      leading: Icon(icon),
      trailing: Icon(Icons.chevron_right_rounded),
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(
            builder: (context) =>
                Scaffold(
                  appBar: AppBar(
                    title: Text(title),
                  ),
                  body: body,
                ),
          )),
    );
  }
}

class SettingsSubPageCategory extends StatelessWidget {
  const SettingsSubPageCategory({super.key, required this.title, required this.settings});

  final String? title;
  final List<Widget> settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 16, bottom: 8),
            child: Text(
              title!,
              style: Theme
                  .of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: Theme
                  .of(context)
                  .colorScheme
                  .primary),
            ),
          ),
        ...settings
      ],
    );
  }
}

class BoolSetting extends StatefulWidget {
  const BoolSetting({super.key,
    required this.setting,
    this.fallback = false,
    this.callback,
    required this.title,
    this.subtitle,
    required this.icon});

  final String setting;
  final String title;
  final String? subtitle;
  final IconData icon;
  final bool fallback;
  final Function(bool value)? callback;

  @override
  State<BoolSetting> createState() => _BoolSettingState();
}

class _BoolSettingState extends State<BoolSetting> {
  late SharedPreferences prefs;
  bool initialized = false;

  @override
  void initState() {
    asyncInitState();
    super.initState();
  }

  void asyncInitState() async {
    prefs = await SharedPreferences.getInstance();
    setState(() {
      initialized = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const ListTile(title: CupertinoActivityIndicator());
    return SwitchListTile(
      title: Text(widget.title),
      subtitle: widget.subtitle != null ? Text(widget.subtitle!) : null,
      secondary: Icon(widget.icon),
      value: prefs.getBool(widget.setting) ?? widget.fallback,
      onChanged: (value) {
        prefs.setBool(widget.setting, value);
        if (widget.callback != null) widget.callback!(value);
        setState(() {});
      },
    );
  }
}

class StringSetting extends StatefulWidget {
  const StringSetting(
      {super.key, required this.setting, this.fallback = "", required this.title, this.subtitle, required this.icon});

  final String setting;
  final String title;
  final String? subtitle;
  final IconData icon;
  final String fallback;

  @override
  State<StringSetting> createState() => _StringSettingState();
}

class _StringSettingState extends State<StringSetting> {
  late SharedPreferences prefs;
  bool initialized = false;

  @override
  void initState() {
    asyncInitState();
    super.initState();
  }

  void asyncInitState() async {
    prefs = await SharedPreferences.getInstance();
    setState(() {
      initialized = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const ListTile(title: CupertinoActivityIndicator());
    return ListTile(
        title: Text(widget.title),
        subtitle: widget.subtitle != null ? Text(widget.subtitle!) : null,
        leading: Icon(widget.icon),
        onTap: () =>
            showDialog(
                context: context,
                builder: (context) {
                  TextEditingController controller =
                  TextEditingController(text: prefs.getString(widget.setting) ?? widget.fallback);
                  return StatefulBuilder(
                      builder: (context, setState) =>
                          AlertDialog(
                            icon: Icon(widget.icon),
                            title: Text(widget.title),
                            content: TextField(
                              controller: controller,
                            ),
                            actions: [
                              TextButton(
                                  style:
                                  TextButton.styleFrom(backgroundColor: Theme
                                      .of(context)
                                      .colorScheme
                                      .primaryContainer),
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                    prefs.setString(widget.setting, controller.text);
                                  },
                                  child: const Text("Bestätigen")),
                              TextButton(
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                  },
                                  child: const Text("Abbrechen"))
                            ],
                          ));
                }).then((value) => setState(() {})));
  }
}

class InlineSelectionSetting extends StatefulWidget {
  const InlineSelectionSetting({super.key,
    required this.setting,
    this.fallbackIndex = 0,
    required this.title,
    required this.icon,
    required this.options,
    this.callback});

  final String setting;
  final String title;
  final List<String> options;
  final IconData icon;
  final int fallbackIndex;
  final Function(int index)? callback;

  @override
  State<InlineSelectionSetting> createState() => _InlineSelectionSettingState();
}

class _InlineSelectionSettingState extends State<InlineSelectionSetting> {
  late SharedPreferences prefs;
  bool initialized = false;
  late String selectedOption;

  @override
  void initState() {
    asyncInitState();
    super.initState();
  }

  void asyncInitState() async {
    prefs = await SharedPreferences.getInstance();
    selectedOption =
        widget.options.elementAtOrNull(prefs.getInt(widget.setting) ?? widget.fallbackIndex) ?? "Invalid option chosen";
    setState(() {
      initialized = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const ListTile(title: CupertinoActivityIndicator());
    return ListTile(
      title: Text(widget.title),
      subtitle: Text(selectedOption),
      leading: Icon(widget.icon),
      trailing: SegmentedButton<String>(
          segments: <ButtonSegment<String>>[
            for (final option in widget.options) ButtonSegment<String>(value: option, label: Text(option)),
          ],
          selected: <String>{
            selectedOption
          },
          onSelectionChanged: (Set<String> newSelection) {
            setState(() {
              selectedOption = newSelection.first;
            });
            widget.callback?.call(widget.options.indexOf(selectedOption));
            int index = widget.options.indexOf(selectedOption);
            if (index != -1) prefs.setInt(widget.setting, index);
          }),
    );
  }
}

class SelectionSetting extends StatefulWidget {
  const SelectionSetting({super.key,
    required this.setting,
    this.fallbackIndex = 0,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.options,
    this.callback});

  final String setting;
  final String title;
  final String? subtitle;
  final List<String> options;
  final IconData icon;
  final int fallbackIndex;
  final Function(int index)? callback;

  @override
  State<SelectionSetting> createState() => _SelectionSettingState();
}

class _SelectionSettingState extends State<SelectionSetting> {
  late SharedPreferences prefs;
  bool initialized = false;

  @override
  void initState() {
    asyncInitState();
    super.initState();
  }

  void asyncInitState() async {
    prefs = await SharedPreferences.getInstance();
    setState(() {
      initialized = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const ListTile(title: CupertinoActivityIndicator());
    return ListTile(
        title: Text(widget.title),
        subtitle: Text(widget.options.elementAtOrNull(prefs.getInt(widget.setting) ?? widget.fallbackIndex) ??
            "Invalid option chosen"),
        leading: Icon(widget.icon),
        onTap: () =>
            showDialog(
                context: context,
                builder: (context) {
                  int index = prefs.getInt(widget.setting) ?? widget.fallbackIndex;
                  return StatefulBuilder(
                      builder: (context, setState) =>
                          AlertDialog(
                            icon: Icon(widget.icon),
                            title: Text(widget.title),
                            content: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.subtitle != null && widget.subtitle!.isNotEmpty) Text(widget.subtitle!),
                                  const SizedBox(height: 16),
                                  for (final option in widget.options)
                                    RadioListTile(
                                      title: Text(option),
                                      value: option,
                                      groupValue: widget.options.elementAtOrNull(index),
                                      onChanged: (value) {
                                        index = widget.options.indexOf(value ?? widget.options[0]);
                                        setState(() {});
                                      },
                                    )
                                ],
                              ),
                            ),
                            actions: [
                              TextButton(
                                  style:
                                  TextButton.styleFrom(backgroundColor: Theme
                                      .of(context)
                                      .colorScheme
                                      .primaryContainer),
                                  onPressed: () async {
                                    await prefs.setInt(widget.setting, index);
                                    Navigator.of(context).pop();
                                    if (widget.callback != null) {
                                      widget.callback!(index);
                                    }
                                  },
                                  child: const Text("Bestätigen")),
                              TextButton(
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                  },
                                  child: const Text("Abbrechen"))
                            ],
                          ));
                }).then((value) => setState(() {})));
  }
}

class StringSelectionSetting extends StatefulWidget {
  const StringSelectionSetting({super.key,
    required this.setting,
    this.fallback,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.options,
    this.callback});

  final String setting;
  final String title;
  final String? subtitle;
  final List<String> options;
  final IconData icon;
  final String? fallback;
  final Function(String value)? callback;

  @override
  State<StringSelectionSetting> createState() => _StringSelectionSettingState();
}

class _StringSelectionSettingState extends State<StringSelectionSetting> {
  late SharedPreferences prefs;
  bool initialized = false;

  @override
  void initState() {
    asyncInitState();
    super.initState();
  }

  void asyncInitState() async {
    prefs = await SharedPreferences.getInstance();
    setState(() {
      initialized = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const ListTile(title: CupertinoActivityIndicator());
    return ListTile(
        title: Text(widget.title),
        subtitle: Text(
            prefs.getString(widget.setting) ?? widget.fallback ?? widget.options.firstOrNull ?? "No options available"),
        leading: Icon(widget.icon),
        onTap: () =>
            showDialog(
                context: context,
                builder: (context) {
                  String groupValue =
                      prefs.getString(widget.setting) ?? widget.fallback ?? widget.options.firstOrNull ?? "";
                  return StatefulBuilder(
                      builder: (context, setState) =>
                          AlertDialog(
                            icon: Icon(widget.icon),
                            title: Text(widget.title),
                            content: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.subtitle != null && widget.subtitle!.isNotEmpty) Text(widget.subtitle!),
                                  const SizedBox(height: 16),
                                  for (final option in widget.options)
                                    RadioListTile(
                                      title: Text(option),
                                      value: option,
                                      groupValue: groupValue,
                                      onChanged: (value) {
                                        groupValue = value ?? widget.options.firstOrNull ?? "";
                                        setState(() {});
                                      },
                                    )
                                ],
                              ),
                            ),
                            actions: [
                              TextButton(
                                  style:
                                  TextButton.styleFrom(backgroundColor: Theme
                                      .of(context)
                                      .colorScheme
                                      .primaryContainer),
                                  onPressed: () async {
                                    await prefs.setString(widget.setting, groupValue);
                                    Navigator.of(context).pop();
                                    if (widget.callback != null) {
                                      widget.callback!(groupValue);
                                    }
                                  },
                                  child: const Text("Bestätigen")),
                              TextButton(
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                  },
                                  child: const Text("Abbrechen"))
                            ],
                          ));
                }).then((value) => setState(() {})));
  }
}

class MultiSelectionSetting extends StatefulWidget {
  const MultiSelectionSetting({super.key,
    required this.setting,
    this.fallbackIndices = const [],
    required this.title,
    this.subtitle,
    required this.icon,
    required this.options,
    this.callback});

  final String setting;
  final String title;
  final String? subtitle;
  final List<String> options;
  final IconData icon;
  final List<int> fallbackIndices;
  final Function(List<int> indices)? callback;

  static List<int> settingStringToList(String? str, List<int> fallback) {
    Object? jsonDecodedObject = str != null ? jsonDecode(str) : null;
    List<int> selectedIndices = List.empty(growable: true);
    if (jsonDecodedObject != null && jsonDecodedObject is List && jsonDecodedObject.isNotEmpty) {
      try {
        selectedIndices = List<int>.from(jsonDecodedObject);
      } catch (e) {
        selectedIndices = List<int>.from(fallback);
      }
    } else {
      selectedIndices = List<int>.from(fallback);
    }
    return selectedIndices;
  }

  @override
  State<MultiSelectionSetting> createState() => _MultiSelectionSettingState();
}

class _MultiSelectionSettingState extends State<MultiSelectionSetting> {
  late SharedPreferences prefs;
  bool initialized = false;

  @override
  void initState() {
    asyncInitState();
    super.initState();
  }

  void asyncInitState() async {
    prefs = await SharedPreferences.getInstance();
    setState(() {
      initialized = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!initialized) return const ListTile(title: CupertinoActivityIndicator());
    String? savedIndicesString = prefs.getString(widget.setting);
    List<int> selectedIndices = MultiSelectionSetting.settingStringToList(savedIndicesString, widget.fallbackIndices);
    return ListTile(
        title: Text(widget.title),
        subtitle: Text(selectedIndices.map((e) => widget.options[e]).join(", ")),
        leading: Icon(widget.icon),
        onTap: () =>
            showDialog(
                context: context,
                builder: (context) {
                  var tempIndices = selectedIndices;
                  return StatefulBuilder(
                      builder: (context, setState) =>
                          AlertDialog(
                            icon: Icon(widget.icon),
                            title: Text(widget.title),
                            content: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.subtitle != null && widget.subtitle!.isNotEmpty) Text(widget.subtitle!),
                                  const SizedBox(height: 16),
                                  for (final (index, option) in widget.options.indexed)
                                    SwitchListTile(
                                      title: Text(option),
                                      value: tempIndices.contains(index),
                                      onChanged: (value) {
                                        if (value) {
                                          tempIndices.add(index);
                                        } else {
                                          tempIndices.remove(index);
                                        }
                                        setState(() {});
                                      },
                                    )
                                ],
                              ),
                            ),
                            actions: [
                              TextButton(
                                  style:
                                  TextButton.styleFrom(backgroundColor: Theme
                                      .of(context)
                                      .colorScheme
                                      .primaryContainer),
                                  onPressed: () async {
                                    tempIndices.sort();
                                    await prefs.setString(widget.setting, jsonEncode(tempIndices));
                                    Navigator.of(context).pop();
                                    if (widget.callback != null) {
                                      widget.callback!(tempIndices);
                                    }
                                  },
                                  child: const Text("Bestätigen")),
                              TextButton(
                                  onPressed: () {
                                    Navigator.of(context).pop();
                                  },
                                  child: const Text("Abbrechen"))
                            ],
                          ));
                }).then((value) => setState(() {})));
  }
}

class AboutSettingsTile extends StatelessWidget {
  const AboutSettingsTile({super.key, this.title, this.subtitle, this.icon, this.extraText});

  final String? title;
  final String? subtitle;
  final IconData? icon;
  final String? extraText;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title ?? "About"),
      subtitle: Text(subtitle ?? "App Information and Legalese"),
      leading: Icon(icon ?? Icons.info_outline),
      onTap: () async {
        PackageInfo packageInfo = await PackageInfo.fromPlatform();
        if (context.mounted) {
          showAboutDialog(
            context: context,
            applicationIcon: Image.asset("assets/icon/logo_transparent.png", height: 64, width: 64),
            applicationName: packageInfo.appName,
            applicationVersion: packageInfo.version,
            applicationLegalese: extraText,
          );
        }
      },
    );
  }
}
