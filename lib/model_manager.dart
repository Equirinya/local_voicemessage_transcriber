import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

//reference: https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models

const _catalogUrl =
    'https://raw.githubusercontent.com/Equirinya/local_voicemessage_transcriber/master/current_model_urls.json';

const _selectedModelKey = 'selected_model_id';

// ─── Model definition ────────────────────────────────────────────────────────

class ModelDefinition {
  final String id;
  final String name;
  final String license;
  final String repository;
  final String encoderUrl;
  final String decoderUrl;
  final String joinerUrl;
  final String tokensUrl;

  const ModelDefinition({
    required this.id,
    required this.name,
    required this.license,
    required this.repository,
    required this.encoderUrl,
    required this.decoderUrl,
    required this.joinerUrl,
    required this.tokensUrl,
  });

  factory ModelDefinition.fromJson(Map<String, dynamic> j) => ModelDefinition(
    id: j['id'],
    name: j['name'],
    license: j['license'],
    repository: j['repository'],
    encoderUrl: j['encoder'],
    decoderUrl: j['decoder'],
    joinerUrl: j['joiner'],
    tokensUrl: j['tokens'],
  );

  List<_ModelFile> get files => [
    _ModelFile('encoder.onnx', encoderUrl),
    _ModelFile('decoder.onnx', decoderUrl),
    _ModelFile('joiner.onnx', joinerUrl),
    _ModelFile('tokens.txt', tokensUrl),
  ];
}

class _ModelFile {
  final String name;
  final String url;
  const _ModelFile(this.name, this.url);
}

// ─── ModelManager ────────────────────────────────────────────────────────────

class ModelManager {
  static Future<Directory> _dirForId(String id) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/models/$id');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<List<ModelDefinition>> fetchCatalog() async {
    final dio = Dio();
    final resp = await dio.get<String>(_catalogUrl);
    final list = jsonDecode(resp.data!) as List;
    return list.map((e) => ModelDefinition.fromJson(e)).toList();
  }

  static Future<bool> isDownloaded(String id, List<_ModelFile> files) async {
    final dir = await _dirForId(id);
    for (final f in files) {
      if (!await File('${dir.path}/${f.name}').exists()) return false;
    }
    return true;
  }

  /// Returns all downloaded models with their attribution info.
  static Future<List<ModelDefinition>> downloadedModels() async {
    try {
      final catalog = await fetchCatalog();
      final result = <ModelDefinition>[];
      for (final def in catalog) {
        if (await isDownloaded(def.id, def.files)) {
          result.add(def);
        }
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  static Future<String> downloadedModelsAttribution() async {
    final models = await downloadedModels();
    if (models.isEmpty) return '';
    final entries = models.map(
          (m) => '${m.name} – ${m.license} (${m.repository})',
    );
    return 'Speech Models:\n${entries.join('\n')}';
  }

  /// Returns local model directory path if fully downloaded.
  static Future<String?> getModelPath(ModelDefinition def) async {
    final downloaded = await isDownloaded(def.id, def.files);
    if (!downloaded) return null;
    final dir = await _dirForId(def.id);
    return dir.path;
  }

  /// Returns the active [ModelDefinition] with its local path if a model is
  /// selected and fully downloaded, or null otherwise.
  static Future<({ModelDefinition def, String path})?> getActiveModel() async {
    final selectedId = await ModelManager.getSelectedId();
    if (selectedId == null) return null;

    List<ModelDefinition> catalog;
    try {
      catalog = await ModelManager.fetchCatalog();
    } catch (_) {
      return null;
    }

    final matches = catalog.where((d) => d.id == selectedId);
    if (matches.isEmpty) return null;

    final def = matches.first;
    final path = await ModelManager.getModelPath(def);
    if (path == null) return null;

    return (def: def, path: path);
  }

  static Future<void> downloadModel({
    required ModelDefinition def,
    required void Function(double progress, String file) onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await _dirForId(def.id);
    final dio = Dio();
    final files = def.files;

    for (int i = 0; i < files.length; i++) {
      final f = files[i];
      final dest = '${dir.path}/${f.name}';
      if (await File(dest).exists()) {
        onProgress((i + 1) / files.length, f.name);
        continue;
      }
      final tmp = '$dest.tmp';
      await dio.download(
        f.url,
        tmp,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          final overall = (i + received / total) / files.length;
          onProgress(overall, f.name);
        },
      );
      await File(tmp).rename(dest);
      onProgress((i + 1) / files.length, f.name);
    }
  }

  static Future<void> deleteModel(String id) async {
    final dir = await _dirForId(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static Future<int> sizeOnDisk(String id) async {
    final dir = await _dirForId(id);
    if (!await dir.exists()) return 0;
    int total = 0;
    await for (final f in dir.list()) {
      if (f is File) total += await f.length();
    }
    return total;
  }

  // ─── Persistence ───────────────────────────────────────────────────────────

  static Future<String?> getSelectedId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_selectedModelKey);
  }

  static Future<void> setSelectedId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_selectedModelKey);
    } else {
      await prefs.setString(_selectedModelKey, id);
    }
  }
}