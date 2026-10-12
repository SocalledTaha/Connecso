import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/services/split_tunnel_policy.dart';
import '../../l10n/app_strings.dart';
import '../widgets/app_notice.dart';

class InstalledApplication {
  const InstalledApplication({
    required this.packageName,
    required this.label,
    required this.isSystemApp,
  });

  final String packageName;
  final String label;
  final bool isSystemApp;
}

enum _SplitMenuAction { toggleSystemApps, exportList, importList }

/// App selection is staged locally. The native core adapter must apply this
/// policy before the feature is described as active routing.
class SplitTunnelingScreen extends StatefulWidget {
  const SplitTunnelingScreen({
    required this.language,
    required this.loadApplications,
    required this.initialPolicy,
    required this.onSave,
    this.loadApplicationIcon,
    super.key,
  });

  final Locale language;
  final Future<List<InstalledApplication>> Function() loadApplications;
  final SplitTunnelPolicy initialPolicy;
  final Future<void> Function(SplitTunnelPolicy) onSave;
  final Future<Uint8List?> Function(String packageName)? loadApplicationIcon;

  @override
  State<SplitTunnelingScreen> createState() => _SplitTunnelingScreenState();
}

class _SplitTunnelingScreenState extends State<SplitTunnelingScreen> {
  late Future<List<InstalledApplication>> _applications;
  late final Set<String> _selectedPackages = {
    ...widget.initialPolicy.packageNames,
  };
  late SplitTunnelMode _mode = widget.initialPolicy.mode;
  final _searchController = TextEditingController();
  final Map<String, Future<Uint8List?>> _iconFutures = {};
  String _query = '';
  bool _searching = false;
  bool _showSystemApps = false;
  Future<void> _saveQueue = Future<void>.value();

  bool get _dirty =>
      _mode != widget.initialPolicy.mode ||
      !_selectedPackages.containsAll(widget.initialPolicy.packageNames) ||
      !widget.initialPolicy.packageNames.containsAll(_selectedPackages);

  @override
  void initState() {
    super.initState();
    _applications = widget.loadApplications();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _applicationIcon(InstalledApplication app) {
    final loader = widget.loadApplicationIcon;
    if (loader == null) return const Icon(Icons.apps_rounded);
    final icon = _iconFutures.putIfAbsent(
      app.packageName,
      () => loader(app.packageName),
    );
    return FutureBuilder<Uint8List?>(
      future: icon,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return const Icon(Icons.apps_rounded);
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            width: 40,
            height: 40,
            fit: BoxFit.contain,
            cacheWidth: 96,
            cacheHeight: 96,
            errorBuilder: (context, error, stackTrace) =>
                const Icon(Icons.apps_rounded),
          ),
        );
      },
    );
  }

  Future<void> _save(AppStrings strings) async {
    try {
      await _persistDraft();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        AppNotice.show(context, strings.saveFailed);
      }
    }
  }

  Future<bool> _confirmLeave(AppStrings strings) async {
    if (!_dirty) return true;
    final choice = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.splitChangesTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.discard),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    if (choice == true) {
      await _persistDraft();
      return true;
    }
    if (choice == false) return true;
    return false;
  }

  Future<void> _persistDraft() {
    final policy = SplitTunnelPolicy(
      mode: _mode,
      packageNames: Set.unmodifiable(Set<String>.of(_selectedPackages)),
    );
    final operation = _saveQueue.then((_) => widget.onSave(policy));
    _saveQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _exportList(AppStrings strings) async {
    final policy = SplitTunnelPolicy(
      mode: _mode,
      packageNames: Set.unmodifiable(_selectedPackages),
    );
    await Clipboard.setData(ClipboardData(text: policy.exportText()));
    if (mounted) {
      AppNotice.show(context, strings.splitListExported);
    }
  }

  Future<void> _importList(AppStrings strings) async {
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      final source = clipboard?.text;
      if (source == null || source.trim().isEmpty) {
        throw const FormatException('Clipboard is empty.');
      }
      final imported = SplitTunnelPolicy.importText(source);
      if (!mounted) return;
      setState(() {
        _mode = imported.mode;
        _selectedPackages
          ..clear()
          ..addAll(imported.packageNames);
      });
      if (!mounted) return;
      AppNotice.show(context, strings.splitListImported);
    } catch (_) {
      if (mounted) {
        AppNotice.show(context, strings.splitListImportFailed);
      }
    }
  }

  Future<void> _handleMenuAction(
    _SplitMenuAction action,
    AppStrings strings,
  ) async {
    switch (action) {
      case _SplitMenuAction.toggleSystemApps:
        setState(() => _showSystemApps = !_showSystemApps);
        break;
      case _SplitMenuAction.exportList:
        await _exportList(strings);
        break;
      case _SplitMenuAction.importList:
        await _importList(strings);
        break;
    }
  }

  void _applySelection(String action, List<InstalledApplication> visible) {
    setState(() {
      switch (action) {
        case 'all':
          _selectedPackages.addAll(visible.map((app) => app.packageName));
          break;
        case 'invert':
          for (final app in visible) {
            if (!_selectedPackages.remove(app.packageName)) {
              _selectedPackages.add(app.packageName);
            }
          }
          break;
        case 'clear':
          _selectedPackages.clear();
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(widget.language);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmLeave(strings) && mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: _searching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: strings.searchApplications,
                    border: InputBorder.none,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                )
              : Text(strings.splitTunneling),
          actions: [
            IconButton(
              tooltip: _searching ? strings.close : strings.searchApplications,
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _query = '';
                  _searchController.clear();
                }
              }),
              icon: Icon(_searching ? Icons.close : Icons.search),
            ),
            PopupMenuButton<_SplitMenuAction>(
              key: const ValueKey('split-tunnel-menu'),
              tooltip: strings.installedApps,
              onSelected: (action) => _handleMenuAction(action, strings),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _SplitMenuAction.toggleSystemApps,
                  child: Text(
                    _showSystemApps
                        ? strings.hideSystemApps
                        : strings.showSystemApps,
                  ),
                ),
                PopupMenuItem(
                  value: _SplitMenuAction.exportList,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.content_copy_rounded),
                    title: Text(strings.exportSplitList),
                  ),
                ),
                PopupMenuItem(
                  value: _SplitMenuAction.importList,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.content_paste_rounded),
                    title: Text(strings.importSplitList),
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: () => _save(strings),
              child: Text(strings.save),
            ),
          ],
        ),
        body: FutureBuilder<List<InstalledApplication>>(
          future: _applications,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    _applications = widget.loadApplications();
                  }),
                  icon: const Icon(Icons.refresh),
                  label: Text(strings.retry),
                ),
              );
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final applications = snapshot.data!;
            final normalizedQuery = _query.trim().toLowerCase();
            final visibleApplications = applications
                .where((app) {
                  if (!_showSystemApps && app.isSystemApp) return false;
                  return normalizedQuery.isEmpty ||
                      app.label.toLowerCase().contains(normalizedQuery) ||
                      app.packageName.toLowerCase().contains(normalizedQuery);
                })
                .toList(growable: false);
            final enabled = _mode == SplitTunnelMode.excludeSelected;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Expanded(child: Text(strings.splitInfo)),
                      Switch(
                        value: _mode == SplitTunnelMode.excludeSelected,
                        onChanged: (enabled) {
                          setState(() {
                            _mode = enabled
                                ? SplitTunnelMode.excludeSelected
                                : SplitTunnelMode.off;
                          });
                        },
                      ),
                    ],
                  ),
                ),
                IgnorePointer(
                  ignoring: !enabled,
                  child: Opacity(
                    opacity: enabled ? 1 : .45,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        20,
                        8,
                        20,
                        8,
                      ),
                      child: Column(
                        children: [
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              strings.installedApps,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              TextButton(
                                onPressed: () =>
                                    _applySelection('all', visibleApplications),
                                child: Text(strings.selectAll),
                              ),
                              TextButton(
                                onPressed: () => _applySelection(
                                  'invert',
                                  visibleApplications,
                                ),
                                child: Text(strings.invertSelection),
                              ),
                              TextButton(
                                onPressed: () => _applySelection(
                                  'clear',
                                  visibleApplications,
                                ),
                                child: Text(strings.clearSelection),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: IgnorePointer(
                    ignoring: !enabled,
                    child: Opacity(
                      opacity: enabled ? 1 : .45,
                      child: visibleApplications.isEmpty
                          ? Center(child: Text(strings.noApplicationsFound))
                          : ListView.builder(
                              itemCount: visibleApplications.length,
                              itemBuilder: (context, index) {
                                final app = visibleApplications[index];
                                return CheckboxListTile(
                                  value: _selectedPackages.contains(
                                    app.packageName,
                                  ),
                                  title: Text(app.label),
                                  subtitle: Text(app.packageName),
                                  secondary: _applicationIcon(app),
                                  onChanged: (selected) {
                                    setState(() {
                                      if (selected == true) {
                                        _selectedPackages.add(app.packageName);
                                      } else {
                                        _selectedPackages.remove(
                                          app.packageName,
                                        );
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
