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
  final String? vadUrl;
  final String modelType;
  final bool streaming;

  const ModelDefinition({
    required this.id,
    required this.name,
    required this.license,
    required this.repository,
    required this.encoderUrl,
    required this.decoderUrl,
    required this.joinerUrl,
    required this.tokensUrl,
    this.vadUrl,
    this.modelType = 'transducer',
    this.streaming = false,
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
    vadUrl: j['vad'] as String?,
    modelType: j['model_type'] as String? ?? 'transducer',
    streaming: j['streaming'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'license': license,
    'repository': repository,
    'encoder': encoderUrl,
    'decoder': decoderUrl,
    'joiner': joinerUrl,
    'tokens': tokensUrl,
    if (vadUrl != null) 'vad': vadUrl,
    'model_type': modelType,
    'streaming': streaming,
  };

  List<_ModelFile> get files => [
    _ModelFile('encoder.onnx', encoderUrl),
    _ModelFile('decoder.onnx', decoderUrl),
    _ModelFile('joiner.onnx', joinerUrl),
    _ModelFile('tokens.txt', tokensUrl),
    if (vadUrl != null) _ModelFile('silero_vad.onnx', vadUrl!),
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

  static Future<File> _metaFileForId(String id) async {
    final dir = await _dirForId(id);
    return File('${dir.path}/meta.json');
  }

  static Future<void> _saveMeta(ModelDefinition def) async {
    final file = await _metaFileForId(def.id);
    await file.writeAsString(jsonEncode(def.toJson()));
  }

  static Future<ModelDefinition?> _loadMeta(String id) async {
    try {
      final file = await _metaFileForId(id);
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ModelDefinition.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  // ─── Catalog ───────────────────────────────────────────────────────────────

  static Future<List<ModelDefinition>> fetchCatalog() async {
    final dio = Dio();
    final resp = await dio.get<String>(_catalogUrl);
    final list = jsonDecode(resp.data!) as List;
    return list.map((e) => ModelDefinition.fromJson(e)).toList();
  }

  static Future<List<ModelDefinition>> fetchCatalogAndRefreshDownloaded() async {
    final catalog = await fetchCatalog();
    final catalogById = {for (final d in catalog) d.id: d};
    final downloaded = await downloadedModels();
    for (final local in downloaded) {
      final remote = catalogById[local.id];
      if (remote != null) await _saveMeta(remote);
    }
    return catalog;
  }

  // ─── Download state ────────────────────────────────────────────────────────

  static Future<bool> isDownloaded(String id, List<_ModelFile> files) async {
    final dir = await _dirForId(id);
    for (final f in files) {
      if (!await File('${dir.path}/${f.name}').exists()) return false;
    }
    return true;
  }

  static Future<List<ModelDefinition>> downloadedModels() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final modelsDir = Directory('${base.path}/models');
      if (!await modelsDir.exists()) return [];

      final result = <ModelDefinition>[];
      await for (final entity in modelsDir.list()) {
        if (entity is! Directory) continue;
        final id = entity.path.split('/').last;
        final def = await _loadMeta(id);
        if (def == null) continue;
        if (await isDownloaded(id, def.files)) result.add(def);
      }
      return result;
    } catch (_) {
      return [];
    }
  }

  static Future<String> downloadedModelsAttribution() async {
    final models = await downloadedModels();
    if (models.isEmpty) return '';
    final entries = models.map((m) => '${m.name} – ${m.license} (${m.repository})');
    return 'Speech Models:\n${entries.join('\n')}';
  }

  // ─── Active model ──────────────────────────────────────────────────────────

  static Future<({ModelDefinition def, String path})?> getActiveModel() async {
    final selectedId = await getSelectedId();
    if (selectedId == null) return null;
    final def = await _loadMeta(selectedId);
    if (def == null) return null;
    if (!await isDownloaded(selectedId, def.files)) return null;
    final dir = await _dirForId(selectedId);
    return (def: def, path: dir.path);
  }

  // ─── Download / delete ─────────────────────────────────────────────────────

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

    await _saveMeta(def);
  }

  static Future<void> deleteModel(String id) async {
    final dir = await _dirForId(id);
    if (await dir.exists()) await dir.delete(recursive: true);
    final selectedId = await getSelectedId();
    if (selectedId == id) await setSelectedId(null);
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