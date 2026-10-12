import 'package:flutter/material.dart';

import '../../domain/models/destination_selection.dart';
import '../../domain/models/vpn_node.dart';
import '../../domain/services/location_resolver.dart';

class DestinationCountrySelector extends StatefulWidget {
  const DestinationCountrySelector({
    required this.nodes,
    required this.selection,
    required this.persian,
    required this.onSelected,
    this.dismissSignal,
    this.onDismissed,
    super.key,
  });

  final List<VpnNode> nodes;
  final DestinationSelection selection;
  final bool persian;
  final ValueChanged<DestinationSelection> onSelected;
  final ValueNotifier<int>? dismissSignal;
  final VoidCallback? onDismissed;

  @override
  State<DestinationCountrySelector> createState() =>
      _DestinationCountrySelectorState();
}

class _DestinationCountrySelectorState
    extends State<DestinationCountrySelector> {
  bool _closing = false;
  int _rowCount = 1;

  @override
  void initState() {
    super.initState();
    widget.dismissSignal?.addListener(_handleDismissRequest);
  }

  @override
  void didUpdateWidget(covariant DestinationCountrySelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dismissSignal != widget.dismissSignal) {
      oldWidget.dismissSignal?.removeListener(_handleDismissRequest);
      widget.dismissSignal?.addListener(_handleDismissRequest);
    }
  }

  @override
  void dispose() {
    widget.dismissSignal?.removeListener(_handleDismissRequest);
    super.dispose();
  }

  String _countryCode(VpnNode node) => LocationResolver.canonicalCountryCode(
    '${node.countryCode ?? ''} ${node.country ?? ''} ${node.name}',
  );

  String _name(String code, Iterable<VpnNode> nodes) {
    final raw = nodes.first.country?.trim();
    final country = raw == null || raw.isEmpty ? code : raw;
    const fa = {
      'NL': 'هلند',
      'DE': 'آلمان',
      'GB': 'بریتانیا',
      'FR': 'فرانسه',
      'TR': 'ترکیه',
      'US': 'ایالات متحده',
      'CA': 'کانادا',
      'IT': 'ایتالیا',
      'IR': 'ایران',
    };
    return widget.persian ? (fa[code] ?? country) : country;
  }

  String _flag(String code) => code.length == 2
      ? String.fromCharCodes(code.codeUnits.map((c) => 0x1F1E6 + c - 65))
      : '🌐';

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<VpnNode>>{};
    for (final node in widget.nodes.where((n) => n.enabled)) {
      groups.putIfAbsent(_countryCode(node), () => []).add(node);
    }
    final entries = groups.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    _rowCount = entries.length + 1;
    final rows = <Widget>[];
    rows.add(
      _AnimatedDestinationRow(
        index: 0,
        total: entries.length + 1,
        closing: _closing,
        child: _row(
          context,
          flag: '🌐',
          name: widget.persian ? 'خودکار' : 'Auto',
          detail: widget.persian
              ? 'بهترین سرور موجود'
              : 'Best available server',
          selected: widget.selection.isAuto,
          quality: null,
          onTap: () => _select(const DestinationSelection.auto()),
        ),
      ),
    );
    var index = 1;
    for (final entry in entries) {
      final available = entry.value
          .where((node) => node.health != NodeHealth.unhealthy)
          .toList();
      final ping = available
          .map((node) => node.authoritativeLatency?.inMilliseconds)
          .whereType<int>()
          .where((value) => value > 0)
          .fold<int?>(null, (a, b) => a == null || b < a ? b : a);
      final total = entry.value.fold<int>(
        0,
        (sum, n) => sum + n.successCount + n.failureCount,
      );
      final successes = entry.value.fold<int>(
        0,
        (sum, n) => sum + n.successCount,
      );
      final quality = total == 0 ? 50 : (successes * 100 / total).round();
      final code = entry.key;
      rows.add(
        _AnimatedDestinationRow(
          index: index++,
          total: entries.length + 1,
          closing: _closing,
          child: _row(
            context,
            flag: _flag(code),
            name: _name(code, entry.value),
            detail: ping == null
                ? (widget.persian ? 'در دسترس نیست' : 'Unavailable')
                : '$ping ms  •  $quality%',
            selected: widget.selection.countryCode == code,
            quality: quality,
            onTap: available.isEmpty
                ? null
                : () => _select(DestinationSelection.country(code)),
          ),
        ),
      );
    }

    return Directionality(
      textDirection: widget.persian ? TextDirection.rtl : TextDirection.ltr,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _handleDismissRequest();
        },
        child: SizedBox(
          width: 170,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(mainAxisSize: MainAxisSize.min, children: rows),
          ),
        ),
      ),
    );
  }

  void _select(DestinationSelection value) {
    _beginClose(() => widget.onSelected(value));
  }

  void _handleDismissRequest() {
    _beginClose(widget.onDismissed);
  }

  void _beginClose(VoidCallback? afterClose) {
    if (_closing) return;
    setState(() => _closing = true);
    Future<void>.delayed(Duration(milliseconds: 280 + (_rowCount * 80)), () {
      if (mounted) afterClose?.call();
    });
  }

  Widget _row(
    BuildContext context, {
    required String flag,
    required String name,
    required String detail,
    required bool selected,
    required int? quality,
    required VoidCallback? onTap,
  }) {
    final colors = Theme.of(context).colorScheme;
    final qualityColor = quality == null
        ? colors.onSurfaceVariant
        : quality >= 80
        ? Colors.green
        : quality >= 55
        ? Colors.amber.shade700
        : colors.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? colors.primaryContainer
            : colors.surfaceContainerHighest.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: _closing ? null : onTap,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 48,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(flag, style: const TextStyle(fontSize: 22)),
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
                          style: TextStyle(
                            color: colors.onSurface,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: qualityColor, fontSize: 9),
                        ),
                      ],
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

class _AnimatedDestinationRow extends StatefulWidget {
  const _AnimatedDestinationRow({
    required this.index,
    required this.total,
    required this.closing,
    required this.child,
  });

  final int index;
  final int total;
  final bool closing;
  final Widget child;

  @override
  State<_AnimatedDestinationRow> createState() =>
      _AnimatedDestinationRowState();
}

class _AnimatedDestinationRowState extends State<_AnimatedDestinationRow> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(
      Duration(milliseconds: (widget.total - widget.index - 1) * 70),
      () {
        if (mounted && !widget.closing) setState(() => _visible = true);
      },
    );
  }

  @override
  void didUpdateWidget(covariant _AnimatedDestinationRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.closing && widget.closing) {
      final reverseIndex = widget.index;
      Future<void>.delayed(Duration(milliseconds: reverseIndex * 80), () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: _visible ? Offset.zero : const Offset(0, .045),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: _visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: IgnorePointer(ignoring: !_visible, child: widget.child),
      ),
    );
  }
}
