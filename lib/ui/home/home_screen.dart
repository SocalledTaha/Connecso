import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'dart:ui' as ui;
import 'dart:async';

import '../../domain/models/connection_state.dart';
import '../../domain/models/vpn_node.dart';
import '../../domain/models/destination_selection.dart';
import '../../domain/services/location_resolver.dart';
import '../../domain/services/country_lookup.dart';
import '../../platform/android/xray_proxy_core.dart';
import '../../domain/services/usage_service.dart';
import '../../data/repositories/saved_subscriptions.dart';
import '../../data/parsers/subscription_parser.dart';
import '../../l10n/app_strings.dart';
import '../settings/subscription_manager_sheet.dart';
import '../widgets/connection_scene.dart';
import '../widgets/app_notice.dart';
import '../widgets/swipe_dismiss_layer.dart';
import '../../prototypes/responsive_globe.dart';
import 'qr_import_screen.dart';
import 'destination_country_selector.dart';
import 'connection_method_selector.dart';
import '../../domain/models/connection_method.dart';

Duration _textMotionDuration(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations == true
    ? Duration.zero
    : const Duration(milliseconds: 1000);

enum AboutUpdateStatus { checking, upToDate, available, error }

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
    this.appVersion = '0.0.0',
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
    this.onPingDestinations,
    this.onCancelDestinationPings,
    this.favoriteDestinationKeys = const {},
    this.recentDestinationCountryCode,
    this.onDestinationFavoriteChanged,
    this.connectionMethod,
    this.onConnectionMethodChanged,
    this.performanceMode = false,
    this.onPerformanceModeChanged,
    this.onAddQuickSettingsTile,
    this.onAddHomeScreenWidget,
    this.onSpeedTest,
    this.speedTestRunning = false,
    this.speedTestMbps,
    this.speedTestError,
    this.refreshingActiveSubscription = false,
    this.canRefreshActiveSubscription = false,
    this.onRefreshActiveSubscription,
    this.readSavedSubscriptions,
    this.autoUpdateEnabled = false,
    this.updateUseActiveRoute = true,
    this.updateIncludePrerelease = true,
    this.onAutoUpdateChanged,
    this.onUpdateRouteChanged,
    this.onUpdatePrereleaseChanged,
    this.onCheckUpdates,
    super.key,
  });

  final String appVersion;
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
  final bool performanceMode;
  final Future<void> Function(bool)? onPerformanceModeChanged;
  final Future<void> Function()? onAddQuickSettingsTile;
  final Future<void> Function()? onAddHomeScreenWidget;
  final Future<void> Function()? onSpeedTest;
  final bool speedTestRunning;
  final double? speedTestMbps;
  final String? speedTestError;
  final bool refreshingActiveSubscription;
  final bool canRefreshActiveSubscription;
  final Future<void> Function()? onRefreshActiveSubscription;
  List<VpnNode> get destinationNodes =>
      nodes.where((node) => node.enabled).toList();
  final DestinationSelection destinationSelection;
  final Future<void> Function(DestinationSelection)?
  onDestinationSelectionChanged;
  final DestinationPingCallback? onPingDestinations;
  final Future<void> Function()? onCancelDestinationPings;
  final Set<String> favoriteDestinationKeys;
  final String? recentDestinationCountryCode;
  final Future<void> Function(String, bool)? onDestinationFavoriteChanged;
  final List<SavedSubscription> Function()? readSavedSubscriptions;
  final bool autoUpdateEnabled;
  final bool updateUseActiveRoute;
  final bool updateIncludePrerelease;
  final Future<void> Function(bool)? onAutoUpdateChanged;
  final Future<void> Function(bool)? onUpdateRouteChanged;
  final Future<void> Function(bool)? onUpdatePrereleaseChanged;
  final Future<void> Function(
    BuildContext,
    bool,
    ValueChanged<AboutUpdateStatus>,
  )?
  onCheckUpdates;

  void _showUpdates(BuildContext context) {
    final isFa = language.languageCode == 'fa';
    final dark = Theme.of(context).brightness == Brightness.dark;
    var autoEnabled = autoUpdateEnabled;
    var useActiveRoute = updateUseActiveRoute;
    var includePrerelease = updateIncludePrerelease;
    var status = AboutUpdateStatus.upToDate;
    var checking = false;
    var statusVisible = false;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (pageContext) => Scaffold(
          appBar: AppBar(
            title: Text(isFa ? 'به‌روزرسانی‌ها' : 'Updates'),
            leading: IconButton(
              tooltip: isFa ? 'بازگشت' : 'Back',
              onPressed: () => Navigator.pop(pageContext),
              icon: Icon(
                isFa ? Icons.arrow_forward_rounded : Icons.arrow_back_rounded,
              ),
            ),
          ),
          body: SafeArea(
            child: StatefulBuilder(
              builder: (context, refresh) => SingleChildScrollView(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _SettingsIcon(
                          icon: Icons.system_update_alt_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isFa ? 'به‌روزرسانی‌ها' : 'Updates',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text(
                                isFa
                                    ? 'نسخهٔ جدید Connecso را بررسی کنید.'
                                    : 'Check for the latest Connecso release.',
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    _settingsSectionTitle(
                      context,
                      isFa ? 'ترجیحات' : 'Preferences',
                    ),
                    const SizedBox(height: 6),
                    _SettingsGroup(
                      children: [
                        SwitchListTile(
                          secondary: const _SettingsIcon(
                            icon: Icons.autorenew_rounded,
                          ),
                          title: Text(
                            isFa
                                ? 'بررسی خودکار نسخهٔ جدید'
                                : 'Check for updates automatically',
                          ),
                          subtitle: Text(
                            isFa
                                ? 'هنگام بازشدن برنامه نسخهٔ تازه بررسی می‌شود.'
                                : 'Check for a newer version when the app opens.',
                          ),
                          value: autoEnabled,
                          onChanged: (value) {
                            autoEnabled = value;
                            refresh(() {});
                            unawaited(
                              onAutoUpdateChanged?.call(value) ??
                                  Future<void>.value(),
                            );
                          },
                        ),
                        const Divider(height: 1, indent: 68),
                        SwitchListTile(
                          secondary: const _SettingsIcon(
                            icon: Icons.vpn_lock_rounded,
                          ),
                          title: Text(
                            isFa
                                ? 'استفاده از مسیر VPN فعال'
                                : 'Use the active VPN route',
                          ),
                          subtitle: Text(
                            isFa
                                ? 'بررسی و دریافت به‌روزرسانی از مسیر امن انجام می‌شود.'
                                : 'Route update checks and downloads through the active VPN.',
                          ),
                          value: useActiveRoute,
                          onChanged: (value) {
                            useActiveRoute = value;
                            refresh(() {});
                            unawaited(
                              onUpdateRouteChanged?.call(value) ??
                                  Future<void>.value(),
                            );
                          },
                        ),
                        const Divider(height: 1, indent: 68),
                        SwitchListTile(
                          secondary: const _SettingsIcon(
                            icon: Icons.science_outlined,
                          ),
                          title: Text(
                            isFa
                                ? 'نسخه‌های پیش‌انتشار'
                                : 'Include prerelease versions',
                          ),
                          subtitle: Text(
                            isFa
                                ? 'نسخه‌های آزمایشی هم در بررسی نمایش داده شوند.'
                                : 'Include beta and preview releases in update checks.',
                          ),
                          value: includePrerelease,
                          onChanged: (value) {
                            includePrerelease = value;
                            refresh(() {});
                            unawaited(
                              onUpdatePrereleaseChanged?.call(value) ??
                                  Future<void>.value(),
                            );
                          },
                        ),
                      ],
                    ),
                    if (statusVisible) ...[
                      const SizedBox(height: 12),
                      _AboutUpdateStatusLine(
                        status: status,
                        persian: isFa,
                        dark: dark,
                      ),
                    ],
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: checking || onCheckUpdates == null
                            ? null
                            : () async {
                                checking = true;
                                status = AboutUpdateStatus.checking;
                                statusVisible = true;
                                refresh(() {});
                                try {
                                  await onCheckUpdates!.call(
                                    pageContext,
                                    includePrerelease,
                                    (value) {
                                      status = value;
                                      statusVisible = true;
                                      if (pageContext.mounted) refresh(() {});
                                    },
                                  );
                                } finally {
                                  checking = false;
                                  if (pageContext.mounted) refresh(() {});
                                }
                              },
                        icon: checking
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded),
                        label: Text(switch (status) {
                          AboutUpdateStatus.checking =>
                            isFa ? 'در حال بررسی…' : 'Checking…',
                          AboutUpdateStatus.upToDate =>
                            isFa ? 'بررسی نسخهٔ جدید' : 'Check for updates',
                          AboutUpdateStatus.available =>
                            isFa ? 'نسخهٔ جدید پیدا شد' : 'Update available',
                          AboutUpdateStatus.error =>
                            isFa ? 'تلاش دوباره' : 'Try again',
                        }),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    final pageContext = context;
    final isFa = language.languageCode == 'fa';
    var performanceEnabled = performanceMode;
    const secureStorage = FlutterSecureStorage();
    var showBatteryTip =
        await secureStorage.read(key: 'hide_battery_optimization_tip_v1') !=
        'true';
    if (!context.mounted) return;
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (dialogContext, animation, secondaryAnimation) => SwipeDismissLayer(
          direction: SwipeCloseDirection.right,
          child: Scaffold(
            body: SafeArea(
              child: StatefulBuilder(
                builder: (context, refresh) => Stack(
                  children: [
                    Positioned.fill(
                      child: SingleChildScrollView(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          20,
                          62,
                          20,
                          28,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              isFa ? 'تنظیمات' : 'Settings',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isFa
                                  ? 'تنظیمات برنامه و دسترسی‌های سریع'
                                  : 'App preferences and quick access',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 22),
                            _settingsSectionTitle(
                              context,
                              isFa ? 'عملکرد' : 'App behavior',
                            ),
                            const SizedBox(height: 6),
                            _SettingsGroup(
                              children: [
                                SwitchListTile(
                                  secondary: const _SettingsIcon(
                                    icon: Icons.bolt_rounded,
                                  ),
                                  title: Text(
                                    isFa ? 'حالت عملکرد' : 'Performance mode',
                                  ),
                                  subtitle: Text(
                                    isFa
                                        ? 'انیمیشن‌ها را کاهش می‌دهد تا مصرف منابع کمتر شود.'
                                        : 'Reduces animation and visual work to save resources.',
                                  ),
                                  value: performanceEnabled,
                                  onChanged: (value) {
                                    performanceEnabled = value;
                                    refresh(() {});
                                    onPerformanceModeChanged?.call(value);
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            _settingsSectionTitle(
                              context,
                              isFa ? 'دسترسی سریع' : 'Quick access',
                            ),
                            const SizedBox(height: 6),
                            _SettingsGroup(
                              children: [
                                if (showBatteryTip) ...[
                                  _settingsActionTile(
                                    context,
                                    icon: Icons.battery_saver_rounded,
                                    title: isFa
                                        ? 'تنظیم محدودیت باتری'
                                        : 'Set battery usage to unrestricted',
                                    subtitle: isFa
                                        ? 'برای جلوگیری از توقف اتصال، محدودیت باتری Connecso را بردارید.'
                                        : 'Allow Connecso to run without battery restrictions for reliable background connections.',
                                    onTap: () async {
                                      try {
                                        await const MethodChannel(
                                          'com.connecso.client/vpn',
                                        ).invokeMethod<void>(
                                          'openBatterySettings',
                                        );
                                      } on PlatformException {
                                        // Keep Settings available even when this Android build
                                        // does not expose a dedicated battery page.
                                      }
                                    },
                                  ),
                                  ListTile(
                                    dense: true,
                                    leading: const SizedBox(width: 40),
                                    title: Text(
                                      isFa
                                          ? 'دیگر این بخش را نشان نده'
                                          : "Don't show this section again",
                                    ),
                                    onTap: () async {
                                      await secureStorage.write(
                                        key: 'hide_battery_optimization_tip_v1',
                                        value: 'true',
                                      );
                                      showBatteryTip = false;
                                      refresh(() {});
                                    },
                                  ),
                                  const Divider(height: 1, indent: 68),
                                ],
                                _settingsActionTile(
                                  context,
                                  icon: Icons.dashboard_customize_rounded,
                                  title: isFa
                                      ? 'کاشی تنظیمات سریع'
                                      : 'Quick Settings tile',
                                  subtitle: isFa
                                      ? 'اتصال را از پنل اعلان‌ها کنترل کنید.'
                                      : 'Control your connection from the notification shade.',
                                  onTap: onAddQuickSettingsTile == null
                                      ? null
                                      : () async {
                                          Navigator.pop(dialogContext);
                                          await onAddQuickSettingsTile!.call();
                                        },
                                ),
                                const Divider(height: 1, indent: 68),
                                _settingsActionTile(
                                  context,
                                  icon: Icons.widgets_rounded,
                                  title: isFa
                                      ? 'ویجت صفحهٔ اصلی'
                                      : 'Home screen widget',
                                  subtitle: isFa
                                      ? 'اتصال و مصرف اشتراک را روی صفحه ببینید.'
                                      : 'View connection and subscription usage on your home screen.',
                                  onTap: onAddHomeScreenWidget == null
                                      ? null
                                      : () async {
                                          Navigator.pop(dialogContext);
                                          await onAddHomeScreenWidget!.call();
                                        },
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            _settingsSectionTitle(
                              context,
                              isFa ? 'دربارهٔ برنامه' : 'About this app',
                            ),
                            const SizedBox(height: 6),
                            _SettingsGroup(
                              children: [
                                Padding(
                                  padding: const EdgeInsetsDirectional.fromSTEB(
                                    16,
                                    14,
                                    16,
                                    12,
                                  ),
                                  child: Text.rich(
                                    TextSpan(
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                      children: [
                                        TextSpan(
                                          text: isFa
                                              ? 'Connecso · نسخه $appVersion'
                                              : 'Connecso · Version $appVersion',
                                        ),
                                        const TextSpan(text: '   •   '),
                                        TextSpan(
                                          text: isFa
                                              ? 'Xray-core ${XrayProxyCore.releaseVersion}'
                                              : 'Xray-core ${XrayProxyCore.releaseVersion}',
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const Divider(height: 1, indent: 68),
                                _settingsActionTile(
                                  context,
                                  icon: Icons.system_update_alt_rounded,
                                  title: isFa ? 'به‌روزرسانی‌ها' : 'Updates',
                                  subtitle: isFa
                                      ? 'بررسی خودکار، مسیر دریافت و نسخه‌های آزمایشی'
                                      : 'Automatic checks, download route and prerelease options',
                                  onTap: () {
                                    Navigator.pop(dialogContext);
                                    _showUpdates(pageContext);
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            _communityFooter(context, isFa),
                          ],
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      top: 4,
                      end: 8,
                      child: IconButton.filledTonal(
                        tooltip: isFa ? 'بستن' : 'Close settings',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: curved.drive(
                Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero),
              ),
              child: child,
            ),
          );
        },
      ),
    );
  }

  Widget _settingsActionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) => ListTile(
    minVerticalPadding: 12,
    leading: _SettingsIcon(icon: icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    trailing: Icon(
      language.languageCode == 'fa'
          ? Icons.chevron_left_rounded
          : Icons.chevron_right_rounded,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    onTap: onTap,
  );

  Widget _communityFooter(BuildContext context, bool isFa) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          isFa ? 'ساخته‌شده توسط Taha' : 'Created by Taha',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          isFa
              ? 'پروژهٔ Connecso را دنبال کنید'
              : 'Follow the Connecso project',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => unawaited(
                _openAboutUrl(
                  'https://github.com/SocalledTaha/connecso-client',
                ),
              ),
              icon: Image.asset(
                Theme.of(context).brightness == Brightness.dark
                    ? 'assets/icons/github_about_dark.webp'
                    : 'assets/icons/github_about_light.webp',
                width: 20,
                height: 20,
              ),
              label: const Text('GitHub'),
            ),
            OutlinedButton.icon(
              onPressed: () =>
                  unawaited(_openAboutUrl('https://t.me/ConnecsoProjects')),
              icon: Image.asset(
                'assets/icons/telegram_about.webp',
                width: 20,
                height: 20,
              ),
              label: const Text('Telegram'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Connecso · $appVersion',
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _settingsSectionTitle(BuildContext context, String title) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 4, top: 4, bottom: 2),
    child: Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w800,
        letterSpacing: .8,
      ),
    ),
  );

  Future<void> _openAboutUrl(String url) async {
    const channel = MethodChannel('com.connecso.client/vpn');
    try {
      await channel.invokeMethod<void>('openExternalUrl', {'url': url});
    } on PlatformException {
      // The About panel remains usable if no app can open a social link.
    }
  }

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
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: splitTunnelingBuilder,
          fullscreenDialog: true,
        ),
      );

  Future<void> _refreshActiveSubscription(BuildContext context) async {
    try {
      await onRefreshActiveSubscription?.call();
      if (context.mounted) {
        _showWideNotice(
          context,
          language.languageCode == 'fa'
              ? 'اشتراک با موفقیت به‌روزرسانی شد.'
              : 'Subscription refreshed successfully.',
        );
      }
    } catch (_) {
      if (context.mounted) {
        _showWideNotice(
          context,
          language.languageCode == 'fa'
              ? 'به‌روزرسانی اشتراک ناموفق بود.'
              : 'Subscription refresh failed.',
        );
      }
    }
  }

  Future<void> _manageSubscriptions(
    BuildContext context,
    AppStrings strings,
  ) => showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: strings.subscriptions,
    barrierColor: Colors.transparent,
    transitionDuration: performanceMode
        ? Duration.zero
        : const Duration(milliseconds: 240),
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
                child: performanceMode
                    ? Material(
                        color: colors.surfaceContainerHighest,
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
                      )
                    : BackdropFilter(
                        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                        child: Material(
                          color: colors.surfaceContainerHighest.withValues(
                            alpha: .88,
                          ),
                          borderRadius: BorderRadius.circular(24),
                          child: ValueListenableBuilder<int>(
                            valueListenable: subscriptionRevision,
                            builder: (context, _, __) =>
                                SubscriptionManagerSheet(
                                  language: language,
                                  savedSubscriptions:
                                      readSavedSubscriptions?.call() ??
                                      savedSubscriptions,
                                  activeSubscriptionId: activeSubscriptionId,
                                  canManageSubscriptions:
                                      canManageSubscriptions,
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
      if (performanceMode) return child;
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

  Future<void> _chooseDestination(BuildContext context) async {
    final selected = await Navigator.of(context).push<DestinationSelection>(
      PageRouteBuilder<DestinationSelection>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (pageContext, animation, secondaryAnimation) =>
            DestinationCountrySelector(
              nodes: destinationNodes,
              selection: destinationSelection,
              persian: language.languageCode == 'fa',
              favoriteDestinationKeys: favoriteDestinationKeys,
              recentCountryCode: recentDestinationCountryCode,
              onToggleFavorite: onDestinationFavoriteChanged,
              onPingDestinations: onPingDestinations,
              onCancelDestinationPings: onCancelDestinationPings,
              onSelected: (value) => Navigator.of(pageContext).pop(value),
            ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final slide = Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic));
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: animation.drive(slide),
              child: child,
            ),
          );
        },
      ),
    );
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
                const SizedBox(width: 8),
                IconButton(
                  tooltip: isPersian ? 'تنظیمات' : 'Settings',
                  onPressed: () => _showSettings(context),
                  icon: const Icon(Icons.settings_outlined),
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

  Widget _buildDashboardBody(BuildContext context, AppStrings strings) {
    final isPersian = language.languageCode == 'fa';
    final dark = Theme.of(context).brightness == Brightness.dark;
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
    final shortcutLabel = isPersian ? 'تنظیمات' : 'Settings';
    final activeNodeCountry = activeNode?.country?.trim() ?? '';
    final activeNodeCountryCode = LocationResolver.canonicalCountryCode(
      '${activeNode?.countryCode ?? ''} $activeNodeCountry',
    );
    final actualDestinationCode = phase == ConnectionPhase.connected
        ? activeNodeCountryCode
        : '';
    final actualDestinationAvailable = actualDestinationCode.isNotEmpty;
    final selectedCode = destinationSelection.isAuto
        ? (actualDestinationAvailable ? actualDestinationCode : '')
        : LocationResolver.canonicalCountryCode(
            destinationSelection.countryCode,
          );
    String? selectedCountryName = destinationSelection.isAuto
        ? (phase == ConnectionPhase.connected && actualDestinationAvailable
              ? LocationResolver.forCountryCode(
                      actualDestinationCode,
                    )?.country ??
                    (activeNodeCountry.isNotEmpty ? activeNodeCountry : null)
              : null)
        : null;
    if (!destinationSelection.isAuto) {
      for (final node in destinationNodes) {
        if (LocationResolver.canonicalCountryCode(
              node.countryCode ?? node.country,
            ) ==
            selectedCode) {
          selectedCountryName =
              const LocationResolver().resolve(node)?.country ?? node.country;
          break;
        }
      }
    }
    if (selectedCountryName == null && selectedCode.isNotEmpty) {
      for (final country in offlineCountries) {
        if (country.code == selectedCode) {
          selectedCountryName = country.displayName;
          break;
        }
      }
    }
    final protocolNode = phase == ConnectionPhase.connected
        ? activeNode
        : destinationNodes.cast<VpnNode?>().firstWhere(
            (node) =>
                node != null &&
                LocationResolver.canonicalCountryCode(
                      node.countryCode ?? node.country,
                    ) ==
                    selectedCode,
            orElse: () => null,
          );
    final destinationProtocol = protocolNode?.protocol.name.toUpperCase();

    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF061522) : const Color(0xFFEAF2F6),
      ),
      child: Stack(
        children: [
          if (!performanceMode)
            Positioned.fill(
              child: IgnorePointer(
                child: ResponsiveGlobe(
                  // Keep the highlighted exit above the power control rather
                  // than placing its marker under the button.
                  globeCenterYFraction: .30,
                  performanceMode: false,
                  lightMode: !dark,
                  sourceTarget:
                      _homeGlobeTarget(
                        LocationResolver.forCountryCode(sourceCountryCode),
                      ) ??
                      const GlobeTarget('Iran', 32.4, 53.7),
                  destinationTarget: _homeGlobeTarget(destination),
                ),
              ),
            ),
          SafeArea(
            child: CustomScrollView(
              physics: const ClampingScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  sliver: SliverList.list(
                    children: [
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: Row(
                          children: [
                            Image.asset(
                              dark
                                  ? 'assets/logos/connecso_logo_dark.png'
                                  : 'assets/logos/connecso_logo_light.png',
                              width: 30,
                              height: 37,
                              fit: BoxFit.contain,
                            ),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                strings.appName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            Transform.translate(
                              offset: const Offset(8, 0),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(26),
                                  border: Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                                  ),
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surface.withValues(alpha: .84),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _LanguageButton(
                                      localeCode: language.languageCode
                                          .toUpperCase(),
                                      tooltip: strings.language,
                                      onPressed: () => onLanguageChanged(
                                        Locale(isPersian ? 'en' : 'fa'),
                                      ),
                                    ),
                                    _ThemeToggle(
                                      isDark: dark,
                                      tooltip: strings.theme,
                                      onPressed: () => onThemeChanged(
                                        dark ? ThemeMode.light : ThemeMode.dark,
                                      ),
                                    ),
                                    _PerformanceModeButton(
                                      enabled: performanceMode,
                                      tooltip: isPersian
                                          ? 'حالت عملکرد'
                                          : 'Performance mode',
                                      onPressed:
                                          onPerformanceModeChanged == null
                                          ? null
                                          : () => onPerformanceModeChanged!(
                                              !performanceMode,
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Transform.translate(
                              offset: const Offset(20, 0),
                              child: Container(
                                width: 60,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  borderRadius: const BorderRadius.horizontal(
                                    left: Radius.circular(26),
                                  ),
                                ),
                                alignment: Alignment.centerLeft,
                                child: IconButton(
                                  tooltip: shortcutLabel,
                                  onPressed: () => _showSettings(context),
                                  icon: const Icon(Icons.settings_outlined),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      _SplitTunnelingCard(
                        title: strings.splitTunneling,
                        onTap: () => _showSplitTunneling(context, strings),
                      ),
                    ],
                  ),
                ),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        ConnectionStatusPanel(
                          phase: phase,
                          connectionLabel: strings.status(phase.name),
                          actionLabel: canCancelConnection
                              ? strings.cancelConnection
                              : busy
                              ? strings.connecting
                              : phase == ConnectionPhase.connected
                              ? strings.disconnected
                              : strings.connect,
                          onPressed: (!busy || canCancelConnection)
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
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: OutlinedButton(
                              onPressed:
                                  phase == ConnectionPhase.connected &&
                                      !speedTestRunning
                                  ? () => onSpeedTest?.call()
                                  : null,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 42),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                visualDensity: VisualDensity.standard,
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.onSurface,
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.surface,
                                side: BorderSide(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (speedTestRunning)
                                    const SizedBox.square(
                                      dimension: 17,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  else
                                    _AetherPulseIcon(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    ),
                                  const SizedBox(width: 8),
                                  Text(
                                    speedTestRunning
                                        ? (isPersian
                                              ? 'در حال سنجش…'
                                              : 'Testing…')
                                        : speedTestError != null
                                        ? (isPersian ? 'ناموفق' : 'Failed')
                                        : speedTestMbps != null
                                        ? '${speedTestMbps!.toStringAsFixed(1)} Mbps'
                                        : (isPersian
                                              ? 'تست سرعت'
                                              : 'Speed test'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 1),
                        _DestinationButton(
                          selection: destinationSelection,
                          actualDestination: destination,
                          countryName: selectedCountryName,
                          protocolName: destinationProtocol,
                          language: language,
                          onTap: () => _chooseDestination(context),
                        ),
                        const SizedBox(height: 8),
                        _UsageCard(
                          uploadBytes: sessionUploadBytes,
                          downloadBytes: sessionDownloadBytes,
                          quota: quota,
                          strings: strings,
                          isPersian: isPersian,
                        ),
                        const SizedBox(height: 8),
                        _SubscriptionExpiryTile(
                          key: const ValueKey('subscription-expiry-tile'),
                          name: activeSubscriptionName ?? strings.appName,
                          nameKey: ValueKey(
                            activeSubscriptionName ?? strings.appName,
                          ),
                          expiry: _subscriptionExpiry(
                            quota,
                            strings,
                            isPersian,
                          ),
                          textDirection: isPersian
                              ? TextDirection.rtl
                              : TextDirection.ltr,
                          onTap: () => _manageSubscriptions(context, strings),
                          onRefresh: canRefreshActiveSubscription
                              ? () => _refreshActiveSubscription(context)
                              : null,
                          refreshing: refreshingActiveSubscription,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmExit(BuildContext context) async {
    final isFa = language.languageCode == 'fa';
    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isFa ? 'خروج از برنامه؟' : 'Exit Connecso?'),
        content: Text(
          isFa
              ? 'می‌خواهید از برنامه خارج شوید؟'
              : 'Do you want to close the app?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(isFa ? 'ادامهٔ کار' : 'Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(isFa ? 'خروج' : 'Exit'),
          ),
        ],
      ),
    );
    if (shouldExit == true) await SystemNavigator.pop();
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
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmExit(context));
      },
      child: Scaffold(
        body: _SwipeNavigationLayer(
          onOpenSettings: () => _showSettings(context),
          onOpenDestinations: () => _chooseDestination(context),
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : nodes.isNotEmpty
                ? _buildDashboardBody(context, strings)
                : _emptySubscriptionBody(context, strings),
          ),
        ),
      ),
    );
  }

  static String _countryFlag(String? code) {
    return LocationResolver.flagForCode(code);
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
          color: MediaQuery.disableAnimationsOf(context)
              ? (Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF0A1C2B)
                    : Colors.white)
              : Theme.of(context).brightness == Brightness.dark
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
    required this.onRefresh,
    required this.refreshing,
  });

  final String name;
  final Key nameKey;
  final String expiry;
  final TextDirection textDirection;
  final VoidCallback onTap;
  final VoidCallback? onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final performanceMode = MediaQuery.disableAnimationsOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Ink(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: performanceMode ? colors.surfaceContainerHighest : null,
            gradient: performanceMode
                ? null
                : LinearGradient(
                    colors: dark
                        ? const [Color(0xFF071A2C), Color(0xFF11304A)]
                        : const [Color(0xFFD8F2FF), Color(0xFFEAF8FF)],
                  ),
            border: Border.all(
              color: performanceMode
                  ? colors.outlineVariant.withValues(alpha: .55)
                  : dark
                  ? const Color(0xFF1B6684).withValues(alpha: .7)
                  : const Color(0xFF74CFF5).withValues(alpha: .72),
            ),
            boxShadow: performanceMode
                ? const []
                : [
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
                  IconButton(
                    tooltip: textDirection == TextDirection.rtl
                        ? 'به‌روزرسانی اشتراک'
                        : 'Refresh subscription',
                    visualDensity: VisualDensity.compact,
                    onPressed: refreshing ? null : onRefresh,
                    icon: TickerMode(
                      // The ticker must be created below this override. A
                      // TickerMode returned from inside the icon is too low
                      // in the tree to affect its State's TickerProvider.
                      enabled: true,
                      child: _RotatingRefreshIcon(
                        refreshing: refreshing,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
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

class _RotatingRefreshIcon extends StatefulWidget {
  const _RotatingRefreshIcon({required this.refreshing, required this.color});

  final bool refreshing;
  final Color color;

  @override
  State<_RotatingRefreshIcon> createState() => _RotatingRefreshIconState();
}

class _RotatingRefreshIconState extends State<_RotatingRefreshIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
    // This is an operation progress cue; keep it moving in Performance Mode
    // even though decorative animations are suppressed elsewhere.
    animationBehavior: AnimationBehavior.preserve,
  );

  @override
  void initState() {
    super.initState();
    if (widget.refreshing) _rotation.repeat();
  }

  @override
  void didUpdateWidget(covariant _RotatingRefreshIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshing == oldWidget.refreshing) return;
    if (widget.refreshing) {
      _rotation.repeat();
    } else {
      _rotation
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _rotation,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Icon(Icons.refresh_rounded, color: widget.color),
    ),
  );
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
    final label = method == null
        ? (persian ? 'خودکار' : 'Auto')
        : method == ConnectionMethod.hysteria2
        ? 'HY2'
        : method!.label;
    return Tooltip(
      message: persian ? 'انتخاب روش اتصال' : 'Select connection method',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Ink(
            height: 44,
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Icon(Icons.route_rounded, color: colors.primary, size: 19),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.expand_more_rounded,
                    color: colors.onSurfaceVariant,
                    size: 18,
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

class _AetherPulseIcon extends StatelessWidget {
  const _AetherPulseIcon({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(18, 18),
    painter: _AetherPulsePainter(color),
  );
}

class _AetherPulsePainter extends CustomPainter {
  const _AetherPulsePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final path = Path()
      ..moveTo(3, 12)
      ..lineTo(7, 12)
      ..lineTo(10, 20)
      ..lineTo(14, 4)
      ..lineTo(17, 12)
      ..lineTo(21, 12);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _AetherPulsePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _DestinationButton extends StatelessWidget {
  const _DestinationButton({
    required this.selection,
    required this.actualDestination,
    required this.countryName,
    required this.protocolName,
    required this.language,
    required this.onTap,
  });
  final DestinationSelection selection;
  final DestinationLocation? actualDestination;
  final String? countryName;
  final String? protocolName;
  final Locale language;
  final VoidCallback onTap;

  String _flag(String? code) {
    return LocationResolver.flagForCode(code);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final code = selection.isAuto
        ? actualDestination?.countryCode
        : selection.countryCode;
    final isFa = language.languageCode == 'fa';
    final isAutoDisconnected = selection.isAuto && actualDestination == null;
    final country = isAutoDisconnected
        ? ''
        : (countryName ??
              actualDestination?.country ??
              (code ?? '').toUpperCase());
    final countryLabel = isAutoDisconnected || country.isEmpty
        ? (isFa ? 'انتخاب خودکار' : 'Auto Select a destination')
        : AppStrings(language).locationName(country, '');
    final label =
        countryLabel +
        (protocolName != null && !isAutoDisconnected ? ' · $protocolName' : '');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Ink(
          height: 44,
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(
              color: colors.outlineVariant.withValues(alpha: .5),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Text(
                  isAutoDisconnected ? '🌐' : _flag(code),
                  style: const TextStyle(fontSize: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(
                  Icons.expand_more_rounded,
                  color: colors.onSurfaceVariant,
                  size: 18,
                ),
              ],
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
    final performanceMode = MediaQuery.disableAnimationsOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: performanceMode ? 0 : 10,
          sigmaY: performanceMode ? 0 : 10,
        ),
        child: Material(
          color: performanceMode
              ? colors.surfaceContainerHighest
              : colors.surfaceContainerHighest.withValues(alpha: .62),
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
        color: MediaQuery.disableAnimationsOf(context)
            ? colors.surfaceContainerHighest
            : colors.surfaceContainerHighest.withValues(alpha: .62),
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
    final nextModeIcon = isDark
        ? Icons.wb_sunny_rounded
        : Icons.nightlight_round;
    return Semantics(
      button: true,
      label: tooltip,
      value: isDark ? 'Dark' : 'Light',
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          onPressed: onPressed,
          style: IconButton.styleFrom(
            fixedSize: const Size(42, 42),
            backgroundColor: colors.surfaceContainerHighest,
            foregroundColor: dark
                ? const Color(0xFF50C8F2)
                : const Color(0xFF258DBA),
          ),
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: Icon(nextModeIcon, key: ValueKey(nextModeIcon), size: 21),
          ),
        ),
      ),
    );
  }
}

class _SwipeNavigationLayer extends StatefulWidget {
  const _SwipeNavigationLayer({
    required this.child,
    required this.onOpenSettings,
    required this.onOpenDestinations,
  });

  final Widget child;
  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onOpenDestinations;

  @override
  State<_SwipeNavigationLayer> createState() => _SwipeNavigationLayerState();
}

class _SwipeNavigationLayerState extends State<_SwipeNavigationLayer> {
  Offset? _start;
  double _dragX = 0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (details) {
        final width = MediaQuery.sizeOf(context).width;
        final x = details.localPosition.dx;
        // Leave the outer 32 logical pixels to Android's system back gesture.
        if (x <= 32 || x >= width - 32) {
          _start = null;
          return;
        }
        _start = details.localPosition;
        _dragX = 0;
      },
      onHorizontalDragUpdate: (details) {
        if (_start == null) return;
        setState(() => _dragX += details.delta.dx);
      },
      onHorizontalDragEnd: (details) {
        final origin = _start;
        _start = null;
        if (origin == null) return;
        final velocity = details.primaryVelocity ?? 0;
        final distance = _dragX;
        if (velocity.abs() >= 300 || distance.abs() >= 64) {
          if ((velocity != 0 ? velocity : distance) < 0) {
            unawaited(_openRoute(widget.onOpenSettings));
          } else {
            unawaited(_openRoute(widget.onOpenDestinations));
          }
        } else {
          setState(() => _dragX = 0);
        }
      },
      onHorizontalDragCancel: () {
        _start = null;
        setState(() => _dragX = 0);
      },
      child: ClipRect(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: (_dragX.abs() / 20).clamp(0, 5),
            sigmaY: (_dragX.abs() / 20).clamp(0, 5),
          ),
          child: Transform.translate(
            offset: Offset(_dragX * .12, 0),
            child: widget.child,
          ),
        ),
      ),
    );
  }

  Future<void> _openRoute(Future<void> Function() open) async {
    try {
      await open();
    } finally {
      if (mounted) setState(() => _dragX = 0);
    }
  }
}

class _PerformanceModeButton extends StatelessWidget {
  const _PerformanceModeButton({
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });
  final bool enabled;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled ? accent.withValues(alpha: .16) : Colors.transparent,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: .42),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
          border: Border.all(
            color: enabled ? accent.withValues(alpha: .65) : Colors.transparent,
          ),
        ),
        child: IconButton(
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          icon: AnimatedScale(
            duration: const Duration(milliseconds: 260),
            scale: enabled ? 1.12 : 1.0,
            child: Icon(
              Icons.bolt_rounded,
              color: enabled
                  ? accent
                  : Theme.of(context).colorScheme.onSurfaceVariant,
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

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.outlineVariant.withValues(alpha: .72)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon({required this.icon, this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.primary;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: tint.withValues(alpha: .18)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: tint, size: 21),
    );
  }
}

class _AboutLinkRow extends StatelessWidget {
  const _AboutLinkRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _SettingsIcon(icon: icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Icon(
        Icons.open_in_new_rounded,
        size: 18,
        color: colors.primary,
      ),
      onTap: onTap,
    );
  }
}

class _AboutEngineCard extends StatelessWidget {
  const _AboutEngineCard({
    required this.dark,
    required this.title,
    required this.subtitle,
  });

  final bool dark;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF10283A) : const Color(0xFFEAF4FC),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: dark
              ? const Color(0xFF319BCB).withValues(alpha: .27)
              : const Color(0xFF1688BE).withValues(alpha: .18),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: .14),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.developer_board_rounded, color: colors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _AboutUpdateStatusLine extends StatelessWidget {
  const _AboutUpdateStatusLine({
    required this.status,
    required this.persian,
    required this.dark,
  });

  final AboutUpdateStatus status;
  final bool persian;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, text) = switch (status) {
      AboutUpdateStatus.checking => (
        Icons.sync_rounded,
        theme.colorScheme.primary,
        persian ? 'در حال بررسی نسخهٔ جدید…' : 'Checking for the latest build…',
      ),
      AboutUpdateStatus.upToDate => (
        Icons.check_circle_rounded,
        const Color(0xFF25AE85),
        persian
            ? 'از آخرین نسخه استفاده می‌کنید.'
            : 'You’re on the latest version.',
      ),
      AboutUpdateStatus.available => (
        Icons.system_update_alt_rounded,
        theme.colorScheme.primary,
        persian
            ? 'نسخهٔ جدید برای دانلود آماده است.'
            : 'An update is available to download.',
      ),
      AboutUpdateStatus.error => (
        Icons.error_outline_rounded,
        theme.colorScheme.error,
        persian
            ? 'بررسی نسخه ناموفق بود؛ دوباره تلاش کنید.'
            : 'Update check failed. Try again.',
      ),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .12 : .08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _AboutLinkButton extends StatelessWidget {
  const _AboutLinkButton({
    required this.tooltip,
    required this.asset,
    required this.onPressed,
  });

  final String tooltip;
  final String asset;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: IconButton(
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      icon: Image.asset(asset, width: 34, height: 34),
    ),
  );
}
