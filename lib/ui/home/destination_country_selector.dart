import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models/destination_selection.dart';
import '../../domain/models/connection_method.dart';
import '../../domain/models/vpn_node.dart';
import '../../domain/services/country_lookup.dart';
import '../../domain/services/destination_ping_policy.dart';
import '../../domain/services/location_resolver.dart';
import '../../l10n/app_strings.dart';
import '../widgets/swipe_dismiss_layer.dart';

typedef DestinationPingProgress =
    void Function(String nodeId, Duration? latency);
typedef DestinationPingCallback =
    Future<Map<String, Duration?>> Function(
      List<VpnNode> nodes, {
      DestinationPingProgress? onProgress,
    });

class DestinationCountrySelector extends StatefulWidget {
  const DestinationCountrySelector({
    required this.nodes,
    required this.selection,
    required this.persian,
    required this.onSelected,
    this.favoriteDestinationKeys = const {},
    this.recentCountryCode,
    this.onToggleFavorite,
    this.onPingDestinations,
    this.onCancelDestinationPings,
    super.key,
  });

  final List<VpnNode> nodes;
  final DestinationSelection selection;
  final bool persian;
  final ValueChanged<DestinationSelection> onSelected;
  final Set<String> favoriteDestinationKeys;
  final String? recentCountryCode;
  final Future<void> Function(String, bool)? onToggleFavorite;
  final DestinationPingCallback? onPingDestinations;
  final Future<void> Function()? onCancelDestinationPings;

  @override
  State<DestinationCountrySelector> createState() =>
      _DestinationCountrySelectorState();
}

class _DestinationCountrySelectorState extends State<DestinationCountrySelector>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final TextEditingController _search = TextEditingController();
  final Map<String, Duration?> _latencies = {};
  final Set<String> _pinging = {};
  final Set<String> _pendingPings = {};
  final Set<String> _queuedPingIds = {};
  final List<VpnNode> _manualPingQueue = [];
  bool _manualPingQueueRunning = false;
  int _manualQueueRevision = 0;
  int _activeTabIndex = 0;
  Future<void>? _cancelSweepForManualPing;
  bool _pingingAll = false;
  bool _pingingFavorites = false;
  late Set<String> _favoriteKeys;
  final Set<String> _expandedCountries = {};
  final Set<String> _collapsedRegions = {};
  bool _favoritesExpanded = true;
  bool _recentExpanded = true;
  int _pingRunGeneration = 0;

  @override
  void initState() {
    super.initState();
    _favoriteKeys = {...widget.favoriteDestinationKeys};
    _tabs = TabController(
      length: 2,
      initialIndex: widget.favoriteDestinationKeys.isEmpty ? 1 : 0,
      vsync: this,
    );
    _activeTabIndex = _tabs.index;
    _tabs.addListener(_handleTabChanged);
  }

  void _handleTabChanged() {
    if (_activeTabIndex == _tabs.index || !mounted) return;
    setState(() => _activeTabIndex = _tabs.index);
  }

  @override
  void didUpdateWidget(covariant DestinationCountrySelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameCodes(
      oldWidget.favoriteDestinationKeys,
      widget.favoriteDestinationKeys,
    )) {
      _favoriteKeys = {...widget.favoriteDestinationKeys};
      // Keep the opening tab aligned with the available content. If the user
      // has never favorited a destination, land on All Countries.
      if (_favoriteKeys.isEmpty) {
        _tabs.animateTo(1);
      } else if (oldWidget.favoriteDestinationKeys.isEmpty) {
        _tabs.animateTo(0);
      }
    }
    if (_favoriteKeys.isEmpty && _tabs.index == 0) {
      _tabs.animateTo(1);
    }
  }

  static const _asia = {
    'AF',
    'AM',
    'AZ',
    'BD',
    'BH',
    'BN',
    'BT',
    'CN',
    'CY',
    'GE',
    'HK',
    'ID',
    'IL',
    'IN',
    'IQ',
    'IR',
    'JO',
    'JP',
    'KG',
    'KH',
    'KP',
    'KR',
    'KW',
    'KZ',
    'LA',
    'LB',
    'LK',
    'MM',
    'MN',
    'MO',
    'MV',
    'MY',
    'NP',
    'OM',
    'PH',
    'PK',
    'PS',
    'QA',
    'SA',
    'SG',
    'SY',
    'TH',
    'TJ',
    'TL',
    'TM',
    'TR',
    'TW',
    'UZ',
    'VN',
    'YE',
  };
  static const _europe = {
    'AD',
    'AL',
    'AT',
    'BA',
    'BE',
    'BG',
    'BY',
    'CH',
    'CZ',
    'DE',
    'DK',
    'EE',
    'ES',
    'FI',
    'FR',
    'GB',
    'GR',
    'HR',
    'HU',
    'IE',
    'IS',
    'IT',
    'LI',
    'LT',
    'LU',
    'LV',
    'MC',
    'MD',
    'ME',
    'MK',
    'MT',
    'NL',
    'NO',
    'PL',
    'PT',
    'RO',
    'RS',
    'RU',
    'SE',
    'SI',
    'SK',
    'SM',
    'UA',
    'VA',
    'XK',
  };
  static const _northAmerica = {
    'AG',
    'BS',
    'BB',
    'BZ',
    'CA',
    'CR',
    'CU',
    'DM',
    'DO',
    'GD',
    'GT',
    'HN',
    'HT',
    'JM',
    'KN',
    'LC',
    'MX',
    'NI',
    'PA',
    'SV',
    'TT',
    'US',
    'VC',
  };

  bool get _isFa => widget.persian;
  AppStrings get _strings => AppStrings(Locale(_isFa ? 'fa' : 'en'));

  bool _sameCodes(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  Map<String, List<VpnNode>> get _groups {
    final result = <String, List<VpnNode>>{};
    for (final node in widget.nodes.where((node) => node.enabled)) {
      final code = _countryCode(node);
      if (code.isEmpty) continue;
      result.putIfAbsent(code, () => []).add(node);
    }
    return result;
  }

  String _countryCode(VpnNode node) =>
      LocationResolver.canonicalCountryCode(
        '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
      ).isEmpty
      ? 'UNKNOWN'
      : LocationResolver.canonicalCountryCode(
          '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
        );

  String _favoriteKey(VpnNode node) => 'node:${node.id}';

  bool _isFavoriteNode(VpnNode node, String countryCode) =>
      _favoriteKeys.contains(_favoriteKey(node)) ||
      _favoriteKeys.contains(countryCode);

  String _englishName(String code, List<VpnNode> nodes) {
    if (code == 'UNKNOWN') return _isFa ? 'مقصدهای دیگر' : 'Other destinations';
    for (final country in offlineCountries) {
      if (country.code.toUpperCase() == code) return country.displayName;
    }
    final raw = nodes.firstOrNull?.country?.trim();
    return raw == null || raw.isEmpty ? code : raw;
  }

  String _name(String code, List<VpnNode> nodes) {
    final english = _englishName(code, nodes);
    return _strings.locationName(english, '');
  }

  String _flag(String code) =>
      code.length == 2 ? LocationResolver.flagForCode(code) : '🌐';

  String _region(String code) {
    if (_asia.contains(code)) return _isFa ? 'آسیا' : 'Asia';
    if (_europe.contains(code)) return _isFa ? 'اروپا' : 'Europe';
    if (_northAmerica.contains(code)) {
      return _isFa ? 'آمریکای شمالی' : 'North America';
    }
    return _isFa ? 'سایر مناطق' : 'Other Regions';
  }

  Map<String, List<MapEntry<String, List<VpnNode>>>> _regions(
    List<MapEntry<String, List<VpnNode>>> entries,
  ) {
    const order = ['Asia', 'Europe', 'North America', 'Other Regions'];
    final result = <String, List<MapEntry<String, List<VpnNode>>>>{};
    for (final entry in entries) {
      final region = _region(entry.key);
      result.putIfAbsent(region, () => []).add(entry);
    }
    return {
      for (final region in order.map(
        (key) => _isFa
            ? switch (key) {
                'Asia' => 'آسیا',
                'Europe' => 'اروپا',
                'North America' => 'آمریکای شمالی',
                _ => 'سایر مناطق',
              }
            : key,
      ))
        if (result.containsKey(region)) region: result[region]!,
    };
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final query = _search.text.trim().toLowerCase();
    final allEntries = groups.entries.toList()
      ..sort((a, b) => _name(a.key, a.value).compareTo(_name(b.key, b.value)));
    final favorites = <MapEntry<String, List<VpnNode>>>[];
    for (final entry in groups.entries) {
      final favoritedNodes = entry.value
          .where((node) => _isFavoriteNode(node, entry.key))
          .toList(growable: false);
      if (favoritedNodes.isNotEmpty &&
          _matches(entry.key, favoritedNodes, query)) {
        favorites.add(MapEntry(entry.key, favoritedNodes));
      }
    }
    favorites.sort(
      (a, b) => _name(a.key, a.value).compareTo(_name(b.key, b.value)),
    );
    final recentCode = widget.recentCountryCode?.toUpperCase();
    final recent = recentCode == null || groups[recentCode] == null
        ? <MapEntry<String, List<VpnNode>>>[]
        : [
            MapEntry(recentCode, groups[recentCode]!),
          ].where((entry) => _matches(entry.key, entry.value, query)).toList();
    final filteredAll = allEntries
        .where((entry) => _matches(entry.key, entry.value, query))
        .toList();
    final colors = Theme.of(context).colorScheme;

    return Directionality(
      textDirection: _isFa ? TextDirection.rtl : TextDirection.ltr,
      child: SwipeDismissLayer(
        direction: SwipeCloseDirection.left,
        enabled: _activeTabIndex == 1,
        child: Scaffold(
          appBar: AppBar(
            title: Text(_isFa ? 'مقصدها' : 'Destinations'),
            leading: IconButton(
              tooltip: _isFa ? 'بازگشت' : 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            actions: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 12),
                child: FilledButton.tonalIcon(
                  onPressed:
                      _pingingAll ||
                          _manualPingQueueRunning ||
                          _manualPingQueue.isNotEmpty ||
                          widget.onPingDestinations == null
                      ? null
                      : () => _pingAll(
                          _orderedAllNodes(allEntries, favorites, recent),
                        ),
                  icon: _pingingAll
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering_rounded, size: 18),
                  label: Text(_isFa ? 'پینگ همه' : 'Ping all'),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: _isFa
                          ? 'جستجوی کشور یا سرور'
                          : 'Search country or server',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _search.clear();
                                setState(() {});
                              },
                              icon: const Icon(Icons.close_rounded),
                            ),
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: colors.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: colors.outlineVariant),
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                Material(
                  color: Colors.transparent,
                  child: TabBar(
                    controller: _tabs,
                    labelColor: colors.primary,
                    unselectedLabelColor: colors.onSurfaceVariant,
                    indicatorColor: colors.primary,
                    tabs: [
                      Tab(
                        text: _isFa
                            ? 'علاقه‌مندی‌ها (${favorites.length})'
                            : 'Favorites (${favorites.length})',
                      ),
                      Tab(text: _isFa ? 'همهٔ کشورها' : 'All Countries'),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    physics: const PageScrollPhysics(),
                    children: [
                      _countryList(favorites, forceExpandEntries: true),
                      _allCountries(filteredAll, favorites, recent),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _matches(String code, List<VpnNode> nodes, String query) {
    if (query.isEmpty) return true;
    return _name(code, nodes).toLowerCase().contains(query) ||
        code.toLowerCase().contains(query) ||
        nodes.any((node) => node.name.toLowerCase().contains(query));
  }

  Widget _allCountries(
    List<MapEntry<String, List<VpnNode>>> all,
    List<MapEntry<String, List<VpnNode>>> favorites,
    List<MapEntry<String, List<VpnNode>>> recent,
  ) {
    // Recent is a shortcut section, not a replacement for the country's
    // normal place in the continent list. Keep it visible in both places.
    // Favorites are an extra shortcut section. Keep every country in its
    // continent list as well so starring a destination never hides it.
    final remaining = all;
    final regions = _regions(remaining);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _countryTile(
          code: 'AUTO',
          name: _isFa ? 'خودکار' : 'Auto select',
          nodes: const [],
          selected: widget.selection.isAuto,
          favorite: false,
          onSelect: () => widget.onSelected(const DestinationSelection.auto()),
          showFavorite: false,
        ),
        if (favorites.isNotEmpty) ...[
          const SizedBox(height: 6),
          _collapsibleSectionHeader(
            _isFa ? 'علاقه‌مندی‌ها' : 'Favorites',
            favorites.length,
            Icons.star_rounded,
            expanded: _favoritesExpanded,
            onTap: () =>
                setState(() => _favoritesExpanded = !_favoritesExpanded),
            trailing: _smallPingAllButton(
              favorites.expand((entry) => entry.value).toList(growable: false),
              isFavorites: true,
            ),
          ),
          if (_favoritesExpanded)
            ...favorites.map((entry) => _entryTile(entry)),
        ],
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 6),
          _collapsibleSectionHeader(
            _isFa ? 'اخیر' : 'Recent',
            1,
            Icons.schedule_rounded,
            expanded: _recentExpanded,
            onTap: () => setState(() => _recentExpanded = !_recentExpanded),
          ),
          if (_recentExpanded) _entryTile(recent.single),
        ],
        for (final region in regions.entries) ...[
          const SizedBox(height: 8),
          _collapsibleSectionHeader(
            region.key,
            region.value.length,
            Icons.public_rounded,
            expanded: !_collapsedRegions.contains(region.key),
            onTap: () => setState(() {
              if (!_collapsedRegions.add(region.key)) {
                _collapsedRegions.remove(region.key);
              }
            }),
          ),
          if (!_collapsedRegions.contains(region.key))
            ...region.value.map((entry) => _entryTile(entry)),
        ],
        if (all.isEmpty) _emptyState(),
      ],
    );
  }

  List<VpnNode> _orderedAllNodes(
    List<MapEntry<String, List<VpnNode>>> all,
    List<MapEntry<String, List<VpnNode>>> favorites,
    List<MapEntry<String, List<VpnNode>>> recent,
  ) {
    final seen = <String>{};
    final ordered = <VpnNode>[];
    void addEntries(Iterable<MapEntry<String, List<VpnNode>>> entries) {
      for (final entry in entries) {
        for (final node in entry.value) {
          if (node.enabled && seen.add(node.id)) ordered.add(node);
        }
      }
    }

    addEntries(favorites);
    addEntries(recent);
    for (final region in _regions(all).values) {
      addEntries(region);
    }
    return ordered;
  }

  Widget _countryList(
    List<MapEntry<String, List<VpnNode>>> entries, {
    bool forceExpandEntries = false,
  }) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _countryTile(
          code: 'AUTO',
          name: _isFa ? 'انتخاب خودکار' : 'Auto selector',
          nodes: const [],
          selected: widget.selection.isAuto,
          favorite: false,
          onSelect: () => widget.onSelected(const DestinationSelection.auto()),
          showFavorite: false,
        ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _smallPingAllButton(
              entries.expand((entry) => entry.value).toList(growable: false),
              isFavorites: true,
            ),
          ),
        ),
        ...entries.map(
          (entry) => _entryTile(entry, forceExpand: forceExpandEntries),
        ),
        if (entries.isEmpty) _emptyState(),
      ],
    );
  }

  Widget _entryTile(
    MapEntry<String, List<VpnNode>> entry, {
    bool forceExpand = false,
  }) {
    final code = entry.key;
    final nodes = entry.value;
    return _countryTile(
      code: code,
      name: _name(code, nodes),
      nodes: nodes,
      selected: widget.selection.countryCode == code,
      favorite: nodes.length == 1 && _isFavoriteNode(nodes.single, code),
      onSelect: () => widget.onSelected(DestinationSelection.country(code)),
      forceExpand: forceExpand,
    );
  }

  Widget _sectionHeader(
    String title,
    int count,
    IconData icon, {
    Widget? trailing,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null) ...[trailing, const SizedBox(width: 6)],
          Text(
            '$count',
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _collapsibleSectionHeader(
    String title,
    int count,
    IconData icon, {
    required bool expanded,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsetsDirectional.only(start: 12, end: 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: colors.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '$count',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _countryTile({
    required String code,
    required String name,
    required List<VpnNode> nodes,
    required bool selected,
    required bool favorite,
    required VoidCallback onSelect,
    bool showFavorite = true,
    bool forceExpand = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final actionableSingle = nodes.length == 1 && !forceExpand;
    final pingKey = actionableSingle ? nodes.single.id : code;
    final pinging = actionableSingle
        ? _pendingPings.contains(pingKey) || _pinging.contains(pingKey)
        : nodes.any((node) => _pendingPings.contains(node.id));
    final latency = actionableSingle
        ? _latencies[nodes.single.id]
        : _bestLatency(nodes);
    final enabled = nodes.any((node) => node.enabled);
    final expandable = code != 'AUTO' && (nodes.length > 1 || forceExpand);
    final expanded = _expandedCountries.contains(code) || forceExpand;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Column(
        children: [
          Material(
            color: selected
                ? colors.primaryContainer.withValues(alpha: .72)
                : colors.surface,
            borderRadius: BorderRadius.circular(15),
            child: InkWell(
              onTap: expandable
                  ? () => setState(() {
                      if (expanded) {
                        _expandedCountries.remove(code);
                      } else {
                        _expandedCountries.add(code);
                      }
                    })
                  : (enabled || code == 'AUTO' ? onSelect : null),
              borderRadius: BorderRadius.circular(15),
              child: Container(
                constraints: const BoxConstraints(minHeight: 66),
                padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(
                    color: selected ? colors.primary : colors.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        _flag(code),
                        style: const TextStyle(fontSize: 22),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            code == 'AUTO'
                                ? (_isFa
                                      ? 'انتخاب خودکار بهترین مقصد'
                                      : 'Automatically choose a destination')
                                : '${nodes.length} ${_isFa ? 'سرور' : (nodes.length == 1 ? 'server' : 'servers')}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (code != 'AUTO' && actionableSingle) ...[
                      if (latency != null)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 2),
                          child: Text(
                            '${latency.inMilliseconds} ms',
                            style: TextStyle(
                              color: _pingColor(latency),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      else if (nodes.any(
                        (node) => _latencies.containsKey(node.id),
                      ))
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 2),
                          child: Text(
                            _isFa ? 'نامعتبر' : 'Invalid',
                            style: TextStyle(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.white
                                  : Colors.black87,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: _isFa ? 'پینگ زنده' : 'Live ping',
                        visualDensity: VisualDensity.compact,
                        onPressed: pinging
                            ? null
                            : () => _pingNode(nodes.single),
                        icon: pinging
                            ? const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                Icons.bolt_rounded,
                                color: colors.primary,
                                size: 20,
                              ),
                      ),
                      IconButton(
                        tooltip: favorite
                            ? (_isFa
                                  ? 'حذف از علاقه‌مندی‌ها'
                                  : 'Remove favorite')
                            : (_isFa
                                  ? 'افزودن به علاقه‌مندی‌ها'
                                  : 'Add favorite'),
                        visualDensity: VisualDensity.compact,
                        onPressed:
                            showFavorite && widget.onToggleFavorite != null
                            ? () async {
                                final node = nodes.single;
                                final key = _favoriteKey(node);
                                final next = {..._favoriteKeys};
                                if (favorite) {
                                  next.remove(key);
                                } else {
                                  next.add(key);
                                }
                                setState(() => _favoriteKeys = next);
                                if (next.isEmpty && _tabs.index == 0) {
                                  _tabs.animateTo(1);
                                }
                                try {
                                  await widget.onToggleFavorite!(
                                    key,
                                    !favorite,
                                  );
                                } catch (_) {
                                  if (!mounted) return;
                                  setState(() {
                                    if (favorite) {
                                      _favoriteKeys.add(key);
                                    } else {
                                      _favoriteKeys.remove(key);
                                    }
                                  });
                                }
                              }
                            : null,
                        icon: Icon(
                          favorite
                              ? Icons.star_rounded
                              : Icons.star_border_rounded,
                          color: favorite
                              ? Colors.amber
                              : colors.onSurfaceVariant,
                          size: 21,
                        ),
                      ),
                      if (expandable)
                        Icon(
                          expanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          color: colors.onSurfaceVariant,
                          size: 20,
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (expandable && expanded)
            ...nodes.asMap().entries.map(
              (entry) => _serverRow(code, entry.value, entry.key + 1),
            ),
        ],
      ),
    );
  }

  Widget _serverRow(String countryCode, VpnNode node, int connectionNumber) {
    final colors = Theme.of(context).colorScheme;
    final method = _methodFor(node);
    final protocol = node.protocol.name.toUpperCase();
    final transport = node.transport.trim().toUpperCase();
    final detail =
        method?.label ??
        [
          protocol,
          if (transport.isNotEmpty && transport != 'TCP') transport,
        ].join(' · ');
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 48, top: 3, bottom: 3),
      child: Material(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: node.enabled
              ? () => widget.onSelected(
                  DestinationSelection.country(
                    countryCode,
                    method: method,
                    nodeId: node.id,
                  ),
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isFa
                            ? 'اتصال $connectionNumber'
                            : 'Connection $connectionNumber',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        detail,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_latencies[node.id] != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 7),
                    child: Text(
                      '${_latencies[node.id]!.inMilliseconds} ms',
                      style: TextStyle(
                        color: _pingColor(_latencies[node.id]!),
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  )
                else if (_latencies.containsKey(node.id))
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 7),
                    child: Text(
                      _isFa ? 'نامعتبر' : 'Invalid',
                      style: TextStyle(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black87,
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: _isFa ? 'پینگ همین اتصال' : 'Ping this connection',
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      _pinging.contains(node.id) ||
                          _pendingPings.contains(node.id)
                      ? null
                      : () => _pingNode(node),
                  icon:
                      _pinging.contains(node.id) ||
                          _pendingPings.contains(node.id)
                      ? const SizedBox.square(
                          dimension: 15,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.bolt_rounded, color: colors.primary),
                ),
                IconButton(
                  tooltip: _favoriteKeys.contains(_favoriteKey(node))
                      ? (_isFa ? 'حذف از علاقه‌مندی‌ها' : 'Remove favorite')
                      : (_isFa ? 'افزودن به علاقه‌مندی‌ها' : 'Add favorite'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _toggleNodeFavorite(node),
                  icon: Icon(
                    _favoriteKeys.contains(_favoriteKey(node))
                        ? Icons.star_rounded
                        : Icons.star_border_rounded,
                    color: _favoriteKeys.contains(_favoriteKey(node))
                        ? Colors.amber
                        : colors.onSurfaceVariant,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  ConnectionMethod? _methodFor(VpnNode node) {
    for (final method in ConnectionMethod.values) {
      if (method.matches(node)) return method;
    }
    return null;
  }

  Widget _smallPingAllButton(List<VpnNode> nodes, {required bool isFavorites}) {
    final busy =
        (isFavorites ? _pingingFavorites : _pingingAll) ||
        _manualPingQueueRunning ||
        _manualPingQueue.isNotEmpty;
    return TextButton.icon(
      onPressed: busy || nodes.isEmpty || widget.onPingDestinations == null
          ? null
          : () => isFavorites ? _pingFavorites(nodes) : _pingAll(nodes),
      icon: busy
          ? const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            )
          : const Icon(Icons.bolt_rounded, size: 16),
      label: Text(_isFa ? 'پینگ همه' : 'Ping all'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }

  Future<void> _pingFavorites(List<VpnNode> nodes) async {
    await _pingList(nodes, favorites: true);
  }

  Future<void> _pingNode(VpnNode node) async {
    final key = node.id;
    if (_pinging.contains(key) ||
        _queuedPingIds.contains(key) ||
        widget.onPingDestinations == null) {
      return;
    }
    setState(() {
      _queuedPingIds.add(key);
      _pendingPings.add(key);
      _manualPingQueue.add(node);
      _manualQueueRevision++;
    });

    // Stop a bulk sweep once, then queue direct taps in their original order.
    final existingCancel = _cancelSweepForManualPing;
    if (existingCancel != null) {
      await existingCancel;
    } else if (_pingingAll || _pingingFavorites) {
      final cancel = () async {
        _pingRunGeneration++;
        if (mounted) {
          setState(() {
            _pingingAll = false;
            _pingingFavorites = false;
          });
        }
        await widget.onCancelDestinationPings?.call();
      }();
      _cancelSweepForManualPing = cancel;
      try {
        await cancel;
      } finally {
        if (identical(_cancelSweepForManualPing, cancel)) {
          _cancelSweepForManualPing = null;
        }
      }
    }
    await _drainManualPingQueue();
  }

  Future<void> _drainManualPingQueue() async {
    if (_manualPingQueueRunning) return;
    _manualPingQueueRunning = true;
    try {
      while (mounted && _manualPingQueue.isNotEmpty) {
        // Coalesce tap bursts into one Xray batch while preserving FIFO order.
        var observedRevision = _manualQueueRevision;
        var quietFor = Duration.zero;
        var waited = Duration.zero;
        while (quietFor < const Duration(milliseconds: 220) &&
            waited < const Duration(milliseconds: 700)) {
          await Future<void>.delayed(const Duration(milliseconds: 70));
          waited += const Duration(milliseconds: 70);
          if (!mounted) break;
          if (_manualQueueRevision != observedRevision) {
            observedRevision = _manualQueueRevision;
            quietFor = Duration.zero;
          } else {
            quietFor += const Duration(milliseconds: 70);
          }
        }
        if (!mounted || widget.onPingDestinations == null) break;
        final count = _manualPingQueue.length.clamp(0, 20);
        final batch = _manualPingQueue.take(count).toList(growable: false);
        _manualPingQueue.removeRange(0, count);
        final keys = batch.map((node) => node.id).toList(growable: false);
        final generation = _pingRunGeneration;
        setState(() {
          _pinging.addAll(keys);
          for (final key in keys) {
            _latencies.remove(key);
            _pendingPings.add(key);
          }
        });
        try {
          final results = await widget.onPingDestinations!(
            batch,
            onProgress: (nodeId, latency) {
              _applyPingResult(nodeId, latency, generation);
            },
          );
          if (mounted && generation == _pingRunGeneration) {
            setState(() {
              for (final key in keys) {
                _latencies[key] = results[key];
                _pendingPings.remove(key);
              }
            });
          }
        } catch (error) {
          _showPingError(error);
        } finally {
          if (mounted) {
            setState(() {
              _pinging.removeAll(keys);
              _queuedPingIds.removeAll(keys);
              _pendingPings.removeAll(keys);
            });
          }
        }
      }
    } finally {
      _manualPingQueueRunning = false;
      if (mounted && _manualPingQueue.isNotEmpty) {
        unawaited(_drainManualPingQueue());
      }
    }
  }

  Future<void> _toggleNodeFavorite(VpnNode node) async {
    final callback = widget.onToggleFavorite;
    if (callback == null) return;
    final key = _favoriteKey(node);
    final favorite = _favoriteKeys.contains(key);
    setState(() {
      if (favorite) {
        _favoriteKeys.remove(key);
      } else {
        _favoriteKeys.add(key);
      }
    });
    if (_favoriteKeys.isEmpty && _tabs.index == 0) _tabs.animateTo(1);
    try {
      await callback(key, !favorite);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        if (favorite) {
          _favoriteKeys.add(key);
        } else {
          _favoriteKeys.remove(key);
        }
      });
      _showPingError(error);
    }
  }

  void _showPingError(Object error) {
    if (!mounted) return;
    final message = _isFa
        ? 'این عملیات انجام نشد؛ دوباره تلاش کنید.'
        : 'The operation failed. Please try again.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Color _pingColor(Duration latency) {
    final ms = latency.inMilliseconds;
    if (ms < 200) return const Color(0xFF00A85A);
    if (ms < 400) return const Color(0xFFE5A000);
    return const Color(0xFFD83A45);
  }

  Duration? _bestLatency(List<VpnNode> nodes) {
    final values =
        nodes
            // Do not display persisted/cold values as a live RTT.
            .map((node) => _latencies[node.id])
            .whereType<Duration>()
            .where((value) => value.inMilliseconds > 0)
            .toList()
          ..sort((a, b) => a.compareTo(b));
    return values.firstOrNull;
  }

  Future<void> _pingAll(List<VpnNode> nodes) async {
    await _pingList(nodes, favorites: false);
  }

  Future<void> _pingList(List<VpnNode> nodes, {required bool favorites}) async {
    final callback = widget.onPingDestinations;
    if (callback == null ||
        _manualPingQueueRunning ||
        _manualPingQueue.isNotEmpty ||
        (favorites ? _pingingFavorites : _pingingAll)) {
      return;
    }
    final uniqueNodes = <String, VpnNode>{
      for (final node in nodes)
        if (node.enabled) node.id: node,
    }.values.toList(growable: false);
    if (uniqueNodes.isEmpty) return;
    final generation = ++_pingRunGeneration;
    setState(() {
      if (favorites) {
        _pingingFavorites = true;
      } else {
        _pingingAll = true;
      }
      for (final node in uniqueNodes) {
        _latencies.remove(node.id);
        _pendingPings.add(node.id);
      }
    });
    try {
      for (
        var start = 0;
        start < uniqueNodes.length;
        start += destinationPingBatchSize
      ) {
        if (!mounted || generation != _pingRunGeneration) break;
        final batch = uniqueNodes
            .skip(start)
            .take(destinationPingBatchSize)
            .toList(growable: false);
        final results = await callback(
          batch,
          onProgress: (nodeId, latency) =>
              _applyPingResult(nodeId, latency, generation),
        );
        if (!mounted || generation != _pingRunGeneration) break;
        setState(() {
          for (final node in batch) {
            final measured = results[node.id];
            _latencies[node.id] = measured;
            _pendingPings.remove(node.id);
          }
        });
      }
      if (!favorites && generation == _pingRunGeneration) {
        setState(() {
          _favoritesExpanded = true;
          _recentExpanded = true;
          _collapsedRegions.clear();
          _expandedCountries.addAll(
            uniqueNodes.map((node) => _countryCode(node)),
          );
        });
      }
    } catch (error) {
      _showPingError(error);
    } finally {
      if (mounted) {
        setState(() {
          if (favorites) {
            _pingingFavorites = false;
          } else {
            _pingingAll = false;
          }
          for (final node in uniqueNodes) {
            if (_pendingPings.contains(node.id)) {
              _latencies[node.id] = null;
            }
            _pendingPings.remove(node.id);
          }
        });
      }
    }
  }

  void _applyPingResult(String nodeId, Duration? latency, int generation) {
    if (!mounted || generation != _pingRunGeneration) return;
    setState(() {
      // A per-node completion is authoritative for this run, including an
      // explicit failure. Never show the previous run's stale RTT as live.
      _latencies[nodeId] = latency;
      _pendingPings.remove(nodeId);
    });
  }

  Widget _emptyState() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        _isFa ? 'مقصدی پیدا نشد.' : 'No destinations found.',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}
