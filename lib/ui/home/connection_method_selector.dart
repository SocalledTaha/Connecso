import 'package:flutter/material.dart';
import '../../domain/models/connection_method.dart';

/// Independent floating pills, with the same staggered motion as countries.
class ConnectionMethodSelector extends StatefulWidget {
  const ConnectionMethodSelector({
    super.key,
    required this.methods,
    required this.selected,
    required this.dismissSignal,
    required this.onSelected,
    required this.onDismissed,
    required this.persian,
  });
  final List<ConnectionMethod> methods;
  final ConnectionMethod? selected;
  final ValueNotifier<int> dismissSignal;
  final ValueChanged<ConnectionMethod?> onSelected;
  final bool persian;
  final VoidCallback onDismissed;

  @override
  State<ConnectionMethodSelector> createState() =>
      _ConnectionMethodSelectorState();
}

class _ConnectionMethodSelectorState extends State<ConnectionMethodSelector> {
  final Set<int> _visible = {};
  bool _closing = false;
  ConnectionMethod? _selected;
  List<ConnectionMethod?> get _options => [null, ...widget.methods];

  @override
  void initState() {
    super.initState();
    _selected = widget.selected;
    widget.dismissSignal.addListener(_dismiss);
    for (var i = 0; i < _options.length; i++) {
      final index = i;
      Future<void>.delayed(
        Duration(milliseconds: (_options.length - i - 1) * 70),
        () {
          if (mounted && !_closing) setState(() => _visible.add(index));
        },
      );
    }
  }

  void _dismiss() => _close(null);

  Future<void> _close(ConnectionMethod? method, {bool chosen = false}) async {
    if (_closing) return;
    setState(() {
      _closing = true;
      if (chosen) _selected = method;
    });
    if (chosen) {
      await Future<void>.delayed(const Duration(milliseconds: 140));
    }
    for (var i = 0; i < _options.length; i++) {
      if (!mounted) return;
      setState(() => _visible.remove(i));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    if (!chosen) {
      widget.onDismissed();
    } else {
      widget.onSelected(method);
    }
  }

  @override
  void dispose() {
    widget.dismissSignal.removeListener(_dismiss);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _dismiss();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _options.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AnimatedSlide(
                offset: _visible.contains(i)
                    ? Offset.zero
                    : const Offset(0, .08),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: AnimatedOpacity(
                  opacity: _visible.contains(i) ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: AnimatedScale(
                    scale: _closing && _selected == _options[i] ? 1.025 : 1,
                    duration: const Duration(milliseconds: 140),
                    child: IgnorePointer(
                      ignoring: _closing || !_visible.contains(i),
                      child: Material(
                        color: _selected == _options[i]
                            ? colors.primaryContainer
                            : colors.surfaceContainerHighest.withValues(
                                alpha: .94,
                              ),
                        borderRadius: BorderRadius.circular(18),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => _close(_options[i], chosen: true),
                          child: SizedBox(
                            width: 170,
                            height: 48,
                            child: Row(
                              children: [
                                const SizedBox(width: 16),
                                Icon(
                                  Icons.route_rounded,
                                  color: colors.primary,
                                  size: 22,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  _options[i]?.label ??
                                      (widget.persian ? 'خودکار' : 'Automatic'),
                                  style: TextStyle(
                                    color: colors.onSurface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
