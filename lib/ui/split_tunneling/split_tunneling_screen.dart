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
  final Set<String> _warmingIconPackages = {};
  String _query = '';
  bool _showSystemApps = false;
  Future<void> _saveQueue = Future<void>.value();

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

  void _warmVisibleIcons(
    BuildContext context,
    List<InstalledApplication> applications,
  ) {
    final loader = widget.loadApplicationIcon;
    if (loader == null) return;
    final pending = applications
        .where((app) => _warmingIconPackages.add(app.packageName))
        .toList(growable: false);
    if (pending.isEmpty) return;
    unawaited(() async {
      try {
        for (var offset = 0; offset < pending.length; offset += 4) {
          final batch = pending.skip(offset).take(4).toList(growable: false);
          final bytes = await Future.wait(
            batch.map(
              (app) => _iconFutures.putIfAbsent(
                app.packageName,
                () => loader(app.packageName),
              ),
            ),
          );
          if (!mounted || !context.mounted) return;
          await Future.wait([
            for (final iconBytes in bytes)
              if (iconBytes != null)
                precacheImage(
                  ResizeImage.resizeIfNeeded(96, 96, MemoryImage(iconBytes)),
                  context,
                ).catchError((Object _) {}),
          ]);
        }
      } catch (_) {
        for (final app in pending) {
          _warmingIconPackages.remove(app.packageName);
        }
      }
    }());
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
      unawaited(_persistDraft());
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
    unawaited(_persistDraft());
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(widget.language);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final pageColor = dark ? const Color(0xFF090D11) : const Color(0xFFEDF4F7);
    final cardColor = dark ? const Color(0xFF151B20) : Colors.white;
    final lineColor = dark ? const Color(0xFF303B43) : const Color(0xFFC6D9E1);
    const brandColor = Color(0xFF238BAF);
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: pageColor,
        appBar: AppBar(
          backgroundColor: pageColor,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(strings.splitTunneling),
          actions: [
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
            final visibleApplications =
                applications
                    .where((app) {
                      if (!_showSystemApps && app.isSystemApp) return false;
                      return normalizedQuery.isEmpty ||
                          app.label.toLowerCase().contains(normalizedQuery) ||
                          app.packageName.toLowerCase().contains(
                            normalizedQuery,
                          );
                    })
                    .toList(growable: false)
                  ..sort((a, b) {
                    final aSelected = _selectedPackages.contains(a.packageName);
                    final bSelected = _selectedPackages.contains(b.packageName);
                    if (aSelected != bSelected) return aSelected ? -1 : 1;
                    final byLabel = a.label.toLowerCase().compareTo(
                      b.label.toLowerCase(),
                    );
                    return byLabel != 0
                        ? byLabel
                        : a.packageName.compareTo(b.packageName);
                  });
            _warmVisibleIcons(context, visibleApplications);
            return _buildAetherStyledBody(
              context,
              strings,
              visibleApplications,
              dark: dark,
              cardColor: cardColor,
              lineColor: lineColor,
              brandColor: brandColor,
            );
          },
        ),
      ),
    );
  }

  Widget _buildAetherStyledBody(
    BuildContext context,
    AppStrings strings,
    List<InstalledApplication> applications, {
    required bool dark,
    required Color cardColor,
    required Color lineColor,
    required Color brandColor,
  }) {
    final isFa = widget.language.languageCode == 'fa';
    final enabled = _mode != SplitTunnelMode.off;
    final selectedCount = _selectedPackages
        .intersection(applications.map((app) => app.packageName).toSet())
        .length;
    final groupShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
      side: BorderSide(color: lineColor),
    );
    return Column(
      children: [
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
                sliver: SliverList.list(
                  children: [
                    const SizedBox(height: 2),
                    Card(
                      color: cardColor,
                      elevation: 0,
                      shape: groupShape,
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          children: [
                            _splitModeOption(
                              context,
                              number: '1',
                              title: isFa
                                  ? 'همهٔ برنامه‌ها از VPN استفاده کنند'
                                  : 'All apps use VPN',
                              subtitle: isFa
                                  ? 'همه‌چیز تحت پوشش است؛ حالت پیشنهادی برای بیشتر کاربران.'
                                  : 'Everything is covered. What most people want.',
                              mode: SplitTunnelMode.off,
                              cardColor: cardColor,
                              lineColor: lineColor,
                              brandColor: brandColor,
                            ),
                            _splitModeOption(
                              context,
                              number: '2',
                              title: isFa
                                  ? 'برنامه‌های انتخاب‌شده از VPN استفاده کنند'
                                  : 'Selected apps use VPN',
                              subtitle: isFa
                                  ? 'فقط برنامه‌هایی که انتخاب می‌کنید؛ برنامه‌های بعداً نصب‌شده بیرون می‌مانند.'
                                  : 'Only what you pick. Apps installed later stay outside.',
                              mode: SplitTunnelMode.includeSelected,
                              cardColor: cardColor,
                              lineColor: lineColor,
                              brandColor: brandColor,
                            ),
                            _splitModeOption(
                              context,
                              number: '3',
                              title: isFa
                                  ? 'برنامه‌های انتخاب‌شده از VPN خارج باشند'
                                  : 'Selected apps bypass VPN',
                              subtitle: isFa
                                  ? 'همه‌چیز به‌جز برنامه‌هایی که انتخاب می‌کنید؛ مناسب برنامه‌های بانکی و محلی.'
                                  : 'Everything but what you pick. For banking and local apps.',
                              mode: SplitTunnelMode.excludeSelected,
                              cardColor: cardColor,
                              lineColor: lineColor,
                              brandColor: brandColor,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (!enabled) ...[
                      const SizedBox(height: 10),
                      _splitNote(
                        context,
                        dark: dark,
                        icon: Icons.info_outline_rounded,
                        text: isFa
                            ? 'در این حالت، تنظیم فهرست برنامه‌ها اثری روی مسیر اتصال ندارد.'
                            : 'App selection is inactive while all-app VPN mode is selected.',
                      ),
                    ],
                    const SizedBox(height: 16),
                    IgnorePointer(
                      ignoring: !enabled,
                      child: Opacity(
                        opacity: enabled ? 1 : .5,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _mode == SplitTunnelMode.includeSelected
                                  ? (isFa
                                        ? 'برنامه‌های عبوری از VPN'
                                        : 'Apps to include')
                                  : (isFa
                                        ? 'برنامه‌های خارج از VPN'
                                        : 'Apps to leave out'),
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              isFa
                                  ? '$selectedCount برنامه انتخاب شده'
                                  : '$selectedCount apps selected',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _searchController,
                              onChanged: (value) =>
                                  setState(() => _query = value),
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.search_rounded),
                                hintText: strings.searchApplications,
                                filled: true,
                                fillColor: cardColor,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(color: lineColor),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  borderSide: BorderSide(color: lineColor),
                                ),
                              ),
                            ),
                            const SizedBox(height: 9),
                            SizedBox(
                              width: double.infinity,
                              child: _splitAction(
                                context,
                                _showSystemApps
                                    ? strings.hideSystemApps
                                    : strings.showSystemApps,
                                Icons.settings_applications_rounded,
                                brandColor,
                                () => setState(
                                  () => _showSystemApps = !_showSystemApps,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final itemWidth =
                                    (constraints.maxWidth - 8) / 2;
                                return Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    SizedBox(
                                      width: itemWidth,
                                      child: _splitAction(
                                        context,
                                        strings.invertSelection,
                                        Icons.flip_rounded,
                                        brandColor,
                                        () => _applySelection(
                                          'invert',
                                          applications,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: itemWidth,
                                      child: _splitAction(
                                        context,
                                        strings.clearSelection,
                                        Icons.remove_done_rounded,
                                        brandColor,
                                        () => _applySelection(
                                          'clear',
                                          applications,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: itemWidth,
                                      child: _splitAction(
                                        context,
                                        strings.importSplitList,
                                        Icons.content_paste_rounded,
                                        brandColor,
                                        () => _handleMenuAction(
                                          _SplitMenuAction.importList,
                                          strings,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: itemWidth,
                                      child: _splitAction(
                                        context,
                                        strings.exportSplitList,
                                        Icons.content_copy_rounded,
                                        brandColor,
                                        () => _handleMenuAction(
                                          _SplitMenuAction.exportList,
                                          strings,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: constraints.maxWidth,
                                      child: _splitAction(
                                        context,
                                        strings.selectAll,
                                        Icons.select_all_rounded,
                                        brandColor,
                                        () => _applySelection(
                                          'all',
                                          applications,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (applications.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text(strings.noApplicationsFound)),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
                  sliver: SliverList.separated(
                    itemCount: applications.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 7),
                    itemBuilder: (context, index) {
                      final app = applications[index];
                      final selected = _selectedPackages.contains(
                        app.packageName,
                      );
                      return IgnorePointer(
                        ignoring: !enabled,
                        child: Opacity(
                          opacity: enabled ? 1 : .5,
                          child: _applicationTile(
                            context,
                            app,
                            selected: selected,
                            cardColor: cardColor,
                            lineColor: lineColor,
                            brandColor: brandColor,
                            isFa: isFa,
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _splitModeOption(
    BuildContext context, {
    required String number,
    required String title,
    required String subtitle,
    required SplitTunnelMode mode,
    required Color cardColor,
    required Color lineColor,
    required Color brandColor,
  }) {
    final selected = _mode == mode;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(
        color: selected
            ? brandColor.withValues(alpha: .68)
            : Colors.transparent,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? brandColor.withValues(alpha: .09) : cardColor,
        shape: shape,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            setState(() => _mode = mode);
            unawaited(_persistDraft());
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? brandColor.withValues(alpha: .10)
                        : cardColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: lineColor),
                  ),
                  child: Text(
                    number,
                    style: TextStyle(
                      color: brandColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? brandColor : lineColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _splitAction(
    BuildContext context,
    String label,
    IconData icon,
    Color brandColor,
    VoidCallback onPressed,
  ) => OutlinedButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 17),
    label: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false),
    ),
    style: OutlinedButton.styleFrom(
      foregroundColor: Theme.of(context).brightness == Brightness.dark
          ? Colors.white
          : brandColor,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      side: BorderSide(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white24
            : brandColor.withValues(alpha: .26),
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
      backgroundColor: Theme.of(context).colorScheme.surface,
    ),
  );

  Widget _splitNote(
    BuildContext context, {
    required bool dark,
    required IconData icon,
    required String text,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: dark ? const Color(0xFF171D22) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: dark ? const Color(0xFF303B43) : const Color(0xFFC6D9E1),
      ),
    ),
    child: Row(
      children: [
        Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    ),
  );

  Widget _applicationTile(
    BuildContext context,
    InstalledApplication app, {
    required bool selected,
    required Color cardColor,
    required Color lineColor,
    required Color brandColor,
    required bool isFa,
  }) {
    final scheme = Theme.of(context).colorScheme;
    void toggle(bool value) {
      setState(() {
        if (value) {
          _selectedPackages.add(app.packageName);
        } else {
          _selectedPackages.remove(app.packageName);
        }
      });
      unawaited(_persistDraft());
    }

    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => toggle(!selected),
        child: Container(
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? brandColor.withValues(alpha: .55) : lineColor,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: lineColor),
                ),
                child: _applicationIcon(app),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      app.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      app.isSystemApp
                          ? (isFa ? 'برنامهٔ سیستمی' : 'System app')
                          : app.packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch.adaptive(value: selected, onChanged: toggle),
            ],
          ),
        ),
      ),
    );
  }
}
