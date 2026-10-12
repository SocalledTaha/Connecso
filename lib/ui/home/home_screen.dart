import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;

import '../../domain/models/connection_state.dart';
import '../../domain/models/vpn_node.dart';
import '../../domain/models/destination_selection.dart';
import '../../domain/services/location_resolver.dart';
import '../../domain/services/usage_service.dart';
import '../../data/repositories/saved_subscriptions.dart';
import '../../data/parsers/subscription_parser.dart';
import '../../l10n/app_strings.dart';
import '../settings/subscription_manager_sheet.dart';
import '../widgets/connection_scene.dart';
import '../widgets/app_notice.dart';
import '../../prototypes/responsive_globe.dart';
import 'qr_import_screen.dart';
import 'destination_country_selector.dart';
import 'connection_method_selector.dart';
import '../../domain/models/connection_method.dart';

Duration _textMotionDuration(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations == true
    ? Duration.zero
    : const Duration(milliseconds: 1000);

void _showWideNotice(BuildContext context, String message) {
  AppNotice.show(context, message);
}

GlobeTarget? _homeGlobeTarget(DestinationLocation? location) {
  if (location == null || !location.hasCoordinates) return null;
  final name = location.country.isEmpty
      ? location.countryCode
      : location.country;
  return GlobeTarget(name, location.latitude!, location.longitude!);
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    required this.loading,
    required this.nodes,
    required this.phase,
    required this.activeNode,
    required this.failure,
    required this.quota,
    required this.sessionUploadBytes,
    required this.sessionDownloadBytes,
    required this.hasSubscriptionUrl,
    required this.savedSubscriptions,
    required this.activeSubscriptionId,
    this.activeSubscriptionName,
    required this.canManageSubscriptions,
    required this.language,
    required this.themeMode,
    required this.destination,
    this.sourceCountryCode,
    required this.splitTunnelingBuilder,
    required this.onImport,
    required this.onToggleConnection,
    required this.onRefreshPing,
    required this.refreshingPing,
    required this.connectionHealthReady,
    required this.onLanguageChanged,
    required this.onThemeChanged,
    required this.onSelectSubscription,
    required this.onEditSubscription,
    required this.onRefreshSubscription,
    required this.onDeleteSubscription,
    required this.onTogglePinned,
    required this.onSignOut,
    required this.subscriptionRevision,
    this.destinationSelection = const DestinationSelection.auto(),
    this.onDestinationSelectionChanged,
    this.connectionMethod,
    this.onConnectionMethodChanged,
    this.readSavedSubscriptions,
    super.key,
  });

  final bool loading;
  final List<VpnNode> nodes;
  final ConnectionPhase phase;
  final VpnNode? activeNode;
  final String? failure;
  final QuotaSnapshot quota;
  final int? sessionUploadBytes;
  final int? sessionDownloadBytes;
  final bool hasSubscriptionUrl;
  final List<SavedSubscription> savedSubscriptions;
  final String? activeSubscriptionId;
  final String? activeSubscriptionName;
  final bool canManageSubscriptions;
  final Locale language;
  final ThemeMode themeMode;
  final DestinationLocation? destination;
  final String? sourceCountryCode;
  final WidgetBuilder splitTunnelingBuilder;
  final Future<void> Function(String) onImport;
  final Future<void> Function() onToggleConnection;
  final Future<void> Function() onRefreshPing;
  final bool refreshingPing;
  final bool connectionHealthReady;
  final Future<void> Function(Locale) onLanguageChanged;
  final Future<void> Function(ThemeMode) onThemeChanged;
  final Future<void> Function(String) onSelectSubscription;
  final Future<void> Function(String, String, String?, bool, int?)
  onEditSubscription;
  final Future<void> Function(String) onRefreshSubscription;
  final Future<void> Function(String) onDeleteSubscription;
  final Future<void> Function(String, bool) onTogglePinned;
  final Future<void> Function() onSignOut;
  final ValueListenable<int> subscriptionRevision;
  final ConnectionMethod? connectionMethod;
  final Future<void> Function(ConnectionMethod?)? onConnectionMethodChanged;
  List<VpnNode> get destinationNodes => nodes
      .where(
        (node) => connectionMethod == null || connectionMethod!.matches(node),
      )
      .toList();
  final DestinationSelection destinationSelection;
  final Future<void> Function(DestinationSelection)?
  onDestinationSelectionChanged;
  final List<SavedSubscription> Function()? readSavedSubscriptions;

  Future<void> _importText(
    BuildContext context,
    AppStrings strings,
    String text,
  ) async {
    try {
      await onImport(normalizeSubscriptionInput(text));
      if (context.mounted) {
        _showImportOverlay(context, strings);
      }
    } catch (_) {
      if (context.mounted) {
        _showWideNotice(context, strings.importFailed);
      }
    }
  }

  void _showImportOverlay(BuildContext context, AppStrings strings) {
    _showWideNotice(
      context,
      strings.isPersian
          ? 'اشتراک با موفقیت ذخیره شد.'
          : 'Subscription imported successfully.',
    );
  }

  Future<void> _importClipboard(
    BuildContext context,
    AppStrings strings,
  ) async {
    ClipboardData? value;
    try {
      value = await Clipboard.getData(Clipboard.kTextPlain);
    } on PlatformException {
      // Some Android clipboard providers briefly reject a read while the
      // system clipboard overlay is closing. Treat that the same as empty
      // clipboard and keep the import action recoverable.
      value = null;
    }
    final text = value?.text == null
        ? null
        : normalizeSubscriptionInput(value!.text!);
    if (!context.mounted) return;
    if (text == null || text.isEmpty) {
      _showWideNotice(context, strings.noClipboard);
    } else {
      await _importText(context, strings, text);
    }
  }

  Future<void> _scanQr(BuildContext context, AppStrings strings) async {
    final qr = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => QrImportScreen(strings: strings)),
    );
    if (qr != null && context.mounted) await _importText(context, strings, qr);
  }

  Future<void> _showSplitTunneling(BuildContext context, AppStrings strings) =>
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: strings.splitTunneling,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (dialogContext, _, __) {
          final colors = Theme.of(dialogContext).colorScheme;
          return SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 132, 12, 16),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(dialogContext).height * .72,
                    maxWidth: MediaQuery.sizeOf(dialogContext).width - 24,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                      child: Material(
                        color: colors.surfaceContainerHighest.withValues(
                          alpha: .90,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        child: splitTunnelingBuilder(dialogContext),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, -.05),
                end: Offset.zero,
              ).animate(curve),
              child: child,
            ),
          );
        },
      );

  Future<void> _manageSubscriptions(BuildContext context, AppStrings strings) =>
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: strings.subscriptions,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (dialogContext, _, __) {
          final colors = Theme.of(dialogContext).colorScheme;
          return SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 20, 12, 88),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(dialogContext).height * .78,
                    maxWidth: MediaQuery.sizeOf(dialogContext).width - 24,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: BackdropFilter(
                      filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                      child: Material(
                        color: colors.surfaceContainerHighest.withValues(
                          alpha: .88,
                        ),
                        borderRadius: BorderRadius.circular(24),
                        child: ValueListenableBuilder<int>(
                          valueListenable: subscriptionRevision,
                          builder: (context, _, __) => SubscriptionManagerSheet(
                            language: language,
                            savedSubscriptions:
                                readSavedSubscriptions?.call() ??
                                savedSubscriptions,
                            activeSubscriptionId: activeSubscriptionId,
                            canManageSubscriptions: canManageSubscriptions,
                            onSelectSubscription: onSelectSubscription,
                            onEditSubscription: onEditSubscription,
                            onRefreshSubscription: onRefreshSubscription,
                            onDeleteSubscription: onDeleteSubscription,
                            onTogglePinned: onTogglePinned,
                            onSignOut: onSignOut,
                            onImportClipboard: () =>
                                _importClipboard(context, strings),
                            onScanQr: () => _scanQr(context, strings),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curve,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, .08),
                end: Offset.zero,
              ).animate(curve),
              child: child,
            ),
          );
        },
      );

  Future<void> _chooseMethod(
    BuildContext context,
    BuildContext anchorContext,
  ) async {
    final methods = ConnectionMethod.available(nodes);
    if (methods.isEmpty) {
      _showWideNotice(
        context,
        language.languageCode == 'fa'
            ? 'هیچ روش اتصال پشتیبانی‌شده‌ای در این اشتراک نیست.'
            : 'No supported connection methods in this subscription.',
      );
      return;
    }
    final box = anchorContext.findRenderObject() as RenderBox;
    final top = box.localToGlobal(Offset.zero).dy;
    final signal = ValueNotifier<int>(0);
    final selected = await showGeneralDialog<(ConnectionMethod?,)>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      barrierLabel: language.languageCode == 'fa'
          ? 'روش اتصال'
          : 'Connection method',
      transitionDuration: Duration.zero,
      pageBuilder: (dialogContext, _, __) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => signal.value++,
              child: const SizedBox.expand(),
            ),
          ),
          PositionedDirectional(
            start: 30,
            bottom: MediaQuery.sizeOf(dialogContext).height - top + 8,
            child: ConnectionMethodSelector(
              methods: methods,
              selected: connectionMethod,
              persian: language.languageCode == 'fa',
              dismissSignal: signal,
              onSelected: (method) =>
                  Navigator.of(dialogContext).pop((method,)),
              onDismissed: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ],
      ),
    );
    signal.dispose();
    if (selected != null) {
      await onConnectionMethodChanged?.call(selected.$1);
      if (context.mounted) {
        _showWideNotice(
          context,
          language.languageCode == 'fa'
              ? '${selected.$1?.label ?? 'خودکار'} برای اتصال بعدی انتخاب شد.'
              : '${selected.$1?.label ?? 'Automatic'} selected for the next connection.',
        );
      }
    }
  }

  Future<void> _chooseDestination(
    BuildContext context,
    BuildContext anchorContext,
  ) async {
    final box = anchorContext.findRenderObject() as RenderBox;
    final top = box.localToGlobal(Offset.zero).dy;
    final dismissSignal = ValueNotifier<int>(0);
    final selected = await showGeneralDialog<DestinationSelection>(
      context: context,
      barrierDismissible: false,
      barrierLabel: language.languageCode == 'fa'
          ? 'انتخاب مقصد'
          : 'Select destination',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (dialogContext, _, __) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => dismissSignal.value++,
                child: const SizedBox.expand(),
              ),
            ),
            PositionedDirectional(
              end: 30,
              bottom: MediaQuery.sizeOf(dialogContext).height - top + 8,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: (top - MediaQuery.paddingOf(dialogContext).top - 8)
                      .clamp(48.0, double.infinity),
                ),
                child: DestinationCountrySelector(
                  nodes: destinationNodes,
                  selection: destinationSelection,
                  persian: language.languageCode == 'fa',
                  dismissSignal: dismissSignal,
                  onDismissed: () => Navigator.of(dialogContext).pop(),
                  onSelected: (value) => Navigator.of(dialogContext).pop(value),
                ),
              ),
            ),
          ],
        );
      },
    );
    dismissSignal.dispose();
    if (selected != null) {
      await onDestinationSelectionChanged?.call(selected);
    }
  }

  Widget _emptySubscriptionBody(BuildContext context, AppStrings strings) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final isPersian = language.languageCode == 'fa';
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            22,
            MediaQuery.paddingOf(context).top + 8,
            22,
            10,
          ),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              children: [
                Image.asset(
                  dark
                      ? 'assets/logos/connecso_logo_dark.png'
                      : 'assets/logos/connecso_logo_light.png',
                  width: 34,
                  height: 42,
                  fit: BoxFit.contain,
                ),
                const SizedBox(width: 9),
                Text(
                  strings.appName,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                _LanguageButton(
                  localeCode: language.languageCode.toUpperCase(),
                  tooltip: strings.language,
                  onPressed: () =>
                      onLanguageChanged(Locale(isPersian ? 'en' : 'fa')),
                ),
                const SizedBox(width: 8),
                _ThemeToggle(
                  isDark: dark,
                  tooltip: strings.theme,
                  onPressed: () =>
                      onThemeChanged(dark ? ThemeMode.light : ThemeMode.dark),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 32),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  savedSubscriptions.isEmpty
                      ? strings.noProfile
                      : strings.savedSubscriptionHint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: canManageSubscriptions
                            ? () => _importClipboard(context, strings)
                            : null,
                        icon: const Icon(Icons.content_paste_rounded),
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            strings.pasteClipboard,
                            maxLines: 1,
                            softWrap: false,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: canManageSubscriptions
                            ? () => _scanQr(context, strings)
                            : null,
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: Text(strings.scanQr),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(language);
    final hasProfile = nodes.isNotEmpty;
    final busy = const {
      ConnectionPhase.preparing,
      ConnectionPhase.connecting,
      ConnectionPhase.verifying,
      ConnectionPhase.reconnecting,
      ConnectionPhase.disconnecting,
    }.contains(phase);
    final canCancelConnection = const {
      ConnectionPhase.preparing,
      ConnectionPhase.connecting,
      ConnectionPhase.verifying,
      ConnectionPhase.reconnecting,
    }.contains(phase);
    final resolvedDestination = destination;
    final isPersian = language.languageCode == 'fa';
    return Scaffold(
      extendBody: true,
      // Keep the map edge-to-edge, including behind the status bar. Foreground
      // content receives the safe-area inset in its sliver padding below.
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF061522)
              : const Color(0xFFEAF2F6),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 420),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : hasProfile
              ? LayoutBuilder(
                  builder: (context, constraints) {
                    final sceneHeight =
                        (MediaQuery.sizeOf(context).height * .70)
                            .clamp(400.0, 720.0)
                            .toDouble();
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: RepaintBoundary(
                            child: IgnorePointer(
                              child: ResponsiveGlobe(
                                globeCenterYFraction: .42,
                                lightMode:
                                    Theme.of(context).brightness ==
                                    Brightness.light,
                                sourceTarget:
                                    _homeGlobeTarget(
                                      LocationResolver.forCountryCode(
                                        sourceCountryCode,
                                      ),
                                    ) ??
                                    const GlobeTarget('Iran', 32.4, 53.7),
                                destinationTarget: _homeGlobeTarget(
                                  resolvedDestination,
                                ),
                              ),
                            ),
                          ),
                        ),
                        CustomScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          slivers: [
                            SliverPadding(
                              padding: EdgeInsets.fromLTRB(
                                22,
                                MediaQuery.paddingOf(context).top + 8,
                                22,
                                MediaQuery.paddingOf(context).bottom + 10,
                              ),
                              sliver: SliverList.list(
                                children: [
                                  Directionality(
                                    textDirection: TextDirection.ltr,
                                    child: Row(
                                      children: [
                                        Image.asset(
                                          Theme.of(context).brightness ==
                                                  Brightness.dark
                                              ? 'assets/logos/connecso_logo_dark.png'
                                              : 'assets/logos/connecso_logo_light.png',
                                          width: 34,
                                          height: 42,
                                          fit: BoxFit.contain,
                                        ),
                                        const SizedBox(width: 9),
                                        Text(
                                          strings.appName,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge
                                              ?.copyWith(
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: .2,
                                              ),
                                        ),
                                        const Spacer(),
                                        _LanguageButton(
                                          localeCode: language.languageCode
                                              .toUpperCase(),
                                          tooltip: strings.language,
                                          onPressed: () => onLanguageChanged(
                                            Locale(isPersian ? 'en' : 'fa'),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        _ThemeToggle(
                                          isDark:
                                              Theme.of(context).brightness ==
                                              Brightness.dark,
                                          tooltip: strings.theme,
                                          onPressed: () => onThemeChanged(
                                            Theme.of(context).brightness ==
                                                    Brightness.dark
                                                ? ThemeMode.light
                                                : ThemeMode.dark,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (hasProfile) ...[
                                    const SizedBox(height: 6),
                                    _SplitTunnelingCard(
                                      title: strings.splitTunneling,
                                      onTap: () =>
                                          _showSplitTunneling(context, strings),
                                    ),
                                  ],
                                  const SizedBox(height: 2),
                                  ConnectionScene(
                                    height: sceneHeight,
                                    showControls: false,
                                    showMap: false,
                                    phase: phase,
                                    destination: resolvedDestination,
                                    destinationLabel:
                                        resolvedDestination == null ||
                                            ((resolvedDestination
                                                        .country
                                                        .isEmpty ||
                                                    resolvedDestination
                                                            .country ==
                                                        'Unknown') &&
                                                resolvedDestination
                                                    .city
                                                    .isEmpty)
                                        ? null
                                        : '${_countryFlag(resolvedDestination.countryCode)} ${resolvedDestination.country}',
                                    destinationSemantics:
                                        resolvedDestination == null ||
                                            ((resolvedDestination
                                                        .country
                                                        .isEmpty ||
                                                    resolvedDestination
                                                            .country ==
                                                        'Unknown') &&
                                                resolvedDestination
                                                    .city
                                                    .isEmpty)
                                        ? null
                                        : '${strings.destination}: ${resolvedDestination.country}',
                                    connectionLabel: strings.status(phase.name),
                                    actionLabel: canCancelConnection
                                        ? strings.cancelConnection
                                        : busy
                                        ? strings.connecting
                                        : phase == ConnectionPhase.connected
                                        ? strings.disconnected
                                        : strings.connect,
                                    onPressed:
                                        hasProfile &&
                                            (!busy || canCancelConnection)
                                        ? onToggleConnection
                                        : null,
                                    failure: failure,
                                    health:
                                        phase == ConnectionPhase.connected &&
                                            connectionHealthReady
                                        ? _connectionHealth(activeNode, strings)
                                        : null,
                                  ),
                                  if (!hasProfile) ...[
                                    Text(
                                      savedSubscriptions.isEmpty
                                          ? strings.noProfile
                                          : strings.savedSubscriptionHint,
                                      textAlign: TextAlign.center,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    if (savedSubscriptions.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      OutlinedButton.icon(
                                        onPressed: canManageSubscriptions
                                            ? () => _manageSubscriptions(
                                                context,
                                                strings,
                                              )
                                            : null,
                                        icon: const Icon(
                                          Icons.subscriptions_outlined,
                                        ),
                                        label: Text(strings.subscriptions),
                                      ),
                                    ],
                                    const SizedBox(height: 12),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: FilledButton.icon(
                                            onPressed: canManageSubscriptions
                                                ? () => _importClipboard(
                                                    context,
                                                    strings,
                                                  )
                                                : null,
                                            icon: const Icon(
                                              Icons.content_paste_rounded,
                                            ),
                                            label: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                strings.pasteClipboard,
                                                maxLines: 1,
                                                softWrap: false,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: canManageSubscriptions
                                                ? () =>
                                                      _scanQr(context, strings)
                                                : null,
                                            icon: const Icon(
                                              Icons.qr_code_scanner_rounded,
                                            ),
                                            label: Text(strings.scanQr),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                )
              : _emptySubscriptionBody(context, strings),
        ),
      ),
      bottomNavigationBar: hasProfile && !loading
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 7, 22, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.translate(
                      // The destination tile gets a real hit-test area above
                      // the usage card below. Compensate here so the Connect
                      // block stays at its established screen position.
                      offset: const Offset(0, 58),
                      child: ConnectionStatusPanel(
                        phase: phase,
                        connectionLabel: strings.status(phase.name),
                        actionLabel: canCancelConnection
                            ? strings.cancelConnection
                            : busy
                            ? strings.connecting
                            : phase == ConnectionPhase.connected
                            ? strings.disconnected
                            : strings.connect,
                        onPressed: hasProfile && (!busy || canCancelConnection)
                            ? onToggleConnection
                            : null,
                        failure: failure,
                        health:
                            phase == ConnectionPhase.connected &&
                                connectionHealthReady
                            ? _connectionHealth(activeNode, strings)
                            : null,
                        refreshPingLabel: strings.refreshPing,
                        onRefreshPing: onRefreshPing,
                        refreshingPing: refreshingPing,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 58),
                          child: _UsageCard(
                            uploadBytes: sessionUploadBytes,
                            downloadBytes: sessionDownloadBytes,
                            quota: quota,
                            strings: strings,
                            isPersian: isPersian,
                          ),
                        ),
                        PositionedDirectional(
                          start: 8,
                          top: 0,
                          child: Builder(
                            builder: (anchorContext) => _MethodButton(
                              method: connectionMethod,
                              persian: isPersian,
                              onTap: () =>
                                  _chooseMethod(context, anchorContext),
                            ),
                          ),
                        ),
                        PositionedDirectional(
                          end: 8,
                          top: 0,
                          child: Builder(
                            builder: (anchorContext) => _DestinationButton(
                              selection: destinationSelection,
                              onTap: () =>
                                  _chooseDestination(context, anchorContext),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _SubscriptionExpiryTile(
                      key: const ValueKey('subscription-expiry-tile'),
                      name: activeSubscriptionName ?? strings.appName,
                      nameKey: ValueKey(
                        activeSubscriptionName ?? strings.appName,
                      ),
                      expiry: _subscriptionExpiry(quota, strings, isPersian),
                      textDirection: isPersian
                          ? TextDirection.rtl
                          : TextDirection.ltr,
                      onTap: () => _manageSubscriptions(context, strings),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  static String _countryFlag(String? code) {
    final normalized = (code ?? '').trim().toUpperCase();
    if (normalized.length != 2) return '🌐';
    return String.fromCharCodes(
      normalized.codeUnits.map((value) => 0x1F1E6 + value - 65),
    );
  }

  static String _subscriptionExpiry(
    QuotaSnapshot quota,
    AppStrings strings,
    bool isPersian,
  ) {
    if (quota.expiresAt != null && quota.expiresAt!.isBefore(DateTime.now())) {
      return strings.expired;
    }
    if (quota.neverExpires) return strings.noExpiry;
    final expiry = quota.expiresAt;
    if (expiry == null) return strings.unavailable;
    final local = expiry.toLocal();
    final date = isPersian
        ? _persianDate(local)
        : '${local.day.toString().padLeft(2, '0')} ${_englishMonth(local.month)} ${local.year}';
    return strings.expiresOn(date);
  }

  static String _englishMonth(int month) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month - 1];

  static String _persianDate(DateTime date) {
    final gy = date.year - 1600;
    final gm = date.month - 1;
    final gd = date.day - 1;
    const gregorianMonthDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    var dayNumber =
        365 * gy + (gy + 3) ~/ 4 - (gy + 99) ~/ 100 + (gy + 399) ~/ 400;
    for (var month = 0; month < gm; month++) {
      dayNumber += gregorianMonthDays[month];
    }
    if (gm > 1 &&
        (date.year % 400 == 0 ||
            (date.year % 4 == 0 && date.year % 100 != 0))) {
      dayNumber++;
    }
    dayNumber += gd;
    var jalaliDayNumber = dayNumber - 79;
    final cycles = jalaliDayNumber ~/ 12053;
    jalaliDayNumber %= 12053;
    var jalaliYear = 979 + 33 * cycles + 4 * (jalaliDayNumber ~/ 1461);
    jalaliDayNumber %= 1461;
    if (jalaliDayNumber >= 366) {
      jalaliYear += (jalaliDayNumber - 1) ~/ 365;
      jalaliDayNumber = (jalaliDayNumber - 1) % 365;
    }
    final jalaliMonth = jalaliDayNumber < 186
        ? 1 + jalaliDayNumber ~/ 31
        : 7 + (jalaliDayNumber - 186) ~/ 30;
    final jalaliDay = jalaliDayNumber < 186
        ? 1 + jalaliDayNumber % 31
        : 1 + (jalaliDayNumber - 186) % 30;
    const monthNames = [
      'فروردین',
      'اردیبهشت',
      'خرداد',
      'تیر',
      'مرداد',
      'شهریور',
      'مهر',
      'آبان',
      'آذر',
      'دی',
      'بهمن',
      'اسفند',
    ];
    final latin = '$jalaliDay ${monthNames[jalaliMonth - 1]} $jalaliYear';
    return latin.replaceAllMapped(RegExp(r'\d'), (match) {
      const digits = '۰۱۲۳۴۵۶۷۸۹';
      return digits[int.parse(match[0]!)];
    });
  }

  static String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  static String? _connectionHealth(VpnNode? node, AppStrings strings) {
    if (node == null) return null;
    if (node.lastProbe == null) {
      return '${strings.ping} ${strings.unavailable}';
    }
    final age = DateTime.now().difference(node.lastProbe!);
    if (age.isNegative || age > const Duration(minutes: 2)) {
      return '${strings.ping} ${strings.unavailable}';
    }
    final latency = node.authoritativeLatency;
    final latencyText = latency != null && latency.inMilliseconds > 0
        ? '${latency.inMilliseconds} ms'
        : strings.unavailable;
    final observations = node.successCount + node.failureCount;
    final healthLabel = observations == 0
        ? strings.stabilityUnavailable
        : observations > 0 &&
              node.health == NodeHealth.healthy &&
              node.stabilityScore >= .7 &&
              latency != null &&
              latency <= const Duration(milliseconds: 1500)
        ? strings.stable
        : strings.unstable;
    return '${strings.ping} $latencyText · $healthLabel';
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({
    required this.uploadBytes,
    required this.downloadBytes,
    required this.quota,
    required this.strings,
    required this.isPersian,
  });

  final int? uploadBytes;
  final int? downloadBytes;
  final QuotaSnapshot quota;
  final AppStrings strings;
  final bool isPersian;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final used = quota.usedBytes;
    final total = quota.totalBytes;
    final remaining = quota.unlimited
        ? strings.unlimited
        : quota.remainingBytes == null
        ? strings.unavailable
        : HomeScreen._formatBytes(quota.remainingBytes!);
    final sessionTotal = uploadBytes == null || downloadBytes == null
        ? null
        : uploadBytes! > 0x7fffffffffffffff - downloadBytes!
        ? null
        : uploadBytes! + downloadBytes!;
    final progress =
        !quota.unlimited && total != null && total > 0 && used != null
        ? (used / total).clamp(0.0, 1.0).toDouble()
        : null;
    final direction = isPersian ? TextDirection.rtl : TextDirection.ltr;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: isPersian
          ? 'مصرف نشست و سهمیه اشتراک'
          : 'Session and subscription usage',
      child: Container(
        key: const ValueKey('unified-usage-card'),
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xE60A1C2B)
              : Colors.white.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.primary.withValues(alpha: .13)),
          boxShadow: [
            if (Theme.of(context).brightness == Brightness.light)
              BoxShadow(
                color: const Color(0xFF183B54).withValues(alpha: .045),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: _textMotionDuration(context),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              layoutBuilder: (currentChild, previousChildren) =>
                  currentChild ?? const SizedBox.shrink(),
              child: Directionality(
                key: ValueKey('session-block-${isPersian ? 'fa' : 'en'}'),
                textDirection: direction,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AnimatedLabel(
                      strings.thisSession,
                      transitionKey: isPersian ? 'fa' : 'en',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    _AnimatedLabel(
                      sessionTotal == null
                          ? strings.currentUsage
                          : HomeScreen._formatBytes(sessionTotal),
                      transitionKey: isPersian ? 'fa' : 'en',
                      keepOutgoing: true,
                      textAlign: TextAlign.start,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _TrafficValue(
                          icon: Icons.arrow_downward_rounded,
                          semanticLabel: strings.downloaded,
                          transitionKey: isPersian ? 'fa' : 'en',
                          value: downloadBytes == null
                              ? strings.download
                              : HomeScreen._formatBytes(downloadBytes!),
                        ),
                        const SizedBox(width: 22),
                        _TrafficValue(
                          icon: Icons.arrow_upward_rounded,
                          semanticLabel: strings.uploaded,
                          transitionKey: isPersian ? 'fa' : 'en',
                          value: uploadBytes == null
                              ? strings.upload
                              : HomeScreen._formatBytes(uploadBytes!),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 11),
            ExcludeSemantics(
              child: Divider(
                height: 1,
                thickness: 1,
                color: colors.outlineVariant.withValues(alpha: .48),
              ),
            ),
            const SizedBox(height: 10),
            Directionality(
              textDirection: direction,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _QuotaValue(
                      label: strings.totalUsage,
                      value: used == null
                          ? strings.unavailable
                          : HomeScreen._formatBytes(used),
                      alignment: TextAlign.start,
                      transitionKey: isPersian ? 'fa' : 'en',
                    ),
                  ),
                  Expanded(
                    child: _QuotaValue(
                      label: strings.remaining,
                      value: remaining,
                      alignment: TextAlign.end,
                      transitionKey: isPersian ? 'fa' : 'en',
                    ),
                  ),
                ],
              ),
            ),
            if (progress != null) ...[
              const SizedBox(height: 9),
              ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: colors.primary.withValues(alpha: .13),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF31D393)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TrafficValue extends StatelessWidget {
  const _TrafficValue({
    required this.icon,
    required this.semanticLabel,
    required this.value,
    this.transitionKey,
  });
  final IconData icon;
  final String semanticLabel;
  final String value;
  final Object? transitionKey;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$semanticLabel: $value',
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 3),
          SizedBox(
            width: 72,
            child: _AnimatedLabel(
              value,
              transitionKey: transitionKey,
              keepOutgoing: true,
              maxLines: 1,
              // Keep the arrow/value row anchored while the placeholder fades
              // out and the first numeric sample fades in.
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}

class _QuotaValue extends StatelessWidget {
  const _QuotaValue({
    required this.label,
    required this.value,
    required this.alignment,
    this.transitionKey,
  });

  final String label;
  final String value;
  final TextAlign alignment;
  final Object? transitionKey;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label: $value',
    child: ExcludeSemantics(
      child: Column(
        crossAxisAlignment: alignment == TextAlign.start
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          _AnimatedLabel(
            label,
            transitionKey: transitionKey,
            textAlign: alignment,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          _AnimatedLabel(
            value,
            transitionKey: transitionKey,
            textAlign: alignment,
            maxLines: 1,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    ),
  );
}

class _SubscriptionExpiryTile extends StatelessWidget {
  const _SubscriptionExpiryTile({
    super.key,
    required this.name,
    required this.nameKey,
    required this.expiry,
    required this.textDirection,
    required this.onTap,
  });

  final String name;
  final Key nameKey;
  final String expiry;
  final TextDirection textDirection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Ink(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: dark
                  ? const [Color(0xFF071A2C), Color(0xFF11304A)]
                  : const [Color(0xFFD8F2FF), Color(0xFFEAF8FF)],
            ),
            border: Border.all(
              color: dark
                  ? const Color(0xFF1B6684).withValues(alpha: .7)
                  : const Color(0xFF74CFF5).withValues(alpha: .72),
            ),
            boxShadow: [
              BoxShadow(
                color: colors.primary.withValues(alpha: dark ? .20 : .12),
                blurRadius: 12,
                spreadRadius: .2,
              ),
            ],
            borderRadius: BorderRadius.circular(17),
          ),
          child: AnimatedSwitcher(
            duration: _textMotionDuration(context),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: Directionality(
              key: ValueKey('$name-$expiry'),
              textDirection: textDirection,
              child: Row(
                children: [
                  Icon(Icons.subscriptions_outlined, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Directionality(
                      textDirection: textDirection,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedSwitcher(
                            duration: _textMotionDuration(context),
                            child: Text(
                              name,
                              key: nameKey,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          _AnimatedLabel(
                            expiry,
                            maxLines: 1,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    textDirection == TextDirection.rtl
                        ? Icons.chevron_left_rounded
                        : Icons.chevron_right_rounded,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MethodButton extends StatelessWidget {
  const _MethodButton({
    required this.method,
    required this.persian,
    required this.onTap,
  });
  final ConnectionMethod? method;
  final bool persian;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: persian ? 'انتخاب روش اتصال' : 'Select connection method',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Ink(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: colors.primary.withValues(alpha: .35)),
              boxShadow: [
                BoxShadow(
                  color: colors.shadow.withValues(alpha: .14),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.route_rounded,
                    color: colors.primary,
                    size: method == null ? 27 : 22,
                  ),
                  if (method != null)
                    Text(
                      method == ConnectionMethod.hysteria2
                          ? 'HY2'
                          : method!.label,
                      style: TextStyle(
                        fontSize: 10,
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DestinationButton extends StatelessWidget {
  const _DestinationButton({required this.selection, required this.onTap});
  final DestinationSelection selection;
  final VoidCallback onTap;

  String _flag(String? code) {
    if (code == null || code.length != 2) return '🌐';
    return String.fromCharCodes(
      code.toUpperCase().codeUnits.map((c) => 0x1F1E6 + c - 65),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Ink(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: colors.primary.withValues(alpha: .35)),
            boxShadow: [
              BoxShadow(
                color: colors.shadow.withValues(alpha: .14),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: selection.isAuto
                ? Icon(Icons.public_rounded, color: colors.primary, size: 27)
                : Text(
                    _flag(selection.countryCode),
                    style: const TextStyle(fontSize: 25),
                  ),
          ),
        ),
      ),
    );
  }
}

class _SplitTunnelingCard extends StatelessWidget {
  const _SplitTunnelingCard({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: colors.surfaceContainerHighest.withValues(alpha: .62),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: AnimatedSwitcher(
              duration: _textMotionDuration(context),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: Padding(
                key: ValueKey(title),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 5,
                ),
                child: Directionality(
                  textDirection: isRtl ? TextDirection.rtl : TextDirection.ltr,
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: colors.primary.withValues(alpha: .16),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.grid_view_rounded,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Directionality(
                          textDirection: isRtl
                              ? TextDirection.rtl
                              : TextDirection.ltr,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _AnimatedLabel(
                                title,
                                maxLines: 1,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Icon(
                        isRtl
                            ? Icons.chevron_left_rounded
                            : Icons.chevron_right_rounded,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LanguageButton extends StatelessWidget {
  const _LanguageButton({
    required this.localeCode,
    required this.tooltip,
    required this.onPressed,
  });

  final String localeCode;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: colors.surfaceContainerHighest.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 38,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.language_rounded, size: 20, color: colors.primary),
                  const SizedBox(width: 5),
                  AnimatedSwitcher(
                    duration: _textMotionDuration(context),
                    child: Text(
                      localeCode,
                      key: ValueKey(localeCode),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: .3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle({
    required this.isDark,
    required this.tooltip,
    required this.onPressed,
  });

  final bool isDark;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: tooltip,
      value: isDark ? 'Dark' : 'Light',
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(22),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              width: 76,
              height: 38,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  colors: dark
                      ? const [Color(0xFF071A2C), Color(0xFF11304A)]
                      : const [Color(0xFFD8F2FF), Color(0xFFEAF8FF)],
                ),
                border: Border.all(
                  color: dark
                      ? const Color(0xFF1B6684).withValues(alpha: .7)
                      : const Color(0xFF74CFF5).withValues(alpha: .72),
                ),
                boxShadow: [
                  BoxShadow(
                    color: colors.primary.withValues(alpha: dark ? .20 : .12),
                    blurRadius: 12,
                    spreadRadius: .2,
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: isDark ? 5 : null,
                    right: isDark ? null : 5,
                    top: 6,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: Icon(
                        isDark
                            ? Icons.wb_sunny_rounded
                            : Icons.nightlight_round,
                        key: ValueKey(isDark),
                        size: 17,
                        color: dark
                            ? const Color(0xFF50C8F2)
                            : const Color(0xFF5A8EA7),
                      ),
                    ),
                  ),
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutBack,
                    left: isDark ? null : 0,
                    right: isDark ? 0 : null,
                    top: 0,
                    child: Container(
                      width: 29,
                      height: 29,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: isDark
                            ? const LinearGradient(
                                colors: [Color(0xFF45E2FF), Color(0xFF08AEEA)],
                              )
                            : const LinearGradient(
                                colors: [Colors.white, Color(0xFFF2FBFF)],
                              ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                (isDark
                                        ? const Color(0xFF00BFEA)
                                        : const Color(0xFF6BB9D8))
                                    .withValues(alpha: .30),
                            blurRadius: 9,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        transitionBuilder: (child, animation) =>
                            ScaleTransition(
                              scale: animation,
                              child: FadeTransition(
                                opacity: animation,
                                child: child,
                              ),
                            ),
                        child: Icon(
                          isDark
                              ? Icons.nightlight_round
                              : Icons.wb_sunny_rounded,
                          key: ValueKey(isDark),
                          size: 17,
                          color: isDark
                              ? const Color(0xFF06233A)
                              : const Color(0xFF28A9E8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnimatedLabel extends StatefulWidget {
  const _AnimatedLabel(
    this.text, {
    this.style,
    this.textAlign,
    this.maxLines,
    this.transitionKey,
    this.keepOutgoing = false,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final Object? transitionKey;
  final bool keepOutgoing;

  @override
  State<_AnimatedLabel> createState() => _AnimatedLabelState();
}

class _AnimatedLabelState extends State<_AnimatedLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
    value: 1,
  );
  late String _from = widget.text;
  late String _to = widget.text;
  Object? _identity;

  @override
  void initState() {
    super.initState();
    _identity = (widget.transitionKey, widget.text);
  }

  @override
  void didUpdateWidget(covariant _AnimatedLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIdentity = (widget.transitionKey, widget.text);
    if (nextIdentity == _identity) return;
    _identity = nextIdentity;
    _from = oldWidget.text;
    _to = widget.text;
    if (_textMotionDuration(context) == Duration.zero) {
      _controller.value = 1;
    } else {
      _controller
        ..duration = _textMotionDuration(context)
        ..forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _text(String value) => Text(
    value,
    style: widget.style,
    textAlign: widget.textAlign,
    maxLines: widget.maxLines,
    overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) {
      final progress = _controller.value;
      if (progress < .5) {
        return Opacity(opacity: 1 - progress * 2, child: _text(_from));
      }
      return Opacity(opacity: (progress - .5) * 2, child: _text(_to));
    },
  );
}
