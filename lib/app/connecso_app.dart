import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../data/repositories/subscription_request_identity.dart';
import '../data/parsers/subscription_parser.dart';
import '../domain/services/usage_service.dart';
import '../domain/services/usage_session_lifecycle.dart';
import '../domain/services/split_tunnel_policy.dart';
import '../domain/services/structured_logger.dart';
import '../domain/services/xray_config_builder.dart';
import '../domain/services/source_country_resolver.dart';
import '../l10n/app_strings.dart';
import '../platform/android/android_vpn_adapter.dart';
import '../platform/android/android_auto_update_service.dart';
import '../platform/android/background_subscription_refresh.dart';
import '../platform/android/xray_proxy_core.dart';
import '../ui/home/home_screen.dart';
import '../ui/home/destination_country_selector.dart';
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
  static final _navigatorKey = GlobalKey<NavigatorState>();
  final _history = AppDatabase();
  late final AndroidVpnAdapter _vpn = AndroidVpnAdapter();
  late final AndroidUpdateService _androidUpdates = AndroidUpdateService(_vpn);
  late final SecureSubscriptionCache _cache = SecureSubscriptionCache(_storage);
  late final SavedSubscriptionsStore _savedStore = SavedSubscriptionsStore(
    _storage,
  );
  late final SubscriptionRepository _subscriptions = SubscriptionRepository(
    cache: _cache,
    directFetcher: _vpn.fetchDirectSubscription,
    currentRouteFetcher: _vpn.fetchCurrentRouteSubscription,
    requestHeadersProvider: SubscriptionRequestIdentity(_storage).headers,
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

  DestinationLocation? _destinationLocationFor(VpnNode? node) {
    if (node == null) return null;
    final explicitCode = LocationResolver.canonicalCountryCode(
      node.countryCode,
    );
    final explicitNameCode = LocationResolver.canonicalCountryCode(
      node.country,
    );
    final trustedCode = explicitCode.isNotEmpty
        ? explicitCode
        : explicitNameCode;
    if (trustedCode.isNotEmpty) {
      return LocationResolver.forCountryCode(trustedCode) ??
          _locations.resolve(node);
    }
    return _locations.resolve(node);
  }

  Future<void> _resolveSourceCountry() async {
    final code = await _sourceCountryResolver.resolve();
    if (mounted && code != null) setState(() => _sourceCountryCode = code);
  }

  Future<List<InstalledApplication>> _installedApplications() {
    final cached = _installedApplicationsCache;
    if (cached != null) return Future.value(cached);
    final pending = _installedApplicationsLoad;
    if (pending != null) return pending;
    late final Future<List<InstalledApplication>> load;
    load = _loadInstalledApplications()
        .then((applications) {
          _installedApplicationsCache = applications;
          return applications;
        })
        .whenComplete(() {
          if (identical(_installedApplicationsLoad, load)) {
            _installedApplicationsLoad = null;
          }
        });
    _installedApplicationsLoad = load;
    return load;
  }

  Future<List<InstalledApplication>> _loadInstalledApplications() async {
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

  List<InstalledApplication>? _installedApplicationsCache;
  Future<List<InstalledApplication>>? _installedApplicationsLoad;

  Timer? _statsTimer;
  Timer? _healthTimer;
  Timer? _quickTileSyncTimer;
  Timer? _speedTestResultTimer;
  DateTime? _connectedAt;
  bool _healthCheckRunning = false;
  bool _statsPollRunning = false;
  int _consecutiveDegradedHealthChecks = 0;
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
  Set<String> _favoriteDestinationKeys = {};
  String? _recentDestinationCountryCode;
  Future<void> _destinationSelectionQueue = Future<void>.value();
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
  bool _performanceMode = false;
  bool _speedTestRunning = false;
  double? _speedTestMbps;
  String? _speedTestError;
  String? _lastWidgetSyncKey;
  bool _autoUpdateEnabled = false;
  bool _updateUseActiveRoute = true;
  bool _updateIncludePrerelease = true;
  bool _updateCheckInFlight = false;
  String _appVersion = '0.0.0';
  Timer? _updateCheckTimer;
  // Keep the initial frame in its loading state until the cached subscriptions
  // and destinations have been restored, so an empty list is never flashed.
  bool _loading = true;
  bool _synchronizingTileConnection = false;
  bool _toggleInFlight = false;
  int _connectionRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveSourceCountry());
    WidgetsBinding.instance.addObserver(this);
    // DNS leak protection is always enabled; it has no user-facing toggle.
    _vpn.fakeDnsEnabled = true;
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
    unawaited(_loadAndroidAppVersion());
    _updateCheckTimer = Timer.periodic(const Duration(hours: 6), (_) {
      if (_autoUpdateEnabled)
        unawaited(_checkForAndroidUpdates(automatic: true));
    });
  }

  Future<void> _loadAndroidAppVersion() async {
    try {
      final version = await _androidUpdates.installedVersion();
      if (mounted && version != _appVersion)
        setState(() => _appVersion = version);
    } catch (_) {}
  }

  Future<void> _restore() async {
    final restore = _restoreFromStorage();
    try {
      await restore.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      _logger.record(
        category: LogCategory.subscription,
        severity: LogSeverity.warning,
        event: 'startup.restore_timed_out',
      );
      if (mounted) setState(() => _loading = false);
      // Secure storage calls cannot be cancelled. Keep listening so a slow
      // platform response can still restore the saved state when it arrives.
      unawaited(
        restore.catchError((Object error) => _recordRestoreFailure(error)),
      );
    } catch (error) {
      _recordRestoreFailure(error);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restoreFromStorage() async {
    final values = await Future.wait<Object?>([
      _readSavedSubscriptions(),
      _readStartupValue('subscription_nodes_v1'),
      _readStartupValue('subscription_url_v1'),
      _readStartupValue('subscription_quota_v1'),
      _readStartupValue('subscription_active_v1'),
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
      try {
        await _savedStore
            .write(subscriptions)
            .timeout(const Duration(seconds: 10));
        await _storage
            .write(key: 'subscription_active_v1', value: activeId)
            .timeout(const Duration(seconds: 10));
      } catch (error) {
        _recordRestoreFailure(error);
      }
    }
    if (!subscriptions.any((item) => item.id == activeId)) {
      activeId =
          subscriptions.where((item) => item.pinned).firstOrNull?.id ??
          subscriptions.firstOrNull?.id;
      if (activeId != null) {
        try {
          await _storage
              .write(key: 'subscription_active_v1', value: activeId)
              .timeout(const Duration(seconds: 10));
        } catch (error) {
          _recordRestoreFailure(error);
        }
      }
    }
    var nodes = const <VpnNode>[];
    if (activeId != null) {
      try {
        nodes = await _subscriptions
            .cachedNodes(activeId)
            .timeout(const Duration(seconds: 10));
      } catch (error) {
        _logger.record(
          category: LogCategory.subscription,
          severity: LogSeverity.warning,
          event: 'startup.node_cache_read_failed',
          fields: {'failureType': error.runtimeType.toString()},
        );
      }
    }
    // Older single-profile builds stored nodes under one global key. If the
    // profile now has a generated ID, safely migrate that cache only when it
    // is unambiguous which saved profile owns it.
    final legacyNodesJson = values[1] as String?;
    if (nodes.isEmpty &&
        activeId != null &&
        subscriptions.length == 1 &&
        legacyNodesJson?.isNotEmpty == true) {
      try {
        final legacyNodes = decodeNodes(legacyNodesJson!);
        if (legacyNodes.isNotEmpty) {
          nodes = legacyNodes
              .map(
                (node) => VpnNode.fromJson({
                  ...node.toJson(),
                  'subscriptionId': activeId,
                }),
              )
              .toList(growable: false);
          await _cache.replaceNodes(activeId, nodes);
          _logger.record(
            category: LogCategory.subscription,
            severity: LogSeverity.info,
            event: 'startup.legacy_node_cache_migrated',
            fields: {'count': nodes.length},
          );
        }
      } catch (error) {
        _logger.record(
          category: LogCategory.subscription,
          severity: LogSeverity.warning,
          event: 'startup.legacy_node_cache_migration_failed',
          fields: {'failureType': error.runtimeType.toString()},
        );
      }
    }
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
      _quota = active?.quota ?? QuotaSnapshot.unavailable();
      _hasSubscriptionUrl = active?.endpoint?.isNotEmpty == true;
      // Show the decrypted last-known profile and node list before restoring
      // secondary preferences; their secure-storage reads must not hold the
      // first usable screen behind a spinner.
      _loading = false;
    });

    final preferences = await Future.wait<Object?>([
      _readStartupValue('language'),
      _readStartupValue('theme'),
      _readStartupValue('split_tunnel_policy_v1'),
      _readStartupValue('performance_mode_v1'),
      _readStartupValue('auto_update_enabled_v1'),
      _readStartupValue('update_use_active_route_v1'),
      _readStartupValue('update_include_prerelease_v1'),
      _readStartupValue('favorite_destination_countries_v1'),
      _readStartupValue('recent_destination_country_v1'),
    ]);
    if (!mounted) return;
    setState(() {
      if (preferences[0] is String) {
        _locale = preferences[0] == 'fa'
            ? const Locale('fa')
            : const Locale('en');
      }
      if (preferences[1] == 'light') {
        _themeMode = ThemeMode.light;
      } else if (preferences[1] == 'dark') {
        _themeMode = ThemeMode.dark;
      }
      _splitPolicy = _readSplitPolicy(preferences[2]);
      _performanceMode = preferences[3] == 'true';
      _autoUpdateEnabled = preferences[4] == 'true';
      _updateUseActiveRoute = preferences[5] != 'false';
      _updateIncludePrerelease = preferences[6] != 'false';
      final favoriteValue = preferences[7];
      if (favoriteValue is String) {
        try {
          final decoded = jsonDecode(favoriteValue);
          if (decoded is List) {
            _favoriteDestinationKeys = decoded
                .whereType<String>()
                // Country codes are case-insensitive; node IDs after the
                // `node:` prefix are opaque and must retain their exact case.
                .map((key) => key.startsWith('node:') ? key : key.toUpperCase())
                .toSet();
          }
        } on FormatException {
          _favoriteDestinationKeys = {};
        }
      }
      _recentDestinationCountryCode = preferences[8] as String?;
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
      final savedNodeId = await _storage.read(key: 'destination_node_v1');
      setState(
        () => _destinationSelection = DestinationSelection.country(
          savedCountry,
          method: _connectionMethod,
          nodeId: savedNodeId,
        ),
      );
    }
    if (_autoUpdateEnabled) unawaited(_checkForAndroidUpdates(automatic: true));
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
    // Render the last validated node cache immediately, then refresh the
    // active subscription in the background. This also repopulates the list
    // on first launch or after a damaged/empty node cache.
    final activeEndpoint = active?.endpoint;
    final activeUri = activeEndpoint == null
        ? null
        : Uri.tryParse(activeEndpoint);
    if (active != null &&
        activeUri != null &&
        activeUri.scheme == 'https' &&
        activeUri.host.isNotEmpty &&
        (active.autoRefreshEnabled || nodes.isEmpty)) {
      unawaited(
        _refreshSubscription(
          activeUri,
          subscriptionId: active.id,
          reportErrors: false,
        ),
      );
    }
  }

  Future<List<SavedSubscription>> _readSavedSubscriptions() async {
    try {
      return await _savedStore.read().timeout(const Duration(seconds: 15));
    } catch (error) {
      _logger.record(
        category: LogCategory.subscription,
        severity: LogSeverity.warning,
        event: 'startup.subscription_store_read_failed',
        fields: {'failureType': error.runtimeType.toString()},
      );
      return const [];
    }
  }

  Future<String?> _readStartupValue(String key) async {
    try {
      return await _storage.read(key: key).timeout(const Duration(seconds: 10));
    } catch (error) {
      _logger.record(
        category: LogCategory.subscription,
        severity: LogSeverity.warning,
        event: 'startup.preference_read_failed',
        fields: {'key': key, 'failureType': error.runtimeType.toString()},
      );
      return null;
    }
  }

  void _recordRestoreFailure(Object error) {
    _logger.record(
      category: LogCategory.subscription,
      severity: LogSeverity.warning,
      event: 'startup.restore_failed',
      fields: {'failureType': error.runtimeType.toString()},
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
    bool preferLastSuccessfulNode = true,
    Set<String> excludedNodeIds = const {},
    bool reconnect = false,
    SelectionReason? reason,
  }) async {
    final startedAt = DateTime.now();
    final candidateNodes = nodes.toList(growable: false);
    // Freeze the user's destination for the whole failover transaction. A
    // retry must never silently switch from a manually selected country to
    // Auto because another UI state update happened while probing.
    final requestedSelection = _destinationSelection.copyWith(
      method: _connectionMethod,
    );
    ConnectTrace.emit(
      'selection.resolution_start mode=${requestedSelection.mode.name} '
      'country=${requestedSelection.countryCode ?? 'AUTO'} '
      'method=${requestedSelection.method?.name ?? 'AUTO'} '
      'nodes=${candidateNodes.length}',
    );
    final countryCounts = <String, int>{};
    for (final node in candidateNodes) {
      final code = LocationResolver.canonicalCountryCode(
        '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
      );
      countryCounts.update(
        code.isEmpty ? '??' : code,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    ConnectTrace.emit(
      'selection.candidate_countries ${countryCounts.entries.map((e) => '${e.key}:${e.value}').join(',')}',
    );
    return _connection.connectWithFailover(
      splitTunnelPolicy: _splitPolicy,
      reconnect: reconnect,
      resolve: (excluded) async {
        ConnectTrace.emit('timing.resolver_start');
        final resolution = await _endpointResolver.resolveCandidates(
          nodes: candidateNodes,
          selection: requestedSelection,
          preferredCountryCodes: _preferredAutoCountryCodes(candidateNodes),
          // A manual country switch must not inherit endpoint affinity from
          // the previous country. That stale affinity can make the resolver
          // keep returning the old route even though the UI selection changed.
          current:
              current ??
              (preferLastSuccessfulNode ? _lastSuccessfulNode : null),
          excludedNodeIds: {...excludedNodeIds, ...excluded},
          reason: reason,
          lastGoodNodeId: preferLastSuccessfulNode
              ? _lastSuccessfulNode?.id
              : null,
        );
        ConnectTrace.emit(
          'timing.resolver_ready elapsedMs=${DateTime.now().difference(startedAt).inMilliseconds} '
          'candidates=${resolution.endpoints.length} checked=${resolution.checkedNodeIds.length}',
        );
        final selectedCountry = requestedSelection.countryCode;
        if (selectedCountry != null) {
          final strictlyScoped = resolution.endpoints
              .where((endpoint) {
                final actualCountry =
                    _locations.resolve(endpoint.node)?.countryCode ??
                    LocationResolver.canonicalCountryCode(
                      '${endpoint.node.countryCode ?? ''} '
                      '${endpoint.node.country ?? ''} ${endpoint.node.name}',
                    );
                return actualCountry == selectedCountry;
              })
              .toList(growable: false);
          if (strictlyScoped.length != resolution.endpoints.length) {
            ConnectTrace.emit(
              'selection.scope_violation selected=$selectedCountry '
              'returned=${resolution.endpoints.map((e) => e.node.id).join(',')}',
            );
          }
          return EndpointResolution(
            endpoints: List.unmodifiable(strictlyScoped),
            checkedNodeIds: resolution.checkedNodeIds,
          );
        }
        return resolution;
      },
    );
  }

  Set<String> _preferredAutoCountryCodes(Iterable<VpnNode> nodes) {
    final countries = <String>{};
    for (final node in nodes) {
      final code = LocationResolver.canonicalCountryCode(
        '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
      );
      if (code.isNotEmpty &&
          (_favoriteDestinationKeys.contains('node:${node.id}') ||
              _favoriteDestinationKeys.contains(code))) {
        countries.add(code);
      }
    }
    return countries;
  }

  Future<void> _setConnectionMethod(ConnectionMethod? method) async {
    if (method != null &&
        !ConnectionMethod.available(_nodes).contains(method)) {
      return;
    }
    final country = _destinationSelection.countryCode;
    // Keep the manually chosen country even when the newly selected transport
    // is unavailable there; clear the transport selection instead of
    // resetting the destination to Auto.
    final methodAvailableInCountry =
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
    final effectiveMethod = methodAvailableInCountry ? method : null;
    setState(() {
      _connectionMethod = effectiveMethod;
    });
    if (effectiveMethod == null) {
      await _storage.delete(key: 'connection_method_v1');
    } else {
      await _storage.write(
        key: 'connection_method_v1',
        value: effectiveMethod.name,
      );
    }
  }

  Future<void> _setDestinationSelection(DestinationSelection selection) {
    final operation = _destinationSelectionQueue.then(
      (_) => _applyDestinationSelection(selection),
    );
    _destinationSelectionQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> setDestinationFavorite(
    String destinationKey,
    bool favorite,
  ) async {
    final key = destinationKey.startsWith('node:')
        ? destinationKey
        : destinationKey.toUpperCase();
    final next = {..._favoriteDestinationKeys};
    if (favorite) {
      next.add(key);
    } else {
      next.remove(key);
    }
    if (mounted) setState(() => _favoriteDestinationKeys = next);
    await _storage.write(
      key: 'favorite_destination_countries_v1',
      value: jsonEncode(next.toList()..sort()),
    );
  }

  Future<void> _applyDestinationSelection(
    DestinationSelection selection,
  ) async {
    final previousCountry = _destinationSelection.countryCode;
    final previousNodeId = _destinationSelection.nodeId;
    final previousMethod = _destinationSelection.method ?? _connectionMethod;
    // A country-only selection is also a request to choose among that
    // country's available transports. Keep a method only when the user picked
    // a specific server/method explicitly; stale global method preferences
    // must not force the previous route (or DIRECT/WARP fallback) on it.
    var nextMethod = selection.nodeId != null || selection.method != null
        ? selection.method
        : null;
    final selectedCountry = selection.countryCode;
    if (selectedCountry != null && nextMethod != null) {
      final hasMethodInCountry = _nodes.any((node) {
        if (!node.enabled || !nextMethod!.matches(node)) return false;
        final country =
            _locations.resolve(node)?.countryCode ??
            LocationResolver.canonicalCountryCode(
              '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
            );
        return country == selectedCountry;
      });
      // A globally selected transport may not exist in the newly selected
      // country. Fall back to automatic transport selection immediately so
      // the first connection attempt can use that country's available nodes.
      if (!hasMethodInCountry) nextMethod = null;
    }
    setState(() {
      _destinationSelection = selection.copyWith(method: nextMethod);
      _connectionMethod = nextMethod;
    });
    ConnectTrace.emit(
      'selection.changed mode=${selection.mode.name} '
      'country=${selection.countryCode ?? 'AUTO'} '
      'method=${nextMethod?.name ?? 'AUTO'}',
    );
    if (nextMethod == null && selectedCountry != null) {
      await _storage.delete(key: 'connection_method_v1');
    }
    await _storage.write(
      key: 'destination_mode_v1',
      value: selection.mode.name,
    );
    if (selection.countryCode == null) {
      await _storage.delete(key: 'destination_country_v1');
      await _storage.delete(key: 'destination_node_v1');
    } else {
      await _storage.write(
        key: 'destination_country_v1',
        value: selection.countryCode,
      );
      if (mounted) {
        setState(() => _recentDestinationCountryCode = selection.countryCode);
      }
      await _storage.write(
        key: 'recent_destination_country_v1',
        value: selection.countryCode,
      );
      if (selection.nodeId == null) {
        await _storage.delete(key: 'destination_node_v1');
      } else {
        await _storage.write(
          key: 'destination_node_v1',
          value: selection.nodeId,
        );
      }
    }
    // A country change while connected enters the same full reconnect
    // pipeline as Auto mode after restricting the endpoint pool.
    final tunnelWasConnected =
        _phase == ConnectionPhase.connected ||
        _connection.status.phase == ConnectionPhase.connected;
    if ((selection.countryCode != previousCountry ||
            selection.nodeId != previousNodeId ||
            nextMethod != previousMethod) &&
        tunnelWasConnected &&
        _nodes.isNotEmpty) {
      // A manual destination change rebuilds the same full VPN pipeline as a
      // fresh Auto connection. Stop observers tied to the previous TUN/core
      // before tearing it down, then start them again only after the new
      // dataplane has been verified.
      _manualPingQueued = false;
      _statsTimer?.cancel();
      _healthTimer?.cancel();
      setState(() {
        _phase = ConnectionPhase.reconnecting;
        _failure = null;
      });
      ConnectTrace.emit(
        'destination.switch_start from=${previousCountry ?? 'AUTO'} '
        'to=${selection.countryCode ?? 'AUTO'}',
      );
      try {
        // Fully stop the old VPN/core before resolving the new route. The
        // reconnect flag can keep the existing Android VPN session alive,
        // which leaves the old country active on some devices.
        setState(() {
          _phase = ConnectionPhase.disconnecting;
          _activeNode = null;
          _destinationNode = null;
        });
        await _connection.disconnect();
        if (!mounted) return;
        setState(() {
          _phase = ConnectionPhase.reconnecting;
        });
        final selected = await _resolveAndConnect(
          _destinationPool,
          // A previous country's healthy endpoint must never bias resolution
          // for a newly selected destination.
          current: null,
          preferLastSuccessfulNode: false,
          reconnect: false,
        );
        final actualCountry =
            _locations.resolve(selected)?.countryCode ??
            LocationResolver.canonicalCountryCode(
              '${selected.countryCode ?? ''} ${selected.country ?? ''} ${selected.name}',
            );
        if (selection.countryCode != null &&
            actualCountry != selection.countryCode) {
          await _connection.disconnect();
          throw StateError(
            'Selected route country $actualCountry does not match '
            '${selection.countryCode}.',
          );
        }
        if (mounted) {
          setState(() {
            _activeNode = selected;
            _destinationNode = selected;
            _phase = ConnectionPhase.connected;
            _failure = null;
          });
          ConnectTrace.emit(
            'destination.switch_complete country=${actualCountry.isEmpty ? 'AUTO' : actualCountry} '
            'node=${selected.id}',
          );
          _connectedAt = DateTime.now();
          _startStatsPolling(newSession: true);
          _startHealthMonitoring();
          unawaited(_refreshConnectionPing());
        }
      } catch (error) {
        // Do not leave the previous route running if rebuilding the selected
        // country fails partway through.
        try {
          await _connection.disconnect();
        } catch (_) {}
        if (mounted) {
          setState(() {
            _phase = ConnectionPhase.disconnected;
            _activeNode = null;
            _destinationNode = null;
            _failure = _humanError(error);
          });
        }
        ConnectTrace.emit(
          'destination.switch_failed country=${selection.countryCode ?? 'AUTO'} '
          'failureType=${error.runtimeType}',
        );
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
    final tileState = await _vpn.quickTileConnection();
    final nodeId = tileState['nodeId'] as String?;
    final sessionPresent =
        tileState['active'] == true || tileState['serviceRunning'] == true;
    VpnNode? tileNode;
    if (sessionPresent && nodeId != null) {
      tileNode = nodes.where((node) => node.id == nodeId).firstOrNull;
      for (final profile in subscriptions) {
        if (tileNode != null) break;
        final cached = await _subscriptions.cachedNodes(profile.id);
        tileNode = cached.where((node) => node.id == nodeId).firstOrNull;
        if (tileNode != null) break;
      }
      // The native service writes `active` only after Xray and the TUN engine
      // have started successfully. Do not gate session restoration on an
      // Internet probe here: a temporary timeout after returning from the
      // background must not make a still-running tunnel look disconnected.
    }
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading) {
      unawaited(_synchronizeQuickTileConnection());
      _quickTileSyncTimer?.cancel();
      _quickTileSyncTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted && !_loading) {
          unawaited(_synchronizeQuickTileConnection());
        }
      });
      if (_autoUpdateEnabled) {
        unawaited(_checkForAndroidUpdates(automatic: true));
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _quickTileSyncTimer?.cancel();
      _quickTileSyncTimer = null;
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
        tileNode =
            <VpnNode?>[
                  _activeNode,
                  _lastSuccessfulNode,
                  _destinationNode,
                  ..._nodes,
                ]
                .whereType<VpnNode>()
                .where((node) => node.id == tileNodeId)
                .firstOrNull;
        for (final profile in subscriptions) {
          if (tileNode != null) break;
          final cached = await _subscriptions.cachedNodes(profile.id);
          final matches = cached.where((node) => node.id == tileNodeId);
          if (matches.isNotEmpty) {
            tileNode = matches.first;
            break;
          }
        }
      }
      if (!mounted) return;
      // `active` is persisted by the VPN service only after successful native
      // dataplane startup, and `serviceRunning` confirms the tunnel-owning
      // service survived while Flutter was backgrounded. An HTTP reachability
      // check is intentionally not part of UI state restoration: transient
      // network stalls must not erase a live session from the screen.
      final nativeSessionActive =
          tileNode != null && (tileActive || serviceRunning);
      if (nativeSessionActive &&
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
      } else if (tileNode == null &&
          !tileActive &&
          !serviceRunning &&
          _phase == ConnectionPhase.connected) {
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
    if (mounted) setState(() => _splitPolicy = policy);
    await _storage.write(
      key: 'split_tunnel_policy_v1',
      value: jsonEncode(policy.toJson()),
    );
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
      // Update the selected profile's destination catalog immediately even
      // while an older tunnel is still connected. The active tunnel remains
      // represented by _activeNode until the user reconnects or switches.
      _nodes = imported;
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
    if (endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty) {
      throw StateError('This subscription does not have a valid HTTPS link.');
    }
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
        accountEmail: result.accountEmail,
        supportUrl: result.supportUrl,
        profileUrl: result.profileUrl,
        announcement: result.announcement,
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
      final isConnected = _phase == ConnectionPhase.connected;
      setState(() {
        _savedSubscriptions = subscriptions;
        if (selected) {
          _quota = result.quota;
          _hasSubscriptionUrl = true;
          // Destination browsing follows the selected subscription even if
          // an older profile's tunnel is still active. Keep that live route
          // untouched until the user explicitly reconnects.
          _nodes = result.nodes;
          if (!isConnected) {
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
      if (selected && !isConnected) {
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

  /// Use the same CoreNodeProbe pipeline as the live ping below Connect.
  Future<void> _destinationPingQueue = Future<void>.value();
  int _destinationPingGeneration = 0;

  Future<void> _cancelDestinationPings() async {
    _destinationPingGeneration++;
    await _vpn.cancelDestinationPings();
  }

  Future<Map<String, Duration?>> _pingDestinations(
    List<VpnNode> requestedNodes, {
    DestinationPingProgress? onProgress,
  }) {
    final generation = _destinationPingGeneration;
    final operation = _destinationPingQueue.then((_) async {
      if (generation != _destinationPingGeneration) {
        return {for (final node in requestedNodes) node.id: null};
      }
      final liveResults = <String, Duration?>{};
      _vpn.setDestinationPingProgressHandler((nodeId, latency) {
        // A later timeout/failed retry must never erase a warm RTT that was
        // already delivered from native progress for this same destination.
        if (latency != null) {
          liveResults[nodeId] = latency;
          _storeDestinationWarmRtt(nodeId, latency);
        }
        if (latency != null || liveResults[nodeId] == null) {
          onProgress?.call(nodeId, latency);
        }
      });
      try {
        return await _runDestinationPings(
          requestedNodes,
          liveResults: liveResults,
          generation: generation,
        );
      } finally {
        _vpn.setDestinationPingProgressHandler(null);
      }
    });
    _destinationPingQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  void _storeDestinationWarmRtt(String nodeId, Duration latency) {
    if (latency.inMilliseconds <= 0) return;
    final index = _nodes.indexWhere((node) => node.id == nodeId);
    if (index < 0) return;
    final node = _nodes[index];
    final now = DateTime.now().toUtc();
    final observations = node.successCount + node.failureCount;
    final recentPings = [...node.last5Pings, latency.inMilliseconds];
    if (recentPings.length > 5) {
      recentPings.removeRange(0, recentPings.length - 5);
    }
    final updated = VpnNode.fromJson({
      ...node.toJson(),
      'latencyMs': latency.inMilliseconds,
      'lastProbe': now.toIso8601String(),
      'lastSuccess': now.toIso8601String(),
      'successCount': node.successCount + 1,
      'stabilityScore':
          ((node.stabilityScore * observations) + 1) / (observations + 1),
      'health': latency <= const Duration(milliseconds: 1500)
          ? NodeHealth.healthy.name
          : NodeHealth.degraded.name,
      'runtimeState': RuntimeHealthState.healthy.name,
      'last5Pings': recentPings,
    });
    final updatedNodes = [..._nodes]..[index] = updated;
    if (mounted) setState(() => _nodes = updatedNodes);
    unawaited(
      _cache
          .replaceNodes(
            node.subscriptionId,
            updatedNodes
                .where((item) => item.subscriptionId == node.subscriptionId)
                .toList(growable: false),
          )
          .catchError(_logPersistenceFailure),
    );
  }

  Future<Map<String, Duration?>> _runDestinationPings(
    List<VpnNode> requestedNodes, {
    required Map<String, Duration?> liveResults,
    required int generation,
  }) async {
    final candidates = <String, VpnNode>{
      for (final node in requestedNodes)
        if (node.enabled) node.id: node,
    }.values.toList(growable: false);
    if (candidates.isEmpty) return const {};
    final results = <String, Duration?>{};
    final sweepClock = Stopwatch()..start();
    Future<Map<String, Duration?>> pingBatch(
      List<VpnNode> batch,
      int worker,
    ) async {
      if (batch.isEmpty || generation != _destinationPingGeneration) {
        return const {};
      }
      try {
        return await _vpn
            .pingDestinations(batch, worker: worker)
            .timeout(const Duration(seconds: 45));
      } on TimeoutException {
        await _vpn.cancelDestinationPings();
        _logger.record(
          category: LogCategory.recovery,
          severity: LogSeverity.warning,
          event: 'destination.rtt_batch_timed_out',
          fields: {'nodeCount': batch.length, 'worker': worker},
        );
        return {for (final node in batch) node.id: null};
      } on Object catch (error) {
        _logger.record(
          category: LogCategory.recovery,
          severity: LogSeverity.warning,
          event: 'destination.rtt_batch_failed',
          fields: {
            'failureType': error.runtimeType.toString(),
            'nodeCount': batch.length,
            'worker': worker,
          },
        );
        return {for (final node in batch) node.id: null};
      }
    }

    // Process waves in visible list order. Each wave keeps the previous fast
    // two-worker setup; results still arrive per node as its RTT completes.
    final retryNodes = <VpnNode>[];
    for (var index = 0; index < candidates.length; index += 20) {
      if (generation != _destinationPingGeneration) break;
      final batch = candidates.skip(index).take(20).toList(growable: false);
      final firstHalf = batch.take(10).toList(growable: false);
      final secondHalf = batch.skip(10).take(10).toList(growable: false);
      final waveResults = await Future.wait([
        pingBatch(firstHalf, 0),
        if (secondHalf.isNotEmpty) pingBatch(secondHalf, 1),
      ]);
      final completed = <String, Duration?>{
        for (final result in waveResults) ...result,
      };
      if (generation != _destinationPingGeneration) break;
      for (final node in batch) {
        final measured = completed[node.id];
        final warmRtt = liveResults[node.id] ?? measured;
        results[node.id] = warmRtt;
        if (warmRtt == null) retryNodes.add(node);
      }
    }

    // Retry only misses once after the main sweep, in groups. This avoids
    // stalling the first-pass queue behind a single unavailable endpoint.
    for (var index = 0; index < retryNodes.length; index += 20) {
      if (generation != _destinationPingGeneration) break;
      final batch = retryNodes.skip(index).take(20).toList(growable: false);
      final firstHalf = batch.take(10).toList(growable: false);
      final secondHalf = batch.skip(10).take(10).toList(growable: false);
      final waveResults = await Future.wait([
        pingBatch(firstHalf, 0),
        if (secondHalf.isNotEmpty) pingBatch(secondHalf, 1),
      ]);
      final completed = <String, Duration?>{
        for (final result in waveResults) ...result,
      };
      for (final node in batch) {
        final measured = liveResults[node.id] ?? completed[node.id];
        if (measured != null) results[node.id] = measured;
      }
    }
    final finalResults = {
      for (final node in candidates)
        node.id: liveResults[node.id] ?? results[node.id],
    };
    _logger.record(
      category: LogCategory.probe,
      severity: LogSeverity.info,
      event: 'destination.rtt_sweep_completed',
      fields: {
        'requestedCount': candidates.length,
        'successCount': finalResults.values.whereType<Duration>().length,
        'retryCount': retryNodes.length,
        'elapsedMs': sweepClock.elapsedMilliseconds,
        'workerBatchSize': 10,
        'parallelWorkers': 2,
      },
    );
    return finalResults;
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
      _nodes = nodes;
      if (!connected) {
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
      if (_statsPollRunning) return;
      _statsPollRunning = true;
      try {
        final stats = await _vpn.readStats();
        if (!mounted || _phase != ConnectionPhase.connected) return;
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
      } finally {
        _statsPollRunning = false;
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
    _consecutiveDegradedHealthChecks = 0;
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
        _consecutiveDegradedHealthChecks =
            state == RuntimeHealthState.nodeSpecificDegraded
            ? _consecutiveDegradedHealthChecks + 1
            : 0;
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
          // A single delayed ping is not enough evidence to move a live
          // tunnel. Require sustained degradation across several monitoring
          // cycles before attempting an automatic failover.
          if (_consecutiveDegradedHealthChecks >= 3 &&
              alternative != null &&
              _selector.runtimeScore(alternative, bestLatency) >
                  _selector.runtimeScore(stateful, bestLatency) * 1.12) {
            await _switchFromRuntimeDegradation(active);
            return;
          }
        }
      } else {
        // An unsuccessful probe is advisory only. Do not let it accumulate
        // toward a runtime failover decision.
        _consecutiveDegradedHealthChecks = 0;
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

      // The connectivity probe can fail while the native Xray/TUN dataplane
      // is still alive. A stats response comes directly from the VPN service
      // and distinguishes a bad health-check sample from a stopped tunnel.
      if (await _nativeDataplaneRunning()) {
        _logger.record(
          category: LogCategory.probe,
          severity: LogSeverity.warning,
          event: 'connection.health_probe_failed_dataplane_alive',
          fields: {'nodeId': active.id},
        );
        return;
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
      if (await _nativeDataplaneRunning() && mounted) {
        setState(() {
          _phase = ConnectionPhase.connected;
          _failure = null;
        });
        _logger.record(
          category: LogCategory.recovery,
          severity: LogSeverity.warning,
          event: 'connection.recovery_deferred_dataplane_alive',
          fields: {'failureType': error.runtimeType.toString()},
        );
        return;
      }
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

  Future<bool> _nativeDataplaneRunning() async {
    try {
      await _vpn.readStats();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _switchFromRuntimeDegradation(VpnNode active) async {
    _consecutiveDegradedHealthChecks = 0;
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
    if (_toggleInFlight) {
      if ({
        ConnectionPhase.preparing,
        ConnectionPhase.connecting,
        ConnectionPhase.verifying,
        ConnectionPhase.reconnecting,
      }.contains(_phase)) {
        _connectionRequestGeneration++;
        await _connection.cancelConnect();
        if (mounted) {
          setState(() {
            _phase = ConnectionPhase.disconnected;
            _activeNode = null;
            _destinationNode = null;
            _failure = null;
          });
        }
      }
      return;
    }
    _toggleInFlight = true;
    final requestGeneration = ++_connectionRequestGeneration;
    try {
      await _toggleConnectionInternal(requestGeneration);
    } finally {
      _toggleInFlight = false;
    }
  }

  Future<void> _toggleConnectionInternal(int requestGeneration) async {
    final tapStartedAt = DateTime.now();
    ConnectTrace.emit('timing.connect_tap phase=${_phase.name}');
    void timing(String event) => ConnectTrace.emit(
      'timing.$event elapsedMs=${DateTime.now().difference(tapStartedAt).inMilliseconds}',
    );
    if (requestGeneration != _connectionRequestGeneration) return;
    final transitionInProgress = {
      ConnectionPhase.preparing,
      ConnectionPhase.connecting,
      ConnectionPhase.verifying,
      ConnectionPhase.reconnecting,
      ConnectionPhase.disconnecting,
    }.contains(_phase);
    if (!transitionInProgress) {
      // The widget and notification can change the native VPN state while
      // this screen is open. Reconcile before interpreting this tap so the
      // main button acts on the real tunnel state instead of stale UI state.
      try {
        await _synchronizeQuickTileConnection();
      } catch (error) {
        // A transient native state-read failure must not make the primary
        // connect control inert; its normal start/stop path remains available.
        ConnectTrace.emit(
          'native_state_reconcile_failed type=${error.runtimeType}',
        );
      }
      timing('native_state_reconciled');
    }
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
      VpnNode? selected;
      Object? lastAttemptError;
      for (var retry = 0; retry < 3; retry++) {
        if (requestGeneration != _connectionRequestGeneration) {
          throw const ConnectionCancelled();
        }
        if (retry > 0 && mounted) {
          setState(() {
            _phase = ConnectionPhase.preparing;
            _failure = null;
          });
          ConnectTrace.emit('automatic_connect_retry attempt=${retry + 1}/3');
        }
        try {
          selected = await _resolveAndConnect(
            _destinationPool,
            // Reuse a known-good endpoint only while the destination scope is
            // unchanged. Country/method changes need a fresh scoped resolution.
            current:
                _activeNode?.id == _lastSuccessfulNode?.id &&
                    _destinationNode?.id == _activeNode?.id
                ? _activeNode
                : null,
          );
          break;
        } catch (error) {
          lastAttemptError = error;
          if (error is ConnectionCancelled ||
              requestGeneration != _connectionRequestGeneration ||
              retry == 2) {
            rethrow;
          }
        }
      }
      if (selected == null)
        throw lastAttemptError ?? StateError('Connect failed.');
      final connectedNode = selected;
      if (!mounted) return;
      setState(() {
        _activeNode = connectedNode;
        _lastSuccessfulNode = connectedNode;
        _nodes = [
          for (final node in _nodes)
            if (node.id == connectedNode.id) connectedNode else node,
        ];
        _phase = ConnectionPhase.connected;
        _connectedHealthReady = false;
      });
      developer.log(
        'ui_connected_state_received',
        name: 'CONNECSO_CONNECT_TRACE',
      );
      _connectedAt = DateTime.now();
      try {
        await _cache.replaceNodes(connectedNode.subscriptionId, _nodes);
      } catch (error) {
        _logPersistenceFailure(error);
      }
      unawaited(
        _recordConnection(
          connectedNode,
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
      ConnectTrace.emit(
        'connection_pipeline_failed type=${error.runtimeType} '
        'detail=${error is CoreException ? error.message.replaceAll(RegExp(r'\s+'), ' ') : error.runtimeType}',
      );
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

  Future<void> setPerformanceMode(bool enabled) async {
    if (_performanceMode == enabled) return;
    setState(() => _performanceMode = enabled);
    await _storage.write(
      key: 'performance_mode_v1',
      value: enabled ? 'true' : 'false',
    );
  }

  Future<void> _runSpeedTest() async {
    if (_speedTestRunning || _phase != ConnectionPhase.connected) return;
    setState(() {
      _speedTestRunning = true;
      _speedTestMbps = null;
      _speedTestError = null;
    });
    try {
      final result = await _vpn.runSpeedTest();
      final value = result['megabitsPerSecond'];
      if (!mounted) return;
      setState(() => _speedTestMbps = value is num ? value.toDouble() : null);
      // Read the authoritative Xray/TUN counters immediately after the test.
      // Do not add the speed-test byte count to session usage: only the tunnel
      // dataplane counters determine the displayed and persisted totals.
      try {
        final stats = await _vpn.readStats();
        if (mounted && _phase == ConnectionPhase.connected) {
          _lastStats = stats;
          setState(() {
            _sessionUploadBytes = _sessionUploadOffsetBytes + stats.uploadBytes;
            _sessionDownloadBytes =
                _sessionDownloadOffsetBytes + stats.downloadBytes;
          });
        }
      } catch (_) {
        // The regular session poll will refresh once the native counters respond.
      }
      _speedTestResultTimer?.cancel();
      _speedTestResultTimer = Timer(const Duration(seconds: 6), () {
        if (!mounted) return;
        setState(() {
          _speedTestMbps = null;
          _speedTestError = null;
        });
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _speedTestError = error.message ?? 'Speed test failed.');
        _speedTestResultTimer?.cancel();
        _speedTestResultTimer = Timer(const Duration(seconds: 6), () {
          if (!mounted) return;
          setState(() => _speedTestError = null);
        });
      }
    } finally {
      if (mounted) setState(() => _speedTestRunning = false);
    }
  }

  Future<void> setAutoUpdateEnabled(bool enabled) async {
    if (!mounted) return;
    setState(() => _autoUpdateEnabled = enabled);
    await _storage.write(
      key: 'auto_update_enabled_v1',
      value: enabled ? 'true' : 'false',
    );
    if (enabled) unawaited(_checkForAndroidUpdates(automatic: true));
  }

  Future<void> setUpdateUseActiveRoute(bool enabled) async {
    if (!mounted) return;
    setState(() => _updateUseActiveRoute = enabled);
    await _storage.write(
      key: 'update_use_active_route_v1',
      value: enabled ? 'true' : 'false',
    );
  }

  Future<void> setUpdateIncludePrerelease(bool enabled) async {
    if (!mounted) return;
    setState(() => _updateIncludePrerelease = enabled);
    await _storage.write(
      key: 'update_include_prerelease_v1',
      value: enabled ? 'true' : 'false',
    );
  }

  Future<void> _checkForAndroidUpdates({
    bool automatic = false,
    BuildContext? notificationContext,
    bool? includePrerelease,
    ValueChanged<AboutUpdateStatus>? onStatus,
  }) async {
    if (_updateCheckInFlight || (automatic && !_autoUpdateEnabled)) {
      if (!automatic) onStatus?.call(AboutUpdateStatus.error);
      return;
    }
    if (automatic) {
      final last = DateTime.tryParse(
        await _storage.read(key: 'update_last_check_v1') ?? '',
      );
      if (last != null &&
          DateTime.now().difference(last) < const Duration(hours: 24)) {
        return;
      }
    }
    _updateCheckInFlight = true;
    if (!automatic) onStatus?.call(AboutUpdateStatus.checking);
    try {
      final currentVersion = await _androidUpdates.installedVersion();
      if (mounted && currentVersion != _appVersion) {
        setState(() => _appVersion = currentVersion);
      }
      final release = await _androidUpdates.latestAndroidRelease(
        includePrerelease: includePrerelease ?? _updateIncludePrerelease,
        useActiveRoute: _updateUseActiveRoute,
      );
      if (release == null) {
        throw StateError(
          _locale.languageCode == 'fa'
              ? 'در کانال انتخاب‌شده بستهٔ Android سازگار با این گوشی پیدا نشد.'
              : 'No Android package for this device was found in the selected channel.',
        );
      }
      if (automatic) {
        await _storage.write(
          key: 'update_last_check_v1',
          value: DateTime.now().toIso8601String(),
        );
      }
      if (!mounted) return;
      final comparison = _androidUpdates.compareVersions(
        release.version,
        currentVersion,
      );
      if (comparison < 0 && automatic) return;
      final cached = await _androidUpdates.findDownloaded(release.package);
      final partial = cached == null
          ? await _androidUpdates.findPartial(release.package)
          : null;
      if (automatic && comparison <= 0) return;
      if (cached != null || comparison != 0 || partial != null) {
        if (!automatic) onStatus?.call(AboutUpdateStatus.available);
        final context = notificationContext ?? _navigatorKey.currentContext;
        if (context != null && context.mounted) {
          await _showAndroidUpdateAvailable(
            context,
            release,
            currentVersion: currentVersion,
            cached: cached,
            partial: partial,
            isDowngrade: comparison < 0,
            alreadyOnLatest: comparison == 0,
          );
        }
      } else if (!automatic) {
        onStatus?.call(AboutUpdateStatus.upToDate);
      }
    } catch (error) {
      if (!automatic && mounted) {
        onStatus?.call(AboutUpdateStatus.error);
        _showUpdateMessage(notificationContext, error.toString());
      }
    } finally {
      _updateCheckInFlight = false;
    }
  }

  void _showUpdateMessage(BuildContext? preferredContext, String message) {
    final context = preferredContext?.mounted == true
        ? preferredContext!
        : _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          content: SelectableText(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(_locale.languageCode == 'fa' ? 'باشه' : 'OK'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAndroidUpdateAvailable(
    BuildContext context,
    AndroidUpdateRelease release, {
    required String currentVersion,
    File? cached,
    File? partial,
    required bool isDowngrade,
    required bool alreadyOnLatest,
  }) async {
    final isFa = _locale.languageCode == 'fa';
    if (cached != null) {
      final install = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            alreadyOnLatest
                ? (isFa
                      ? 'نسخهٔ ${release.version} از قبل دریافت شده'
                      : 'Build ${release.version} is already downloaded')
                : (isFa
                      ? 'نسخهٔ ${release.version} آمادهٔ نصب است'
                      : 'Connecso ${release.version} is ready to install'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isFa
                    ? 'فایل APK از قبل در دستگاه است و آمادهٔ نصب است.'
                    : 'The APK is already on this device and ready to install.',
              ),
              const SizedBox(height: 10),
              SelectableText(
                cached.path,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(isFa ? 'بعداً' : 'Later'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.install_mobile_rounded),
              label: Text(isFa ? 'نصب نسخه' : 'Install update'),
            ),
          ],
        ),
      );
      if (install == true) await _androidUpdates.install(cached);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          partial != null
              ? (isFa
                    ? 'ادامهٔ دریافت نسخهٔ ${release.version}'
                    : 'Resume download ${release.version}')
              : isDowngrade
              ? (isFa
                    ? 'نسخهٔ پایین‌تر ${release.version} موجود است'
                    : 'Downgrade to ${release.version}?')
              : (isFa
                    ? 'نسخهٔ ${release.version} در دسترس است'
                    : 'Connecso ${release.version} is available'),
        ),
        content: SizedBox(
          width: (MediaQuery.sizeOf(context).width - 88)
              .clamp(260.0, 420.0)
              .toDouble(),
          height: (MediaQuery.sizeOf(context).height * 0.42)
              .clamp(210.0, 300.0)
              .toDouble(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isFa
                    ? 'نسخهٔ فعلی: $currentVersion'
                    : 'Current version: $currentVersion',
              ),
              if (isDowngrade) ...[
                const SizedBox(height: 8),
                Text(
                  isFa
                      ? 'نسخهٔ فعلی شما جدیدتر است؛ دریافت این بسته نسخه را پایین می‌آورد.'
                      : 'Your installed build is newer. Downloading this package will downgrade the app.',
                ),
              ],
              if (partial != null) ...[
                const SizedBox(height: 8),
                Text(
                  isFa
                      ? 'دریافت نیمه‌تمام پیدا شد و از همان‌جا ادامه می‌یابد.'
                      : 'A partial download was found and will resume from where it stopped.',
                ),
              ],
              const SizedBox(height: 10),
              Text(
                isFa ? 'تغییرات این نسخه' : 'What’s new',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: SelectableText(
                      release.changelog.isEmpty
                          ? (isFa
                                ? 'توضیحی برای این انتشار ثبت نشده است.'
                                : 'No release notes were published.')
                          : release.changelog,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      isFa
                          ? 'بسته: Android APK · ${release.package.name}'
                          : 'Package: Android APK · ${release.package.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(_formatAndroidUpdateSize(release.package.sizeBytes)),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(isFa ? 'لغو' : 'Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.download_rounded),
            label: Text(
              partial != null
                  ? (isFa ? 'ادامهٔ دریافت' : 'Resume download')
                  : (isFa ? 'دریافت نسخه' : 'Download update'),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || !context.mounted) return;
    await _downloadAndroidUpdate(context, release);
  }

  Future<void> _downloadAndroidUpdate(
    BuildContext context,
    AndroidUpdateRelease release,
  ) async {
    final isFa = _locale.languageCode == 'fa';
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final progress = ValueNotifier<AndroidUpdateProgress>(
      AndroidUpdateProgress(
        id: id,
        receivedBytes: 0,
        totalBytes: release.package.sizeBytes,
        state: 'downloading',
      ),
    );
    final directory = await _androidUpdates.downloadDirectory;
    if (!context.mounted) return;
    var paused = false;
    var completed = false;
    var closed = false;
    var cancelled = false;
    String? errorText;
    final subscription = _androidUpdates.progress.listen((value) {
      if (value.id == id) progress.value = value;
    });
    final downloadTask = _androidUpdates.startDownload(
      id: id,
      package: release.package,
      useActiveRoute: _updateUseActiveRoute,
    );
    unawaited(
      downloadTask
          .then((result) {
            if (result['status'] == 'completed') completed = true;
            if (result['status'] == 'closed') closed = true;
            if (result['status'] == 'cancelled') cancelled = true;
            progress.value = AndroidUpdateProgress(
              id: id,
              receivedBytes: completed
                  ? release.package.sizeBytes
                  : progress.value.receivedBytes,
              totalBytes: release.package.sizeBytes,
              state: '${result['status'] ?? 'completed'}',
            );
            if (_navigatorKey.currentContext?.mounted == true) {
              // The dialog's ValueListenableBuilder observes completion and updates its actions.
            }
          })
          .catchError((Object error) {
            errorText = error.toString();
            progress.value = AndroidUpdateProgress(
              id: id,
              receivedBytes: progress.value.receivedBytes,
              totalBytes: release.package.sizeBytes,
              state: 'error',
            );
          }),
    );

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ValueListenableBuilder<AndroidUpdateProgress>(
        valueListenable: progress,
        builder: (dialogContext, value, _) {
          completed = value.state == 'completed' || completed;
          closed = value.state == 'closed' || closed;
          cancelled = value.state == 'cancelled' || cancelled;
          final isComplete = value.state == 'completed' || completed;
          return AlertDialog(
            title: Text(
              isComplete
                  ? (isFa ? 'دریافت کامل شد' : 'Download complete')
                  : (isFa
                        ? 'در حال دریافت به‌روزرسانی…'
                        : 'Downloading update…'),
            ),
            content: SizedBox(
              width: (MediaQuery.sizeOf(context).width - 88)
                  .clamp(240.0, 340.0)
                  .toDouble(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: isComplete
                        ? 1
                        : value.totalBytes > 0 && value.receivedBytes > 0
                        ? value.fraction
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    errorText ??
                        '${isComplete ? 100 : (value.fraction * 100).round()}%',
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    '$directory${Platform.pathSeparator}${release.package.name}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: isComplete
                ? [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(isFa ? 'بستن' : 'Close'),
                    ),
                    FilledButton.icon(
                      onPressed: () async {
                        final file = await _androidUpdates.findDownloaded(
                          release.package,
                        );
                        if (file != null && dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                          await _androidUpdates.install(file);
                        }
                      },
                      icon: const Icon(Icons.install_mobile_rounded),
                      label: Text(isFa ? 'نصب به‌روزرسانی' : 'Install update'),
                    ),
                  ]
                : [
                    TextButton(
                      onPressed: () async {
                        await _androidUpdates.controlDownload(id, 'cancel');
                        Navigator.of(dialogContext).pop();
                      },
                      child: Text(isFa ? 'لغو دریافت' : 'Cancel download'),
                    ),
                    TextButton(
                      onPressed: () async {
                        paused = !paused;
                        await _androidUpdates.controlDownload(
                          id,
                          paused ? 'pause' : 'resume',
                        );
                        progress.value = AndroidUpdateProgress(
                          id: id,
                          receivedBytes: value.receivedBytes,
                          totalBytes: value.totalBytes,
                          state: paused ? 'paused' : 'downloading',
                        );
                      },
                      child: Text(
                        paused
                            ? (isFa ? 'ادامه' : 'Resume')
                            : (isFa ? 'مکث' : 'Pause'),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await _androidUpdates.controlDownload(id, 'close');
                        Navigator.of(dialogContext).pop();
                      },
                      child: Text(isFa ? 'بستن پنجره' : 'Close window'),
                    ),
                  ],
          );
        },
      ),
    );
    try {
      await downloadTask;
    } catch (error) {
      errorText ??= error.toString();
    }
    await subscription.cancel();
    progress.dispose();
    if (closed || cancelled) return;
    if (errorText != null && context.mounted) {
      _showUpdateMessage(
        context,
        isFa ? 'دریافت ناموفق بود: $errorText' : 'Download failed: $errorText',
      );
    }
  }

  String _formatAndroidUpdateSize(int bytes) {
    if (bytes <= 0)
      return _locale.languageCode == 'fa' ? 'نامشخص' : 'Size unknown';
    if (bytes >= 1024 * 1024 * 1024)
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _quickTileSyncTimer?.cancel();
    _speedTestResultTimer?.cancel();
    _statsTimer?.cancel();
    _healthTimer?.cancel();
    _updateCheckTimer?.cancel();
    _androidUpdates.dispose();
    _subscriptions.close();
    unawaited(_history.close());
    super.dispose();
  }

  List<Map<String, Object?>> _widgetDestinationEntries() {
    final enabledNodes = _nodes.where((node) => node.enabled).toList();
    final favoriteNodes = enabledNodes.where(_isWidgetFavorite).toList();
    final visibleNodes =
        (favoriteNodes.isNotEmpty ? favoriteNodes : enabledNodes).take(80);
    return visibleNodes.map((node) {
      final location = _locations.resolve(node);
      return <String, Object?>{
        'nodeId': node.id,
        'countryCode': location?.countryCode ?? node.countryCode ?? '',
        'countryName': location?.country ?? node.country ?? node.name,
        'nodeName': node.name,
        'protocol': node.protocol.name.toUpperCase(),
        'config': jsonEncode(
          XrayConfigBuilder(fakeDnsEnabled: _vpn.fakeDnsEnabled).build(node),
        ),
        'mode': _splitPolicy.mode.name,
        'packages': _splitPolicy.packageNames.toList()..sort(),
      };
    }).toList();
  }

  bool _isWidgetFavorite(VpnNode node) {
    final location = _locations.resolve(node);
    final code = LocationResolver.canonicalCountryCode(
      location?.countryCode ?? node.countryCode ?? node.country,
    );
    return _favoriteDestinationKeys.contains('node:${node.id}') ||
        (code.isNotEmpty && _favoriteDestinationKeys.contains(code));
  }

  @override
  Widget build(BuildContext context) {
    final widgetNode = _destinationNode ?? _activeNode;
    final widgetLocation = widgetNode == null
        ? null
        : _locations.resolve(widgetNode);
    final widgetData = <String, Object?>{
      'connected': _phase == ConnectionPhase.connected,
      'connectionFailed': _phase == ConnectionPhase.failed,
      'country': widgetLocation?.country ?? widgetNode?.country ?? '',
      'language': _locale.languageCode,
      'darkTheme':
          _themeMode == ThemeMode.dark ||
          (_themeMode == ThemeMode.system &&
              WidgetsBinding.instance.platformDispatcher.platformBrightness ==
                  Brightness.dark),
      'usedBytes': _quota.usedBytes,
      'totalBytes': _quota.totalBytes,
      'remainingBytes': _quota.remainingBytes,
      'unlimited': _quota.unlimited,
      'quotaAvailable': _quota.usedBytes != null,
      'widgetDestinations': jsonEncode(_widgetDestinationEntries()),
      'widgetHasFavorites': _nodes.any(
        (node) => node.enabled && _isWidgetFavorite(node),
      ),
    };
    final widgetSyncKey = jsonEncode(widgetData);
    if (widgetSyncKey != _lastWidgetSyncKey) {
      _lastWidgetSyncKey = widgetSyncKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_vpn.updateWidgetData(widgetData));
      });
    }
    const navy = Color(0xFF05080C);
    final dark = ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: navy,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xFF00D9F5),
            brightness: Brightness.dark,
          ).copyWith(
            surface: const Color(0xFF0A0F15),
            surfaceContainerHighest: const Color(0xFF101820),
            surfaceContainer: const Color(0xFF0C141B),
            outline: const Color(0xFF126477),
            primary: const Color(0xFF00D9F5),
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
      navigatorKey: _navigatorKey,
      title: 'CONNECSO',
      debugShowCheckedModeBanner: false,
      showPerformanceOverlay: _debugPerformanceOverlay,
      theme: light,
      darkTheme: dark,
      themeMode: _themeMode,
      themeAnimationDuration: _performanceMode
          ? Duration.zero
          : const Duration(milliseconds: 200),
      locale: _locale,
      supportedLocales: const [Locale('en'), Locale('fa')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: _performanceMode),
        child: child ?? const SizedBox.shrink(),
      ),
      home: HomeScreen(
        appVersion: _appVersion,
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
        destination:
            (_phase == ConnectionPhase.connected
                    ? (_activeNode ?? _destinationNode)
                    : (_destinationNode ?? _activeNode)) ==
                null
            ? null
            : _destinationLocationFor(
                _phase == ConnectionPhase.connected
                    ? (_activeNode ?? _destinationNode)
                    : (_destinationNode ?? _activeNode),
              ),
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
        performanceMode: _performanceMode,
        onPerformanceModeChanged: setPerformanceMode,
        onSpeedTest: _runSpeedTest,
        speedTestRunning: _speedTestRunning,
        speedTestMbps: _speedTestMbps,
        speedTestError: _speedTestError,
        onAddQuickSettingsTile: () async {
          try {
            final added = await _vpn.requestAddQuickSettingsTile();
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  added
                      ? (_locale.languageCode == 'fa'
                            ? 'درخواست افزودن کاشی ارسال شد.'
                            : 'Quick Settings tile request sent.')
                      : (_locale.languageCode == 'fa'
                            ? 'این نسخهٔ اندروید افزودن کاشی را پشتیبانی نمی‌کند.'
                            : 'This Android version cannot add a tile from the app.'),
                ),
              ),
            );
          } on PlatformException catch (error) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(error.message ?? 'Unable to add tile.')),
              );
          }
        },
        onAddHomeScreenWidget: () async {
          try {
            final added = await _vpn.requestAddHomeScreenWidget();
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  added
                      ? (_locale.languageCode == 'fa'
                            ? 'درخواست افزودن ویجت ارسال شد.'
                            : 'Widget request sent.')
                      : (_locale.languageCode == 'fa'
                            ? 'لانچر دستگاه افزودن ویجت را پشتیبانی نمی‌کند.'
                            : 'The launcher does not support pinning widgets.'),
                ),
              ),
            );
          } on PlatformException catch (error) {
            if (mounted)
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(error.message ?? 'Unable to add widget.'),
                ),
              );
          }
        },
        refreshingActiveSubscription:
            _activeSubscriptionId != null &&
            _refreshingSubscriptionIds.contains(_activeSubscriptionId),
        canRefreshActiveSubscription:
            _activeSubscriptionId != null &&
            _savedSubscriptions.any(
              (profile) =>
                  profile.id == _activeSubscriptionId &&
                  profile.endpoint?.isNotEmpty == true,
            ) &&
            !const {
              ConnectionPhase.preparing,
              ConnectionPhase.connecting,
              ConnectionPhase.verifying,
              ConnectionPhase.reconnecting,
              ConnectionPhase.disconnecting,
            }.contains(_phase),
        autoUpdateEnabled: _autoUpdateEnabled,
        updateUseActiveRoute: _updateUseActiveRoute,
        updateIncludePrerelease: _updateIncludePrerelease,
        onAutoUpdateChanged: setAutoUpdateEnabled,
        onUpdateRouteChanged: setUpdateUseActiveRoute,
        onUpdatePrereleaseChanged: setUpdateIncludePrerelease,
        onCheckUpdates: (dialogContext, includePrerelease, onStatus) =>
            _checkForAndroidUpdates(
              notificationContext: dialogContext,
              includePrerelease: includePrerelease,
              onStatus: onStatus,
            ),
        onRefreshActiveSubscription: _activeSubscriptionId == null
            ? null
            : () => refreshSavedSubscription(_activeSubscriptionId!),
        destinationSelection: _destinationSelection,
        onDestinationSelectionChanged: _setDestinationSelection,
        onPingDestinations: _pingDestinations,
        onCancelDestinationPings: _cancelDestinationPings,
        favoriteDestinationKeys: _favoriteDestinationKeys,
        recentDestinationCountryCode: _recentDestinationCountryCode,
        onDestinationFavoriteChanged: setDestinationFavorite,
      ),
    );
  }
}
