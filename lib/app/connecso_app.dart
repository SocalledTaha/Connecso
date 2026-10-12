import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/repositories/subscription_cache.dart';
import '../data/database/app_database.dart';
import '../data/repositories/saved_subscriptions.dart';
import '../data/parsers/subscription_metadata.dart';
import '../domain/models/connection_state.dart';
import '../domain/models/vpn_node.dart';
import '../domain/models/destination_selection.dart';
import '../domain/models/connection_method.dart';
import '../domain/models/resolved_endpoint.dart';
import '../domain/services/connection_manager.dart';
import '../domain/services/core_node_probe.dart';
import '../domain/services/core_manager.dart';
import '../domain/services/endpoint_resolver.dart';
import '../domain/services/location_resolver.dart';
import '../domain/services/probe_engine.dart';
import '../domain/services/smart_selector.dart';
import '../domain/services/connect_trace.dart';
import '../data/repositories/subscription_repository.dart';
import '../data/parsers/subscription_parser.dart';
import '../domain/services/usage_service.dart';
import '../domain/services/usage_session_lifecycle.dart';
import '../domain/services/split_tunnel_policy.dart';
import '../domain/services/structured_logger.dart';
import '../domain/services/source_country_resolver.dart';
import '../l10n/app_strings.dart';
import '../platform/android/android_vpn_adapter.dart';
import '../platform/android/background_subscription_refresh.dart';
import '../platform/android/xray_proxy_core.dart';
import '../ui/home/home_screen.dart';
import '../ui/split_tunneling/split_tunneling_screen.dart';

const _debugPerformanceOverlay = bool.fromEnvironment(
  'CONNECSO_PERF_OVERLAY',
  defaultValue: false,
);

class ConnecsoApp extends StatefulWidget {
  const ConnecsoApp({super.key});

  @override
  State<ConnecsoApp> createState() => _ConnecsoAppState();
}

class _ConnecsoAppState extends State<ConnecsoApp> with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();
  final _history = AppDatabase();
  late final AndroidVpnAdapter _vpn = AndroidVpnAdapter();
  late final SecureSubscriptionCache _cache = SecureSubscriptionCache(_storage);
  late final SavedSubscriptionsStore _savedStore = SavedSubscriptionsStore(
    _storage,
  );
  late final SubscriptionRepository _subscriptions = SubscriptionRepository(
    cache: _cache,
    directFetcher: _vpn.fetchDirectSubscription,
    currentRouteFetcher: _vpn.fetchCurrentRouteSubscription,
  );
  late final UsageSessionLifecycle _usageSessions = UsageSessionLifecycle(
    beginSession: _history.beginUsageSession,
    updateSession: _history.updateUsageSession,
  );
  late final CoreManager _cores = CoreManager(XrayProxyCore(_vpn));
  late final EndpointResolver _endpointResolver = EndpointResolver(
    cores: _cores,
  );
  late final ConnectionManager _connection = ConnectionManager(
    tunnel: _vpn,
    cores: _cores,
    onNodeSelected: (node) {
      if (mounted && _destinationNode?.id != node.id) {
        setState(() => _destinationNode = node);
      }
    },
    onPhaseChanged: (phase) {
      if (mounted && _phase != phase) setState(() => _phase = phase);
    },
    recordNodeFailure: (node, duration) => _history.recordConnection(
      nodeId: node.id,
      protocol: node.protocol.name,
      core: ProxyCoreKind.xray.name,
      connected: false,
      occurredAt: DateTime.now(),
      duration: duration,
    ),
  );
  late final ProbeEngine _probeEngine = ProbeEngine(CoreNodeProbe(_cores));
  final _locations = const LocationResolver();
  final _selector = const SmartSelector();
  final _logger = StructuredLogger();
  final _sourceCountryResolver = const SourceCountryResolver();
  String? _sourceCountryCode;

  Future<void> _resolveSourceCountry() async {
    final code = await _sourceCountryResolver.resolve();
    if (mounted && code != null) setState(() => _sourceCountryCode = code);
  }

  Future<List<InstalledApplication>> _installedApplications() async {
    final applications = await _vpn.installedApplications();
    return applications
        .map(
          (application) => InstalledApplication(
            packageName: application['packageName'] as String? ?? '',
            label: application['label'] as String? ?? '',
            isSystemApp: application['isSystemApp'] as bool? ?? false,
          ),
        )
        .where((application) => application.packageName.isNotEmpty)
        .toList(growable: false);
  }

  Timer? _statsTimer;
  Timer? _healthTimer;
  DateTime? _connectedAt;
  bool _healthCheckRunning = false;
  bool _connectedHealthReady = false;
  int _sessionUploadOffsetBytes = 0;
  int _sessionDownloadOffsetBytes = 0;
  CoreStats? _lastStats;
  DateTime _lastUsagePersisted = DateTime.fromMillisecondsSinceEpoch(0);
  bool _probingNodes = false;
  bool _pauseBackgroundProbes = false;
  Completer<void>? _probeIdleCompleter;
  bool _refreshingConnectionPing = false;
  bool _manualPingQueued = false;
  int _subscriptionRevision = 0;
  final ValueNotifier<int> _subscriptionRevisionNotifier = ValueNotifier(0);

  int _bumpSubscriptionRevision() {
    final value = ++_subscriptionRevision;
    _subscriptionRevisionNotifier.value = value;
    return value;
  }

  (List<VpnNode>, String, int)? _queuedProbe;
  int? _sessionUploadBytes;
  int? _sessionDownloadBytes;
  final Set<String> _refreshingSubscriptionIds = {};
  bool _hasSubscriptionUrl = false;
  bool get _refreshingSubscription => _refreshingSubscriptionIds.isNotEmpty;

  List<VpnNode> _nodes = const [];
  List<SavedSubscription> _savedSubscriptions = const [];
  String? _activeSubscriptionId;
  ConnectionPhase _phase = ConnectionPhase.noProfile;
  VpnNode? _activeNode;
  // Keep the last endpoint that completed the full dataplane verification.
  // It is intentionally retained across a normal disconnect so a reconnect
  // can reuse the proven endpoint without waiting for a subscription-wide
  // probe batch. Country and method scope are still enforced by Resolver.
  VpnNode? _lastSuccessfulNode;
  VpnNode? _destinationNode;
  DestinationSelection _destinationSelection =
      const DestinationSelection.auto();
  String? _failure;
  QuotaSnapshot _quota = QuotaSnapshot.unavailable();
  SplitTunnelPolicy _splitPolicy = const SplitTunnelPolicy(
    mode: SplitTunnelMode.excludeSelected,
    packageNames: {},
  );
  Locale _locale =
      WidgetsBinding.instance.platformDispatcher.locale.languageCode == 'fa'
      ? const Locale('fa')
      : const Locale('en');
  ThemeMode _themeMode = ThemeMode.system;
  // Render Home immediately. Secure-storage/cache restore is asynchronous and
  // must not replace the first frame with a startup spinner.
  bool _loading = false;
  bool _synchronizingTileConnection = false;
  bool _toggleInFlight = false;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveSourceCountry());
    WidgetsBinding.instance.addObserver(this);
    // Quick Settings runs outside Flutter. MainActivity forwards its result
    // broadcast here, so the home UI updates on the actual state transition
    // instead of polling every few seconds.
    _vpn.setExternalStateChangedHandler(() {
      if (mounted) unawaited(_synchronizeQuickTileConnection());
    });
    unawaited(
      scheduleBackgroundSubscriptionRefresh().catchError((Object error) {
        _logger.record(
          category: LogCategory.subscription,
          severity: LogSeverity.warning,
          event: 'subscription.background_schedule_failed',
          fields: {'failureType': error.runtimeType.toString()},
        );
      }),
    );
    _restore();
  }

  Future<void> _restore() async {
    final values = await Future.wait([
      _savedStore.read(),
      _storage.read(key: 'subscription_nodes_v1'),
      _storage.read(key: 'subscription_url_v1'),
      _storage.read(key: 'subscription_quota_v1'),
      _storage.read(key: 'subscription_active_v1'),
      _storage.read(key: 'language'),
      _storage.read(key: 'theme'),
      _storage.read(key: 'split_tunnel_policy_v1'),
    ]);
    var subscriptions = values[0] as List<SavedSubscription>;
    var activeId = values[4] as String?;
    if (subscriptions.isEmpty &&
        ((values[1] as String?)?.isNotEmpty == true ||
            (values[2] as String?)?.isNotEmpty == true)) {
      subscriptions = [
        SavedSubscription(
          id: 'primary',
          name: 'Subscription 1',
          endpoint: values[2] as String?,
          quota:
              QuotaSnapshot.decode(values[3] as String?) ??
              QuotaSnapshot.unavailable(),
        ),
      ];
      activeId = 'primary';
      await _savedStore.write(subscriptions);
      await _storage.write(key: 'subscription_active_v1', value: activeId);
    }
    if (!subscriptions.any((item) => item.id == activeId)) activeId = null;
    final nodes = activeId == null
        ? const <VpnNode>[]
        : await _subscriptions.cachedNodes(activeId);
    final active = activeId == null
        ? null
        : subscriptions.firstWhere((item) => item.id == activeId);
    final revision = _bumpSubscriptionRevision();
    if (!mounted) return;
    setState(() {
      _savedSubscriptions = subscriptions;
      _activeSubscriptionId = activeId;
      _nodes = nodes;
      _phase = nodes.isEmpty
          ? ConnectionPhase.noProfile
          : ConnectionPhase.disconnected;
      _activeNode = null;
      if (values[5] is String) {
        _locale = values[5] == 'fa' ? const Locale('fa') : const Locale('en');
      }
      if (values[6] == 'light') {
        _themeMode = ThemeMode.light;
      } else if (values[6] == 'dark') {
        _themeMode = ThemeMode.dark;
      }
      _splitPolicy = _readSplitPolicy(values[7]);
      _quota = active?.quota ?? QuotaSnapshot.unavailable();
      _hasSubscriptionUrl = active?.endpoint?.isNotEmpty == true;
      _loading = false;
    });
    final savedMethod = await _storage.read(key: 'connection_method_v1');
    if (mounted) {
      setState(() {
        _connectionMethod = ConnectionMethod.values
            .where((method) => method.name == savedMethod)
            .firstOrNull;
      });
    }
    final savedMode = await _storage.read(key: 'destination_mode_v1');
    final savedCountry = await _storage.read(key: 'destination_country_v1');
    if (mounted &&
        savedMode == DestinationMode.countryLocked.name &&
        savedCountry != null &&
        savedCountry.isNotEmpty) {
      setState(
        () =>
            _destinationSelection = DestinationSelection.country(savedCountry),
      );
    }
    // Quick-tile verification can perform several network checks. It must
    // restore a real connected session when present, but it should not keep
    // the HomeScreen behind the startup spinner while doing so.
    unawaited(
      _restoreQuickTileAfterFirstFrame(
        subscriptions: subscriptions,
        activeId: activeId,
        active: active,
        nodes: nodes,
        revision: revision,
      ),
    );
  }

  ConnectionMethod? _connectionMethod;

  List<VpnNode> _methodPool(Iterable<VpnNode> nodes) => nodes
      .where(
        (node) => _connectionMethod == null || _connectionMethod!.matches(node),
      )
      .toList();

  List<VpnNode> get _destinationPool => _methodPool(_nodes);

  List<VpnNode> get _recoveryPool => _destinationPool;

  Future<VpnNode> _resolveAndConnect(
    Iterable<VpnNode> nodes, {
    VpnNode? current,
    Set<String> excludedNodeIds = const {},
    bool reconnect = false,
    SelectionReason? reason,
  }) async {
    final startedAt = DateTime.now();
    ConnectTrace.emit('timing.resolver_start');
    final endpoint = await _endpointResolver.resolve(
      nodes: nodes,
      selection: _destinationSelection.copyWith(method: _connectionMethod),
      current: current,
      excludedNodeIds: excludedNodeIds,
      reason: reason,
    );
    ConnectTrace.emit(
      'timing.resolver_ready elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} node=${endpoint.node.id}',
    );
    return reconnect
        ? _connection.reconnect(endpoint, splitTunnelPolicy: _splitPolicy)
        : _connection.connect(endpoint, splitTunnelPolicy: _splitPolicy);
  }

  Future<void> _setConnectionMethod(ConnectionMethod? method) async {
    if (method != null &&
        !ConnectionMethod.available(_nodes).contains(method)) {
      return;
    }
    final country = _destinationSelection.countryCode;
    final keepCountry =
        country == null ||
        method == null ||
        _nodes.any(
          (node) =>
              node.enabled &&
              method.matches(node) &&
              LocationResolver.canonicalCountryCode(
                    '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
                  ) ==
                  country,
        );
    setState(() {
      _connectionMethod = method;
      if (!keepCountry) {
        _destinationSelection = const DestinationSelection.auto();
      }
    });
    if (method == null) {
      await _storage.delete(key: 'connection_method_v1');
    } else {
      await _storage.write(key: 'connection_method_v1', value: method.name);
    }
    if (!keepCountry) {
      await _storage.write(
        key: 'destination_mode_v1',
        value: DestinationMode.auto.name,
      );
      await _storage.delete(key: 'destination_country_v1');
    }
  }

  Future<void> _setDestinationSelection(DestinationSelection selection) async {
    setState(() => _destinationSelection = selection);
    await _storage.write(
      key: 'destination_mode_v1',
      value: selection.mode.name,
    );
    if (selection.countryCode == null) {
      await _storage.delete(key: 'destination_country_v1');
    } else {
      await _storage.write(
        key: 'destination_country_v1',
        value: selection.countryCode,
      );
    }
    // A country change while connected enters the same full reconnect
    // pipeline as Auto mode after restricting the endpoint pool.
    if (selection.countryCode != null &&
        _phase == ConnectionPhase.connected &&
        _nodes.isNotEmpty) {
      // A manual destination change rebuilds the same full VPN pipeline as a
      // fresh Auto connection. Stop observers tied to the previous TUN/core
      // before tearing it down, then start them again only after the new
      // dataplane has been verified.
      _manualPingQueued = false;
      _statsTimer?.cancel();
      _healthTimer?.cancel();
      try {
        final selected = await _resolveAndConnect(
          _destinationPool,
          current: _activeNode,
          reconnect: true,
        );
        if (mounted) {
          setState(() {
            _activeNode = selected;
            _destinationNode = selected;
            _phase = ConnectionPhase.connected;
            _failure = null;
          });
          _connectedAt = DateTime.now();
          _startStatsPolling(newSession: true);
          _startHealthMonitoring();
          unawaited(_refreshConnectionPing());
        }
      } catch (error) {
        if (mounted) {
          setState(() => _failure = _humanError(error));
        }
      }
    }
  }

  Future<void> _restoreQuickTileAfterFirstFrame({
    required List<SavedSubscription> subscriptions,
    required String? activeId,
    required SavedSubscription? active,
    required List<VpnNode> nodes,
    required int revision,
  }) async {
    final tileNode = await _findVerifiedTileNode(subscriptions);
    if (!mounted ||
        _activeSubscriptionId != activeId ||
        (_phase != ConnectionPhase.disconnected &&
            _phase != ConnectionPhase.noProfile)) {
      return;
    }
    if (tileNode != null) {
      setState(() {
        _activeNode = tileNode;
        _phase = ConnectionPhase.connected;
        _connectedHealthReady = true;
      });
      _connection.restoreConnectedSession();
      _startStatsPolling(newSession: true);
      _startHealthMonitoring();
      return;
    }
    final savedUrl = active?.endpoint;
    if (savedUrl != null && savedUrl.trim().isNotEmpty && activeId != null) {
      unawaited(
        _refreshSubscription(
          Uri.tryParse(savedUrl),
          subscriptionId: activeId,
          reportErrors: false,
        ),
      );
    } else if (nodes.isNotEmpty && activeId != null) {
      unawaited(
        _probeNodes(nodes, subscriptionId: activeId, revision: revision),
      );
    }
  }

  Future<VpnNode?> _findVerifiedTileNode(
    List<SavedSubscription> subscriptions,
  ) async {
    final nodeId = await _vpn.activeQuickTileNodeId().catchError(
      (Object _) => null,
    );
    if (nodeId == null) return null;
    for (final profile in subscriptions) {
      final nodes = await _subscriptions.cachedNodes(profile.id);
      for (final node in nodes) {
        if (node.id == nodeId && await _verifyTunnelWithRetry()) return node;
      }
    }
    return null;
  }

  Future<bool> _verifyTunnelWithRetry() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (await _vpn.verifyUsableConnectivity().catchError(
        (Object _) => false,
      )) {
        return true;
      }
      if (attempt < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading) {
      unawaited(_synchronizeQuickTileConnection());
    }
  }

  Future<void> _synchronizeQuickTileConnection() async {
    if (_synchronizingTileConnection) return;
    _synchronizingTileConnection = true;
    try {
      final subscriptions = _savedSubscriptions;
      // Quick Action writes the authoritative state only after Android has
      // completed dataplane startup. Read that state directly first; do not
      // block UI synchronization on another Google/YouTube verification.
      final tileState = await _vpn.quickTileConnection();
      final tileActive = tileState['active'] == true;
      final serviceRunning = tileState['serviceRunning'] == true;
      final tileNodeId = tileState['nodeId'] as String?;
      VpnNode? tileNode;
      if ((tileActive || serviceRunning) && tileNodeId != null) {
        for (final profile in subscriptions) {
          final cached = await _subscriptions.cachedNodes(profile.id);
          final matches = cached.where((node) => node.id == tileNodeId);
          if (matches.isNotEmpty) {
            tileNode = matches.first;
            break;
          }
        }
      }
      if (!mounted) return;
      // After lock/unlock the Android service can remain alive while the
      // persisted Quick Tile flag is briefly stale. Confirm the native
      // dataplane before restoring the Flutter state in that case.
      final nativeSessionUsable =
          tileNode != null &&
          (tileActive ||
              (serviceRunning &&
                  await _verifyTunnelWithRetry().catchError(
                    (Object _) => false,
                  )));
      if (nativeSessionUsable &&
          (_activeNode?.id != tileNode!.id ||
              _phase != ConnectionPhase.connected)) {
        setState(() {
          _activeNode = tileNode;
          _phase = ConnectionPhase.connected;
          _failure = null;
        });
        _connection.restoreConnectedSession();
        _startStatsPolling(newSession: true);
        _startHealthMonitoring();
      } else if (tileNode == null && _phase == ConnectionPhase.connected) {
        _statsTimer?.cancel();
        _healthTimer?.cancel();
        await _endUsageSession();
        if (!mounted) return;
        _connection.restoreDisconnectedSession();
        setState(() {
          _activeNode = null;
          _phase = _nodes.isEmpty
              ? ConnectionPhase.noProfile
              : ConnectionPhase.disconnected;
        });
        await _loadSelectedProfileAfterDisconnect();
      }
    } finally {
      _synchronizingTileConnection = false;
    }
  }

  SplitTunnelPolicy _readSplitPolicy(Object? stored) {
    const fallback = SplitTunnelPolicy(
      mode: SplitTunnelMode.excludeSelected,
      packageNames: {},
    );
    if (stored is! String) return fallback;
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, Object?>) return fallback;
      return SplitTunnelPolicy.fromJson(decoded);
    } on FormatException {
      return fallback;
    } on TypeError {
      return fallback;
    } on ArgumentError {
      return fallback;
    }
  }

  Future<void> _saveSplitPolicy(SplitTunnelPolicy policy) async {
    await _storage.write(
      key: 'split_tunnel_policy_v1',
      value: jsonEncode(policy.toJson()),
    );
    if (!mounted) return;
    setState(() => _splitPolicy = policy);
  }

  Future<void> importSubscription(String source) async {
    if (_refreshingSubscription) {
      throw StateError('Wait for the current subscription refresh to finish.');
    }
    final trimmed = normalizeSubscriptionInput(source);
    final uri = Uri.tryParse(trimmed);
    if (uri?.hasScheme == true &&
        (uri!.scheme == 'https' || uri.scheme == 'http')) {
      if (uri.scheme != 'https') {
        throw const FormatException('Subscription links must use HTTPS.');
      }
      await _refreshSubscription(
        uri,
        subscriptionId: _newSubscriptionId(),
        newProfileName: uri.host,
      );
      return;
    }
    final id = _newSubscriptionId();
    final imported = await _subscriptions.importText(
      trimmed,
      subscriptionId: id,
    );
    final connected = _phase == ConnectionPhase.connected;
    final profile = SavedSubscription(
      id: id,
      name:
          parseSubscriptionProfileTitle(const {}, trimmed) ??
          'Subscription ${_savedSubscriptions.length + 1}',
    );
    final subscriptions = [..._savedSubscriptions, profile];
    await _savedStore.write(subscriptions);
    await _storage.write(key: 'subscription_active_v1', value: id);
    _logger.record(
      category: LogCategory.subscription,
      severity: LogSeverity.info,
      event: 'subscription.imported',
      fields: {'count': imported.length},
    );
    if (!mounted) return;
    setState(() {
      _savedSubscriptions = subscriptions;
      _activeSubscriptionId = id;
      if (!connected) _nodes = imported;
      _quota = QuotaSnapshot.unavailable();
      _hasSubscriptionUrl = false;
      if (!connected) {
        _phase = ConnectionPhase.disconnected;
        _activeNode = null;
        _sessionUploadBytes = null;
        _sessionDownloadBytes = null;
      }
      _failure = null;
    });
    final revision = _bumpSubscriptionRevision();
    unawaited(_probeNodes(imported, subscriptionId: id, revision: revision));
  }

  Future<void> _refreshSubscription(
    Uri? endpoint, {
    required String subscriptionId,
    String? newProfileName,
    bool reportErrors = true,
  }) async {
    if (endpoint == null || endpoint.scheme != 'https') return;
    if (_refreshingSubscriptionIds.contains(subscriptionId)) {
      if (reportErrors) {
        throw StateError('This subscription is already being refreshed.');
      }
      return;
    }
    _refreshingSubscriptionIds.add(subscriptionId);
    if (mounted) setState(() {});
    try {
      final hadConnectedTunnel =
          _phase == ConnectionPhase.connected && _activeNode != null;
      SubscriptionRefreshResult result;
      try {
        // With no Connecso tunnel this is the direct system-network route.
        // When an external VPN is active, Android's normal network route is
        // used here as well; no proxy is injected by the subscription layer.
        result = await _subscriptions.refreshDirect(
          endpoint,
          subscriptionId: subscriptionId,
        );
        _logger.record(
          category: LogCategory.recovery,
          severity: LogSeverity.info,
          event: hadConnectedTunnel
              ? 'subscription.refresh_active_tunnel_succeeded'
              : 'subscription.refresh_direct_succeeded',
          fields: {'subscriptionId': subscriptionId},
        );
      } catch (error) {
        try {
          // The Direct route is intentionally attempted first. This second
          // request uses the process' current route, which can be Connecso's
          // active VPN or another VPN/proxy already configured on Android.
          result = await _subscriptions.refreshViaCurrentRoute(
            endpoint,
            subscriptionId: subscriptionId,
          );
          _logger.record(
            category: LogCategory.recovery,
            severity: LogSeverity.info,
            event: 'subscription.refresh_current_route_succeeded',
            fields: {'subscriptionId': subscriptionId},
          );
        } catch (currentRouteError) {
          if (!hadConnectedTunnel || !await _activeTunnelIsDead()) {
            rethrow;
          }
          _logger.record(
            category: LogCategory.recovery,
            severity: LogSeverity.warning,
            event: 'subscription.refresh_active_tunnel_failed',
            fields: {'subscriptionId': subscriptionId},
          );
          result = await _refreshThroughHealthyCachedNode(
            endpoint,
            subscriptionId: subscriptionId,
          );
        }
      }
      _connection.resetSubscriptionCycle(result.nodes);
      final existingIndex = _savedSubscriptions.indexWhere(
        (item) => item.id == subscriptionId,
      );
      final activateNewProfile = existingIndex < 0 && newProfileName != null;
      final previous = existingIndex < 0
          ? null
          : _savedSubscriptions[existingIndex];
      final title = result.profileTitle;
      final profile = SavedSubscription(
        id: subscriptionId,
        name: previous?.nameCustomized == true
            ? previous!.name
            : title ??
                  previous?.name ??
                  newProfileName ??
                  'Subscription ${_savedSubscriptions.length + 1}',
        endpoint: endpoint.toString(),
        quota: result.quota,
        nameCustomized: previous?.nameCustomized ?? false,
        pinned: previous?.pinned ?? false,
        serverName: title ?? previous?.serverName,
        accountEmail: result.accountEmail ?? previous?.accountEmail,
        supportUrl: result.supportUrl ?? previous?.supportUrl,
        profileUrl: result.profileUrl ?? previous?.profileUrl,
        announcement: result.announcement ?? previous?.announcement,
      );
      final subscriptions = [..._savedSubscriptions];
      if (existingIndex < 0) {
        subscriptions.add(profile);
      } else {
        subscriptions[existingIndex] = profile;
      }
      await _savedStore.write(subscriptions);
      if (activateNewProfile) {
        await _storage.write(
          key: 'subscription_active_v1',
          value: subscriptionId,
        );
      }
      if (!mounted) return;
      if (activateNewProfile) {
        _activeSubscriptionId = subscriptionId;
      }
      final selected = _activeSubscriptionId == subscriptionId;
      final connectedToThisProfile =
          _phase == ConnectionPhase.connected &&
          _activeNode?.subscriptionId == subscriptionId;
      final canReplaceNodeList =
          _phase != ConnectionPhase.connected || connectedToThisProfile;
      setState(() {
        _savedSubscriptions = subscriptions;
        if (selected) {
          _quota = result.quota;
          _hasSubscriptionUrl = true;
        }
        if (selected && canReplaceNodeList) {
          _nodes = result.nodes;
          if (_phase != ConnectionPhase.connected) {
            _phase = result.nodes.isEmpty
                ? ConnectionPhase.noProfile
                : ConnectionPhase.disconnected;
          }
        }
        _failure = null;
      });
      _bumpSubscriptionRevision();
      _logger.record(
        category: LogCategory.subscription,
        severity: LogSeverity.info,
        event: 'subscription.refreshed',
        fields: {'count': result.nodes.length},
      );
      if (selected && canReplaceNodeList) {
        unawaited(
          _probeNodes(
            result.nodes,
            subscriptionId: subscriptionId,
            revision: _subscriptionRevision,
          ),
        );
      }
    } catch (error) {
      _logger.record(
        category: LogCategory.subscription,
        severity: LogSeverity.warning,
        event: 'subscription.refresh_failed',
        fields: {'failureType': error.runtimeType.toString()},
      );
      if (reportErrors) rethrow;
    } finally {
      _refreshingSubscriptionIds.remove(subscriptionId);
      if (mounted) setState(() {});
    }
  }

  Future<bool> _activeTunnelIsDead() async {
    final active = _activeNode;
    if (active == null || _phase != ConnectionPhase.connected) return false;
    try {
      final results = await _probeEngine.probeBatch([active], concurrency: 1);
      return results.isEmpty || !results.first.reachable;
    } catch (_) {
      return true;
    }
  }

  Future<SubscriptionRefreshResult> _refreshThroughHealthyCachedNode(
    Uri endpoint, {
    required String subscriptionId,
  }) async {
    final currentId = _activeNode?.id;
    final candidates = _nodes
        .where(
          (node) =>
              node.subscriptionId == subscriptionId &&
              node.id != currentId &&
              node.enabled &&
              node.health == NodeHealth.healthy,
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      // Deliberately keep the recovery-proxy slot fail-closed until its
      // signed endpoint and transport are supplied in a later build.
      return _refreshThroughRecoveryProxy(
        endpoint,
        subscriptionId: subscriptionId,
      );
    }

    _logger.record(
      category: LogCategory.recovery,
      severity: LogSeverity.info,
      event: 'subscription.refresh_cached_node_connect_start',
      fields: {'subscriptionId': subscriptionId, 'count': candidates.length},
    );
    await _connection.disconnect();
    if (mounted) {
      setState(() {
        _phase = ConnectionPhase.disconnected;
        _activeNode = null;
      });
    }
    final selected = await _resolveAndConnect(_methodPool(candidates));
    if (mounted) {
      setState(() {
        _activeNode = selected;
        _phase = ConnectionPhase.connected;
        _connectedHealthReady = false;
      });
      _startStatsPolling(newSession: true);
      _startHealthMonitoring();
    }
    _logger.record(
      category: LogCategory.recovery,
      severity: LogSeverity.info,
      event: 'subscription.refresh_cached_node_connected',
      fields: {'subscriptionId': subscriptionId, 'nodeId': selected.id},
    );
    return _subscriptions.refreshDirect(
      endpoint,
      subscriptionId: subscriptionId,
    );
  }

  Future<SubscriptionRefreshResult> _refreshThroughRecoveryProxy(
    Uri endpoint, {
    required String subscriptionId,
  }) => Future<SubscriptionRefreshResult>.error(
    StateError(
      'Recovery proxy is not configured for subscription $subscriptionId.',
    ),
  );

  Future<void> _probeNodes(
    List<VpnNode> nodes, {
    required String subscriptionId,
    required int revision,
  }) async {
    if (nodes.isEmpty) return;
    // ConnectionManager performs the authoritative destination probe. Do not
    // start a subscription-wide background batch while the home connection
    // flow is active or disconnected; an in-flight batch would compete with
    // the destination ping after the tunnel comes up.
    if ({
      ConnectionPhase.noProfile,
      ConnectionPhase.disconnected,
      ConnectionPhase.preparing,
      ConnectionPhase.connecting,
      ConnectionPhase.verifying,
      ConnectionPhase.connected,
      ConnectionPhase.reconnecting,
      ConnectionPhase.disconnecting,
    }.contains(_phase)) {
      return;
    }
    if (_pauseBackgroundProbes) {
      _queuedProbe = (nodes, subscriptionId, revision);
      return;
    }
    if (_probingNodes) {
      _queuedProbe = (nodes, subscriptionId, revision);
      return;
    }
    _probingNodes = true;
    _probeIdleCompleter = Completer<void>();
    try {
      final candidates = [...nodes]
        ..sort((a, b) => _selector.score(b).compareTo(_selector.score(a)));
      final results = await _probeEngine.probeBatch(
        candidates.take(12),
        // The Android core has one effective native probe lane. Multiple
        // background workers only queue inside the core and can delay the
        // user's connection probe when the button is pressed.
        concurrency: 1,
        // Background refresh is advisory; a stalled node must not occupy the
        // native probe lane for the full resolver timeout.
        timeout: const Duration(milliseconds: 1500),
      );
      if (revision != _subscriptionRevision) return;
      final byId = {for (final result in results) result.nodeId: result};
      final updated = nodes
          .map((node) {
            final result = byId[node.id];
            if (result == null) return node;
            final validLatency =
                result.latency != null && result.latency!.inMilliseconds > 0
                ? result.latency
                : null;
            final observations = node.successCount + node.failureCount;
            final successes = node.successCount + (result.reachable ? 1 : 0);
            final failures = node.failureCount + (result.reachable ? 0 : 1);
            final stability =
                ((node.stabilityScore * observations) +
                    (result.reachable ? 1 : 0)) /
                (observations + 1);
            return VpnNode.fromJson({
              ...node.toJson(),
              'health': result.reachable && validLatency != null
                  ? (validLatency.inMilliseconds <= 1500
                        ? NodeHealth.healthy.name
                        : NodeHealth.degraded.name)
                  : NodeHealth.degraded.name,
              if (validLatency != null)
                'latencyMs': validLatency.inMilliseconds,
              'lastProbe': result.checkedAt.toUtc().toIso8601String(),
              'lastSuccess': result.reachable
                  ? result.checkedAt.toUtc().toIso8601String()
                  : node.lastSuccess?.toIso8601String(),
              'lastFailure': result.reachable
                  ? node.lastFailure?.toIso8601String()
                  : result.checkedAt.toUtc().toIso8601String(),
              'successCount': successes,
              'failureCount': failures,
              'stabilityScore': stability,
            });
          })
          .toList(growable: false);
      await _cache.replaceNodes(subscriptionId, updated);
      for (final result in results) {
        final node = nodes.firstWhere((item) => item.id == result.nodeId);
        unawaited(
          _history
              .recordProbe(
                nodeId: result.nodeId,
                protocol: node.protocol.name,
                reachable: result.reachable,
                latency:
                    result.latency != null && result.latency!.inMilliseconds > 0
                    ? result.latency
                    : null,
                failureCategory: result.failureCategory,
                checkedAt: result.checkedAt,
              )
              .catchError(_logPersistenceFailure),
        );
      }
      if (!mounted) return;
      final canReplaceNodeList =
          _activeSubscriptionId == subscriptionId &&
          (_phase != ConnectionPhase.connected ||
              _activeNode?.subscriptionId == subscriptionId);
      if (canReplaceNodeList) {
        setState(() {
          _nodes = updated;
          final activeId = _activeNode?.id;
          if (activeId != null) {
            final refreshed = updated.where((item) => item.id == activeId);
            if (refreshed.isNotEmpty) _activeNode = refreshed.first;
          }
        });
      }
    } catch (error) {
      _logPersistenceFailure(error);
    } finally {
      _finishProbeCycle();
    }
  }

  void _finishProbeCycle() {
    _probingNodes = false;
    final idle = _probeIdleCompleter;
    _probeIdleCompleter = null;
    if (idle != null && !idle.isCompleted) idle.complete();
    if (_pauseBackgroundProbes) return;
    final queued = _queuedProbe;
    _queuedProbe = null;
    if (queued != null && mounted) {
      unawaited(
        _probeNodes(queued.$1, subscriptionId: queued.$2, revision: queued.$3),
      );
      return;
    }
    if (_manualPingQueued && mounted) {
      _manualPingQueued = false;
      _probingNodes = true;
      unawaited(_performConnectionPing());
    }
  }

  Future<void> _pauseProbesForConnection() async {
    _pauseBackgroundProbes = true;
    // Do not wait for an in-flight background batch here. Those probes are
    // advisory and can take several seconds across a subscription; waiting
    // for them made a user tap appear to do nothing before connect started.
    // The batch will finish in the background, and _finishProbeCycle keeps
    // queued work paused until the connection attempt is complete.
  }

  void _resumeProbesAfterConnection() {
    _pauseBackgroundProbes = false;
    _manualPingQueued = false;
    final queued = _queuedProbe;
    _queuedProbe = null;
    // Once the tunnel is up, the active destination is authoritative. Do not
    // restart a stale subscription-wide probe batch behind it.
    if (_phase == ConnectionPhase.connected) return;
    if (queued != null && mounted) {
      unawaited(
        _probeNodes(queued.$1, subscriptionId: queued.$2, revision: queued.$3),
      );
    }
  }

  Future<void> _refreshConnectionPing() async {
    if (_refreshingConnectionPing || _phase != ConnectionPhase.connected) {
      return;
    }
    final node = _activeNode;
    if (node == null) return;
    setState(() => _refreshingConnectionPing = true);
    if (_probingNodes) {
      _manualPingQueued = true;
      return;
    }
    _probingNodes = true;
    await _performConnectionPing(node);
  }

  Future<void> _performConnectionPing([VpnNode? requestedNode]) async {
    final node = requestedNode ?? _activeNode;
    try {
      if (node == null) return;
      final results = await _probeEngine.probeBatch([node], concurrency: 1);
      if (results.isEmpty) return;
      final result = results.single;
      final updated = _nodeWithProbeResult(node, result);

      if (mounted) {
        setState(() {
          if (_activeNode?.id == node.id) _activeNode = updated;
          if (_lastSuccessfulNode?.id == node.id ||
              _activeNode?.id == node.id) {
            _lastSuccessfulNode = updated;
          }
          if (_activeSubscriptionId == node.subscriptionId) {
            _nodes = _nodes
                .map((item) => item.id == node.id ? updated : item)
                .toList(growable: false);
          }
        });
      }

      try {
        final cached = await _subscriptions.cachedNodes(node.subscriptionId);
        if (cached.any((item) => item.id == node.id)) {
          await _cache.replaceNodes(
            node.subscriptionId,
            cached
                .map((item) => item.id == node.id ? updated : item)
                .toList(growable: false),
          );
        }
        await _history.recordProbe(
          nodeId: node.id,
          protocol: node.protocol.name,
          reachable: result.reachable,
          latency: result.latency,
          failureCategory: result.failureCategory,
          checkedAt: result.checkedAt,
        );
      } catch (error) {
        _logPersistenceFailure(error);
      }
      _logger.record(
        category: LogCategory.probe,
        severity: result.reachable ? LogSeverity.info : LogSeverity.warning,
        event: 'probe.manual_completed',
        fields: {
          'outcome': result.reachable ? 'success' : 'failure',
          if (result.latency != null)
            'durationMs': result.latency!.inMilliseconds,
        },
      );
    } catch (error) {
      _logger.record(
        category: LogCategory.probe,
        severity: LogSeverity.warning,
        event: 'probe.manual_failed',
        fields: {'failureType': error.runtimeType.toString()},
      );
    } finally {
      _finishProbeCycle();
      if (mounted) {
        setState(() {
          _refreshingConnectionPing = false;
          if (_phase == ConnectionPhase.connected) {
            _connectedHealthReady = true;
          }
        });
      }
    }
  }

  VpnNode _nodeWithProbeResult(VpnNode node, ProbeResult result) {
    final observations = node.successCount + node.failureCount;
    final reachable = result.reachable;
    final latency = result.latency != null && result.latency!.inMilliseconds > 0
        ? result.latency
        : null;
    return VpnNode.fromJson({
      ...node.toJson(),
      'health': reachable && latency != null
          ? (latency.inMilliseconds <= 1500
                ? NodeHealth.healthy.name
                : NodeHealth.degraded.name)
          : NodeHealth.degraded.name,
      // A cold/reachability-only probe has no authoritative latency. Clear
      // any older value instead of allowing it to leak into the UI.
      'latencyMs': latency?.inMilliseconds,
      'lastProbe': result.checkedAt.toUtc().toIso8601String(),
      'lastSuccess': reachable
          ? result.checkedAt.toUtc().toIso8601String()
          : node.lastSuccess?.toIso8601String(),
      'lastFailure': reachable
          ? node.lastFailure?.toIso8601String()
          : result.checkedAt.toUtc().toIso8601String(),
      'successCount': node.successCount + (reachable ? 1 : 0),
      'failureCount': node.failureCount + (reachable ? 0 : 1),
      'stabilityScore':
          ((node.stabilityScore * observations) + (reachable ? 1 : 0)) /
          (observations + 1),
    });
  }

  String _newSubscriptionId() =>
      'sub-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_savedSubscriptions.length}';

  Future<void> _disconnectCurrentSession() async {
    const inProgress = {
      ConnectionPhase.preparing,
      ConnectionPhase.connecting,
      ConnectionPhase.verifying,
      ConnectionPhase.reconnecting,
      ConnectionPhase.disconnecting,
    };
    if (inProgress.contains(_phase)) {
      throw StateError('Wait for the current VPN operation to finish.');
    }
    _statsTimer?.cancel();
    _healthTimer?.cancel();
    if (_phase == ConnectionPhase.connected ||
        _phase == ConnectionPhase.failed ||
        _phase == ConnectionPhase.disconnected ||
        _phase == ConnectionPhase.noProfile) {
      await _endUsageSession();
      await _connection.disconnect();
    }
    _lastStats = null;
    if (mounted) {
      setState(() {
        _phase = ConnectionPhase.disconnected;
        _activeNode = null;
        _sessionUploadBytes = null;
        _sessionDownloadBytes = null;
      });
    }
  }

  Future<void> signOutOfSubscription() async {
    if (_activeSubscriptionId == null || _refreshingSubscription) return;
    await _disconnectCurrentSession();
    await _storage.delete(key: 'subscription_active_v1');
    if (!mounted) return;
    _bumpSubscriptionRevision();
    _queuedProbe = null;
    setState(() {
      _activeSubscriptionId = null;
      _nodes = const [];
      _quota = QuotaSnapshot.unavailable();
      _hasSubscriptionUrl = false;
      _phase = ConnectionPhase.noProfile;
      _activeNode = null;
      _sessionUploadBytes = null;
      _sessionDownloadBytes = null;
      _failure = null;
    });
  }

  Future<void> selectSavedSubscription(String id) async {
    if (id == _activeSubscriptionId) return;
    final profile = _savedSubscriptions.firstWhere((item) => item.id == id);
    final nodes = await _subscriptions.cachedNodes(id);
    await _storage.write(key: 'subscription_active_v1', value: id);
    if (!mounted) return;
    final connected = _phase == ConnectionPhase.connected;
    final revision = _bumpSubscriptionRevision();
    _queuedProbe = null;
    setState(() {
      _activeSubscriptionId = id;
      _quota = profile.quota;
      _hasSubscriptionUrl = profile.endpoint?.isNotEmpty == true;
      if (!connected) {
        _nodes = nodes;
        _phase = nodes.isEmpty
            ? ConnectionPhase.noProfile
            : ConnectionPhase.disconnected;
        _activeNode = null;
        _sessionUploadBytes = null;
        _sessionDownloadBytes = null;
      }
      _failure = null;
    });
    final endpoint = profile.endpoint;
    if (endpoint != null && endpoint.isNotEmpty) {
      unawaited(
        _refreshSubscription(
          Uri.tryParse(endpoint),
          subscriptionId: id,
          reportErrors: false,
        ),
      );
    } else if (nodes.isNotEmpty) {
      unawaited(_probeNodes(nodes, subscriptionId: id, revision: revision));
    }
  }

  Future<void> renameSavedSubscription(String id, String name) async {
    final profile = _savedSubscriptions.firstWhere((item) => item.id == id);
    await editSavedSubscription(
      id,
      name,
      null,
      profile.autoRefreshEnabled,
      profile.refreshIntervalHours,
    );
  }

  Future<void> editSavedSubscription(
    String id,
    String name,
    String? endpoint,
    bool autoRefresh,
    int? refreshIntervalHours,
  ) async {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.runes.length > 40) {
      throw ArgumentError.value(name, 'name');
    }
    final index = _savedSubscriptions.indexWhere((item) => item.id == id);
    if (index < 0) throw StateError('Subscription was not found.');
    final previous = _savedSubscriptions[index];
    final normalizedEndpoint = endpoint?.trim().isEmpty == true
        ? previous.endpoint
        : endpoint?.trim() ?? previous.endpoint;
    var updatedProfile = previous.copyWith(
      name: normalized,
      endpoint: normalizedEndpoint,
      nameCustomized: true,
    );
    List<VpnNode>? refreshedNodes;
    final endpointChanged = normalizedEndpoint != previous.endpoint;
    if (endpointChanged && normalizedEndpoint != null) {
      final uri = Uri.tryParse(normalizedEndpoint);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        throw const FormatException('Subscription links must use HTTPS.');
      }
      final result = await _subscriptions.refreshDirect(
        uri,
        subscriptionId: id,
      );
      refreshedNodes = result.nodes;
      updatedProfile = updatedProfile.copyWith(
        quota: result.quota,
        serverName: result.profileTitle ?? previous.serverName,
        accountEmail: result.accountEmail ?? previous.accountEmail,
        supportUrl: result.supportUrl ?? previous.supportUrl,
        profileUrl: result.profileUrl ?? previous.profileUrl,
        announcement: result.announcement ?? previous.announcement,
        autoRefreshEnabled: autoRefresh,
        refreshIntervalHours: refreshIntervalHours,
      );
    } else {
      updatedProfile = updatedProfile.copyWith(
        autoRefreshEnabled: autoRefresh,
        refreshIntervalHours: refreshIntervalHours,
      );
    }
    final updated = [..._savedSubscriptions]..[index] = updatedProfile;
    await _savedStore.write(updated);
    if (!mounted) return;
    final canReplaceNodeList =
        _activeSubscriptionId == id &&
        (_phase != ConnectionPhase.connected ||
            _activeNode?.subscriptionId == id);
    setState(() {
      _savedSubscriptions = updated;
      if (_activeSubscriptionId == id) {
        _quota = updatedProfile.quota;
        _hasSubscriptionUrl = updatedProfile.endpoint?.isNotEmpty == true;
      }
      if (refreshedNodes != null && canReplaceNodeList) {
        _nodes = refreshedNodes;
      }
    });
    _bumpSubscriptionRevision();
    if (refreshedNodes != null) {
      await _cache.replaceNodes(id, refreshedNodes);
    }
  }

  Future<void> refreshSavedSubscription(String id) async {
    final profile = _savedSubscriptions.firstWhere((item) => item.id == id);
    final endpoint = profile.endpoint;
    if (endpoint == null || endpoint.isEmpty) {
      throw StateError('This saved subscription has no refreshable link.');
    }
    await _refreshSubscription(
      Uri.tryParse(endpoint),
      subscriptionId: id,
      reportErrors: true,
    );
  }

  Future<void> setSubscriptionPinned(String id, bool pinned) async {
    final updated = _savedSubscriptions
        .map(
          (profile) =>
              profile.id == id ? profile.copyWith(pinned: pinned) : profile,
        )
        .toList(growable: false);
    await _savedStore.write(updated);
    if (!mounted) return;
    setState(() {
      _savedSubscriptions = [
        ...updated.where((item) => item.pinned),
        ...updated.where((item) => !item.pinned),
      ];
    });
    _bumpSubscriptionRevision();
  }

  Future<void> deleteSavedSubscription(String id) async {
    final updated = _savedSubscriptions
        .where((profile) => profile.id != id)
        .toList(growable: false);
    await _savedStore.write(updated);
    await _storage.delete(key: 'subscription_nodes_v2_$id');
    final wasSelected = _activeSubscriptionId == id;
    if (wasSelected) await _storage.delete(key: 'subscription_active_v1');
    if (!mounted) return;
    final connected = _phase == ConnectionPhase.connected;
    setState(() {
      _savedSubscriptions = updated;
      if (wasSelected) {
        _activeSubscriptionId = null;
        _quota = QuotaSnapshot.unavailable();
        _hasSubscriptionUrl = false;
        if (!connected) {
          _nodes = const [];
          _phase = ConnectionPhase.noProfile;
          _activeNode = null;
          _sessionUploadBytes = null;
          _sessionDownloadBytes = null;
        }
      }
    });
    _bumpSubscriptionRevision();
  }

  Future<void> _loadSelectedProfileAfterDisconnect() async {
    final id = _activeSubscriptionId;
    SavedSubscription? profile;
    if (id != null) {
      for (final item in _savedSubscriptions) {
        if (item.id == id) {
          profile = item;
          break;
        }
      }
    }
    final nodes = id == null
        ? const <VpnNode>[]
        : await _subscriptions.cachedNodes(id);
    if (!mounted) return;
    final revision = _bumpSubscriptionRevision();
    setState(() {
      _nodes = nodes;
      _phase = id == null
          ? ConnectionPhase.noProfile
          : nodes.isEmpty
          ? ConnectionPhase.noProfile
          : ConnectionPhase.disconnected;
      _activeNode = null;
      _failure = null;
    });
    final endpoint = profile?.endpoint;
    if (endpoint != null && endpoint.isNotEmpty) {
      unawaited(
        _refreshSubscription(
          Uri.tryParse(endpoint),
          subscriptionId: id!,
          reportErrors: false,
        ),
      );
    } else if (nodes.isNotEmpty && id != null) {
      unawaited(_probeNodes(nodes, subscriptionId: id, revision: revision));
    }
  }

  void _startStatsPolling({bool newSession = false}) {
    _statsTimer?.cancel();
    if (newSession) {
      _sessionUploadOffsetBytes = 0;
      _sessionDownloadOffsetBytes = 0;
      _lastStats = null;
      unawaited(_beginUsageSession());
      setState(() {
        _sessionUploadBytes = null;
        _sessionDownloadBytes = null;
      });
    }
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final stats = await _vpn.readStats();
        if (!mounted) return;
        _lastStats = stats;
        setState(() {
          _sessionUploadBytes = _sessionUploadOffsetBytes + stats.uploadBytes;
          _sessionDownloadBytes =
              _sessionDownloadOffsetBytes + stats.downloadBytes;
        });
        if (DateTime.now().difference(_lastUsagePersisted).inSeconds >= 30) {
          _lastUsagePersisted = DateTime.now();
          unawaited(_persistUsage(stats));
        }
      } catch (_) {
        // Keep the last known value while Android temporarily has no stats.
      }
    });
  }

  Future<void> _beginUsageSession() async {
    try {
      await _usageSessions.begin(DateTime.now());
    } catch (error) {
      _logPersistenceFailure(error);
    }
  }

  Future<void> _persistUsage(CoreStats stats) async {
    try {
      final uploadBytes = _sessionUploadOffsetBytes + stats.uploadBytes;
      final downloadBytes = _sessionDownloadOffsetBytes + stats.downloadBytes;
      await _usageSessions.persist(
        uploadBytes: uploadBytes,
        downloadBytes: downloadBytes,
      );
    } catch (error) {
      _logPersistenceFailure(error);
    }
  }

  Future<void> _endUsageSession() async {
    try {
      final stats = _lastStats;
      await _usageSessions.end(
        uploadBytes:
            _sessionUploadBytes ??
            _sessionUploadOffsetBytes + (stats?.uploadBytes ?? 0),
        downloadBytes:
            _sessionDownloadBytes ??
            _sessionDownloadOffsetBytes + (stats?.downloadBytes ?? 0),
        endedAt: DateTime.now(),
      );
    } catch (error) {
      _logPersistenceFailure(error);
    }
  }

  Future<void> _recordConnection(
    VpnNode node, {
    required bool connected,
    Duration? duration,
  }) async {
    try {
      await _history.recordConnection(
        nodeId: node.id,
        protocol: node.protocol.name,
        core: ProxyCoreKind.xray.name,
        connected: connected,
        occurredAt: DateTime.now(),
        duration: duration,
      );
    } catch (error) {
      _logPersistenceFailure(error);
    }
  }

  void _logPersistenceFailure(Object error) {
    _logger.record(
      category: LogCategory.application,
      severity: LogSeverity.warning,
      event: 'persistence.write_failed',
      fields: {'failureType': error.runtimeType.toString()},
    );
  }

  void _startHealthMonitoring() {
    _healthTimer?.cancel();
    _connectedAt ??= DateTime.now();
    _healthTimer = Timer.periodic(
      _connectedAt != null &&
              DateTime.now().difference(_connectedAt!) >=
                  const Duration(hours: 1)
          ? const Duration(minutes: 10)
          : const Duration(minutes: 1),
      (_) => unawaited(_checkTunnelHealth()),
    );
  }

  Future<void> _checkTunnelHealth() async {
    final active = _activeNode;
    if (_healthCheckRunning ||
        _phase != ConnectionPhase.connected ||
        active == null) {
      return;
    }
    _healthCheckRunning = true;
    try {
      // After connection, only the active destination is health-checked. The
      // selector already chose the node; probing the rest of the subscription
      // would compete with the live tunnel and can delay reconnects.
      final samples = await _probeEngine.probeBatch([active], concurrency: 1);
      final byId = {for (final sample in samples) sample.nodeId: sample};
      final currentSample = byId[active.id];
      if (currentSample?.reachable == true && currentSample?.latency != null) {
        final updatedActive = _nodeWithProbeResult(active, currentSample!);
        final updatedPeers = _nodes
            .map((node) {
              final sample = byId[node.id];
              return sample?.reachable == true && sample?.latency != null
                  ? _nodeWithProbeResult(node, sample!)
                  : node;
            })
            .toList(growable: false);
        final state = _selector.classifyRuntime(updatedActive, updatedPeers);
        final stateful = VpnNode.fromJson({
          ...updatedActive.toJson(),
          'runtimeState': state.name,
        });
        if (mounted && _activeNode?.id == active.id) {
          setState(() {
            _activeNode = stateful;
            _nodes = updatedPeers
                .map((node) => node.id == active.id ? stateful : node)
                .toList(growable: false);
          });
        }
        if (state == RuntimeHealthState.nodeSpecificDegraded) {
          final measured = updatedPeers
              .where(
                (node) =>
                    node.id != active.id && node.authoritativeLatency != null,
              )
              .toList(growable: false);
          final bestLatency = measured
              .map((node) => node.authoritativeLatency!.inMilliseconds)
              .fold<int?>(
                null,
                (best, value) => best == null || value < best ? value : best,
              );
          final alternative = _selector.select(measured);
          if (alternative != null &&
              _selector.runtimeScore(alternative, bestLatency) >
                  _selector.runtimeScore(stateful, bestLatency) * 1.12) {
            await _switchFromRuntimeDegradation(active);
            return;
          }
        }
      }
      final usable = await _vpn.verifyUsableConnectivity().catchError(
        (_) => false,
      );
      if (!mounted ||
          _phase != ConnectionPhase.connected ||
          _activeNode?.id != active.id) {
        return;
      }
      if (usable) {
        return;
      }
      // Confirm a hard failure immediately instead of waiting for another
      // normal monitoring pulse. Three short checks distinguish an outage
      // from one transient verification failure.
      for (var retry = 0; retry < 2; retry++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (await _vpn.verifyUsableConnectivity().catchError((_) => false)) {
          return;
        }
      }

      _sessionUploadOffsetBytes += _lastStats?.uploadBytes ?? 0;
      _sessionDownloadOffsetBytes += _lastStats?.downloadBytes ?? 0;
      _lastStats = null;
      setState(() => _phase = ConnectionPhase.reconnecting);
      final replacement = await _resolveAndConnect(
        _recoveryPool,
        current: active,
        excludedNodeIds: {active.id},
        reconnect: true,
        reason: SelectionReason.failover,
      );
      if (!mounted) return;
      setState(() {
        _activeNode = replacement;
        _phase = ConnectionPhase.connected;
        _failure = null;
      });
      _connectedAt = DateTime.now();
      unawaited(_recordConnection(replacement, connected: true));
    } catch (error) {
      await _endUsageSession();
      if (!mounted) return;
      _statsTimer?.cancel();
      setState(() {
        _phase = ConnectionPhase.failed;
        _failure = _humanError(error);
      });
      _logger.record(
        category: LogCategory.vpn,
        severity: LogSeverity.error,
        event: 'connection.recovery_failed',
        fields: {'failureType': error.runtimeType.toString()},
      );
    } finally {
      _healthCheckRunning = false;
    }
  }

  Future<void> _switchFromRuntimeDegradation(VpnNode active) async {
    _sessionUploadOffsetBytes += _lastStats?.uploadBytes ?? 0;
    _sessionDownloadOffsetBytes += _lastStats?.downloadBytes ?? 0;
    _lastStats = null;
    setState(() => _phase = ConnectionPhase.reconnecting);
    final replacement = await _resolveAndConnect(
      _recoveryPool,
      current: active,
      excludedNodeIds: {active.id},
      reconnect: true,
      reason: SelectionReason.failover,
    );
    if (!mounted) return;
    setState(() {
      _activeNode = replacement;
      _phase = ConnectionPhase.connected;
      _failure = null;
    });
    _connectedAt = DateTime.now();
    unawaited(_recordConnection(replacement, connected: true));
  }

  Future<void> toggleConnection() async {
    if (_toggleInFlight) return;
    _toggleInFlight = true;
    try {
      await _toggleConnectionInternal();
    } finally {
      _toggleInFlight = false;
    }
  }

  Future<void> _toggleConnectionInternal() async {
    final tapStartedAt = DateTime.now();
    ConnectTrace.emit('timing.connect_tap phase=${_phase.name}');
    void timing(String event) => ConnectTrace.emit(
      'timing.$event elapsedMs=${DateTime.now().difference(tapStartedAt).inMilliseconds}',
    );
    if (_phase == ConnectionPhase.connecting ||
        _phase == ConnectionPhase.preparing ||
        _phase == ConnectionPhase.verifying ||
        _phase == ConnectionPhase.reconnecting) {
      await _connection.cancelConnect();
      if (mounted) {
        setState(() {
          _phase = ConnectionPhase.disconnected;
          _activeNode = null;
          _destinationNode = null;
          _sourceCountryCode = null;
        });
      }
      unawaited(_resolveSourceCountry());
      return;
    }
    if (_phase == ConnectionPhase.connected) {
      _manualPingQueued = false;
      _statsTimer?.cancel();
      _healthTimer?.cancel();
      await _endUsageSession();
      setState(() {
        _phase = ConnectionPhase.disconnecting;
      });
      try {
        await _connection.disconnect();
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _failure = _humanError(error);
        });
      }
      if (!mounted) return;
      setState(() {
        _phase = ConnectionPhase.disconnected;
        _activeNode = null;
        _destinationNode = null;
        _sourceCountryCode = null;
        _connectedHealthReady = false;
      });
      _connectedAt = null;
      // Re-resolve the public source country after disconnect so the globe
      // returns to the user's current egress instead of the previous target.
      unawaited(_resolveSourceCountry());
      await _loadSelectedProfileAfterDisconnect();
      return;
    }
    // Flutter can miss the Android service result broadcast after process
    // recreation. Before starting a new session, reconcile the authoritative
    // cross-process tile state and stop any stale VPN service first.
    final staleNode = await _vpn.activeQuickTileNodeId().catchError(
      (Object _) => null,
    );
    timing('stale_state_checked');
    if (staleNode != null) {
      await _connection.disconnect();
      if (!mounted) return;
      setState(() {
        // The stop command is authoritative, but do not return here: a tap
        // that was intended to connect must continue into the normal start
        // path after the stale service has been asked to stop.
        _phase = ConnectionPhase.preparing;
        _activeNode = null;
        _destinationNode = null;
        _sourceCountryCode = null;
      });
    }
    if (_nodes.isEmpty ||
        _phase == ConnectionPhase.connecting ||
        _phase == ConnectionPhase.preparing) {
      return;
    }
    setState(() {
      _phase = ConnectionPhase.preparing;
      _failure = null;
    });
    // A refresh queued during the previous selector cycle must not trigger a
    // second UI ping after this connection. The connection ping below is the
    // authoritative hot measurement for this attempt.
    _manualPingQueued = false;
    await _pauseProbesForConnection();
    timing('connection_pipeline_started');
    ConnectTrace.emit('connect_request_received');
    developer.log('connect_request_received', name: 'CONNECSO_CONNECT_TRACE');
    final connectionStartedAt = DateTime.now();
    try {
      final selected = await _resolveAndConnect(
        _destinationPool,
        current: _activeNode ?? _lastSuccessfulNode,
      );
      if (!mounted) return;
      setState(() {
        _activeNode = selected;
        _lastSuccessfulNode = selected;
        _nodes = [
          for (final node in _nodes)
            if (node.id == selected.id) selected else node,
        ];
        _phase = ConnectionPhase.connected;
        _connectedHealthReady = false;
      });
      developer.log(
        'ui_connected_state_received',
        name: 'CONNECSO_CONNECT_TRACE',
      );
      _connectedAt = DateTime.now();
      unawaited(_cache.replaceNodes(selected.subscriptionId, _nodes));
      unawaited(
        _recordConnection(
          selected,
          connected: true,
          duration: DateTime.now().difference(connectionStartedAt),
        ),
      );
      _startStatsPolling(newSession: true);
      _startHealthMonitoring();
      // Use the same authoritative path as the Refresh Ping action. This
      // avoids displaying the transient first post-connect sample and keeps
      // the Connected card consistent with a manual refresh.
      unawaited(_refreshConnectionPing());
    } catch (error) {
      if (!mounted) return;
      if (error is ConnectionCancelled) {
        setState(() {
          _phase = ConnectionPhase.disconnected;
          _activeNode = null;
          _failure = null;
        });
        return;
      }
      // Android's VpnService is a separate process. A missed/stale start
      // result can leave a fully usable tunnel alive while this Flutter
      // attempt still holds the failed phase. Reconcile the authoritative
      // native state before exposing a false failure to the user.
      await _synchronizeQuickTileConnection();
      if (!mounted || _phase == ConnectionPhase.connected) return;
      setState(() {
        _phase = ConnectionPhase.failed;
        _failure = _humanError(error);
      });
    } finally {
      _resumeProbesAfterConnection();
    }
  }

  String _humanError(Object error) {
    final strings = AppStrings(_locale);
    if (error is! CoreException) return strings.failed;
    final message = error.message.toLowerCase();
    if (message.contains('permission')) return strings.vpnPermissionFailure;
    if (message.contains('no usable subscription nodes') ||
        message.contains('no compatible vpn core')) {
      return strings.noUsableNodes;
    }
    if (message.contains('could not be verified') ||
        message.contains('connectivity')) {
      return strings.connectivityVerificationFailed;
    }
    if (message.contains('xray') ||
        message.contains('core') ||
        message.contains('runtime') ||
        message.contains('vpn startup')) {
      return strings.xrayUnavailable;
    }
    return strings.failed;
  }

  Future<void> setLanguage(Locale locale) async {
    setState(() {
      _locale = locale;
    });
    await _storage.write(key: 'language', value: locale.languageCode);
  }

  Future<void> setTheme(ThemeMode mode) async {
    final systemMode =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark
        ? ThemeMode.dark
        : ThemeMode.light;
    final effectiveMode = mode == systemMode ? ThemeMode.system : mode;
    setState(() {
      _themeMode = effectiveMode;
    });
    await _storage.write(
      key: 'theme',
      value: effectiveMode == ThemeMode.system
          ? 'system'
          : effectiveMode == ThemeMode.light
          ? 'light'
          : 'dark',
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statsTimer?.cancel();
    _healthTimer?.cancel();
    _subscriptions.close();
    unawaited(_history.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF061925);
    final dark = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: navy,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xFF59CBE8),
            brightness: Brightness.dark,
          ).copyWith(
            surface: const Color(0xFF0A2634),
            surfaceContainerHighest: const Color(0xFF0C2C3A),
            surfaceContainer: const Color(0xFF0D3141),
            outline: const Color(0xFF326A7D),
            primary: const Color(0xFF59CBE8),
            onSurface: const Color(0xFFF4F7FA),
            onSurfaceVariant: const Color(0xFFC8D2DA),
          ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        elevation: 8,
        backgroundColor: Color(0xFF123746),
        contentTextStyle: TextStyle(
          color: Color(0xFFF4F7FA),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      useMaterial3: true,
    );
    final light = ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF2FAFD),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF218DB8))
          .copyWith(
            surface: const Color(0xFFFFFFFF),
            surfaceContainerHighest: const Color(0xFFF4FAFC),
            surfaceContainer: const Color(0xFFEAF6FB),
            outline: const Color(0xFFB9D5E1),
            primary: const Color(0xFF218DB8),
            onSurface: const Color(0xFF10202B),
            onSurfaceVariant: const Color(0xFF344B59),
          ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        elevation: 8,
        backgroundColor: Color(0xFFF9FCFD),
        contentTextStyle: TextStyle(
          color: Color(0xFF10202B),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      useMaterial3: true,
    );
    return MaterialApp(
      title: 'CONNECSO',
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: _debugPerformanceOverlay,
      theme: light,
      darkTheme: dark,
      themeMode: _themeMode,
      locale: _locale,
      supportedLocales: const [Locale('en'), Locale('fa')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: HomeScreen(
        loading: _loading,
        nodes: _nodes,
        phase: _phase,
        activeNode: _activeNode,
        failure: _failure,
        quota: _quota,
        sessionUploadBytes: _sessionUploadBytes,
        sessionDownloadBytes: _sessionDownloadBytes,
        hasSubscriptionUrl: _hasSubscriptionUrl,
        savedSubscriptions: _savedSubscriptions,
        readSavedSubscriptions: () => _savedSubscriptions,
        activeSubscriptionId: _activeSubscriptionId,
        activeSubscriptionName:
            _activeSubscriptionId == null ||
                !_savedSubscriptions.any(
                  (item) => item.id == _activeSubscriptionId,
                )
            ? null
            : _savedSubscriptions
                  .firstWhere((item) => item.id == _activeSubscriptionId)
                  .displayName,
        canManageSubscriptions: !const {
          ConnectionPhase.preparing,
          ConnectionPhase.connecting,
          ConnectionPhase.verifying,
          ConnectionPhase.reconnecting,
          ConnectionPhase.disconnecting,
        }.contains(_phase),
        language: _locale,
        themeMode: _themeMode,
        sourceCountryCode: _sourceCountryCode,
        destination: (_destinationNode ?? _activeNode) == null
            ? null
            : _locations.resolve(_destinationNode ?? _activeNode!),
        splitTunnelingBuilder: (_) => SplitTunnelingScreen(
          language: _locale,
          loadApplications: _installedApplications,
          loadApplicationIcon: _vpn.applicationIcon,
          initialPolicy: _splitPolicy,
          onSave: _saveSplitPolicy,
        ),
        onImport: importSubscription,
        onToggleConnection: toggleConnection,
        onRefreshPing: _refreshConnectionPing,
        refreshingPing: _refreshingConnectionPing,
        connectionHealthReady: _connectedHealthReady,
        onLanguageChanged: setLanguage,
        onThemeChanged: setTheme,
        onSelectSubscription: selectSavedSubscription,
        onEditSubscription: editSavedSubscription,
        onRefreshSubscription: refreshSavedSubscription,
        onDeleteSubscription: deleteSavedSubscription,
        onTogglePinned: setSubscriptionPinned,
        onSignOut: signOutOfSubscription,
        subscriptionRevision: _subscriptionRevisionNotifier,
        connectionMethod: _connectionMethod,
        onConnectionMethodChanged: _setConnectionMethod,
        destinationSelection: _destinationSelection,
        onDestinationSelectionChanged: _setDestinationSelection,
      ),
    );
  }
}
