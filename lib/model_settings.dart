import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'model_manager.dart';

class ModelSettingsPage extends StatefulWidget {
  final void Function(ModelDefinition? selected) onSelectionChanged;

  const ModelSettingsPage({super.key, required this.onSelectionChanged});

  @override
  State<ModelSettingsPage> createState() => _ModelSettingsPageState();
}

class _ModelSettingsPageState extends State<ModelSettingsPage> {
  List<ModelDefinition> _catalog = [];
  Map<String, bool> _downloaded = {};
  Map<String, double> _downloading = {}; // id → progress 0-1, only if active
  Map<String, CancelToken> _tokens = {};
  Map<String, String> _currentFile = {};
  String? _selectedId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final catalog = await ModelManager.fetchCatalog();
      final selectedId = await ModelManager.getSelectedId();
      final downloaded = <String, bool>{};
      for (final def in catalog) {
        downloaded[def.id] = await ModelManager.isDownloaded(def.id, def.files);
      }
      setState(() {
        _catalog = catalog;
        _downloaded = downloaded;
        _selectedId = selectedId;
        _loading = false;
      });
    } catch (e,st) {
      if(kDebugMode) print('Catalog load error: $e\n$st');
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _startDownload(ModelDefinition def) async {
    final token = CancelToken();
    setState(() {
      _tokens[def.id] = token;
      _downloading[def.id] = 0;
      _currentFile[def.id] = '';
    });

    try {
      await ModelManager.downloadModel(
        def: def,
        cancelToken: token,
        onProgress: (progress, file) {
          if (mounted) setState(() {
            _downloading[def.id] = progress;
            _currentFile[def.id] = file;
          });
        },
      );
      _downloaded[def.id] = true;
    } on DioException catch (e,st) {
      if(kDebugMode) print('Download error for ${def.id}: $e\n$st');
      if (!CancelToken.isCancel(e) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: ${e.message}')),
        );
      }
      // Clean up partial on cancel
      if (CancelToken.isCancel(e)) {
        await ModelManager.deleteModel(def.id);
        _downloaded[def.id] = false;
      }
    } finally {
      if (mounted) setState(() {
        _downloading.remove(def.id);
        _tokens.remove(def.id);
        _currentFile.remove(def.id);
      });
    }
  }

  Future<void> _delete(ModelDefinition def) async {
    await ModelManager.deleteModel(def.id);
    if (_selectedId == def.id) {
      await ModelManager.setSelectedId(null);
      widget.onSelectionChanged(null);
      setState(() => _selectedId = null);
    }
    setState(() => _downloaded[def.id] = false);
  }

  Future<void> _selectModel(String? id) async {
    await ModelManager.setSelectedId(id);
    final def = id == null ? null : _catalog.firstWhere((d) => d.id == id);
    widget.onSelectionChanged(def);
    setState(() => _selectedId = id);
  }

  @override
  Widget build(BuildContext context) {
    return  _loading
        ? const Center(child: CupertinoActivityIndicator())
        : _error != null
        ? Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Failed to load catalog: $_error'),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      ),
    )
        : Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: DropdownButtonFormField<String?>(
            value: _selectedId,
            decoration: const InputDecoration(
              labelText: 'Active model',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              ..._catalog
                  .where((d) => _downloaded[d.id] == true)
                  .map((d) => DropdownMenuItem(
                value: d.id,
                child: Text(d.name),
              )),
            ],
            onChanged: (id) => _selectModel(id),
          ),
        ),
        const Divider(),
        Expanded(
          child: ListView.builder(
            itemCount: _catalog.length,
            itemBuilder: (context, i) {
              final def = _catalog[i];
              final isDownloaded = _downloaded[def.id] ?? false;
              final isDownloading = _downloading.containsKey(def.id);
              final progress = _downloading[def.id] ?? 0.0;
              final file = _currentFile[def.id] ?? '';

              return ListTile(
                title: Text(def.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // License chip
                    Wrap(
                      children: [
                        InkWell(
                          onTap: () => launchUrl(Uri.parse(def.repository)),
                          child: Chip(
                            padding: EdgeInsets.zero,
                            labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                            label: Text(
                              def.license,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                            avatar: const Icon(Icons.balance, size: 12),
                          ),
                        ),
                      ],
                    ),
                    // Status / progress row (your existing code)
                    if (isDownloading) ...[
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 2),
                      Text(
                        '$file  ${(progress * 100).toStringAsFixed(0)}%',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ] else if (isDownloaded)
                      Text(
                        _selectedId == def.id ? 'Active' : 'Downloaded',
                        style: TextStyle(
                          color: _selectedId == def.id
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      )
                    else
                      const Text('Not downloaded'),
                  ],
                ),
                trailing: isDownloading
                    ? IconButton(
                  icon: const Icon(Icons.cancel),
                  onPressed: () => _tokens[def.id]?.cancel(),
                )
                    : isDownloaded
                    ? IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(def),
                )
                    : IconButton(
                  icon: const Icon(Icons.download),
                  onPressed: () => _startDownload(def),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class ModelDownloadDialog extends StatefulWidget {
  const ModelDownloadDialog({super.key});

  /// Returns the selected+downloaded ModelDefinition, or null if dismissed.
  static Future<ModelDefinition?> show(BuildContext context) {
    return showDialog<ModelDefinition>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const ModelDownloadDialog(),
    );
  }

  @override
  State<ModelDownloadDialog> createState() => _ModelDownloadDialogState();
}

class _ModelDownloadDialogState extends State<ModelDownloadDialog> {
  List<ModelDefinition> _catalog = [];
  ModelDefinition? _selected;
  bool _loadingCatalog = true;
  bool _downloading = false;
  bool _done = false;
  double _progress = 0;
  String _currentFile = '';
  CancelToken? _cancelToken;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    try {
      final catalog = await ModelManager.fetchCatalog();
      setState(() {
        _catalog = catalog;
        _selected = catalog.isNotEmpty ? catalog.first : null;
        _loadingCatalog = false;
      });
    } catch (e,st) {
      if(kDebugMode) print('Catalog load error: $e\n$st');
      setState(() { _error = e.toString(); _loadingCatalog = false; });
    }
  }

  Future<void> _download() async {
    if (_selected == null) return;
    final def = _selected!;
    final token = CancelToken();
    _cancelToken = token;

    setState(() { _downloading = true; _progress = 0; _error = null; });

    try {
      await ModelManager.downloadModel(
        def: def,
        cancelToken: token,
        onProgress: (progress, file) {
          if (mounted) setState(() {
            _progress = progress;
            _currentFile = file;
          });
        },
      );
      await ModelManager.setSelectedId(def.id);
      setState(() { _downloading = false; _done = true; });
    } on DioException catch (e,st) {
      if(kDebugMode) print('Download error: $e\n$st');
      if (CancelToken.isCancel(e)) {
        await ModelManager.deleteModel(def.id);
        if (mounted) setState(() { _downloading = false; });
      } else {
        if (mounted) setState(() {
          _downloading = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download speech model'),
      content: SizedBox(
        width: double.maxFinite,
        child: _loadingCatalog
            ? const Center(child: CircularProgressIndicator())
            : _error != null && !_downloading
            ? Text('Error: $_error')
            : Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select a model to download. This is required for transcription.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<ModelDefinition>(
              value: _selected,
              decoration: const InputDecoration(
                labelText: 'Model',
                border: OutlineInputBorder(),
              ),
              items: _catalog
                  .map((d) => DropdownMenuItem(
                value: d,
                child: Text(d.name),
              ))
                  .toList(),
              onChanged: _downloading || _done
                  ? null
                  : (d) => setState(() => _selected = d),
            ),
            if (_downloading || _done) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _done ? 1.0 : _progress,
              ),
              const SizedBox(height: 4),
              Text(
                _done
                    ? 'Download complete!'
                    : '$_currentFile  ${(_progress * 100).toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_downloading && !_done)
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
        if (_downloading)
          TextButton(
            onPressed: () => _cancelToken?.cancel(),
            child: const Text('Cancel download'),
          ),
        if (!_done)
          ElevatedButton(
            onPressed: _loadingCatalog || _downloading ? null : _download,
            child: const Text('Download'),
          ),
        if (_done)
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(_selected),
            child: const Text('Close'),
          ),
      ],
    );
  }
}