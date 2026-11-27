import 'dart:ui' as ui;

import 'package:flutter/material.dart';

enum SwipeCloseDirection { left, right }

/// Lets a pushed page track a dismiss swipe, blur slightly, then reveal the
/// route beneath using the navigator's matching reverse transition.
class SwipeDismissLayer extends StatefulWidget {
  const SwipeDismissLayer({
    required this.child,
    required this.direction,
    this.enabled = true,
    this.dismissStartHeight,
    super.key,
  });

  final Widget child;
  final SwipeCloseDirection direction;
  final bool enabled;
  final double? dismissStartHeight;

  @override
  State<SwipeDismissLayer> createState() => _SwipeDismissLayerState();
}

class _SwipeDismissLayerState extends State<SwipeDismissLayer> {
  double _dragX = 0;
  bool _accepted = false;
  int? _pointer;
  Offset? _startPosition;
  DateTime? _startedAt;

  void _resetDrag() {
    _pointer = null;
    _startPosition = null;
    _startedAt = null;
    _dragX = 0;
    _accepted = false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) {
      if (_pointer != null) return;
      final width = MediaQuery.sizeOf(context).width;
      final withinDismissHeader =
          widget.dismissStartHeight == null ||
          event.localPosition.dy <= widget.dismissStartHeight!;
      _accepted =
          widget.enabled &&
          event.localPosition.dx > 32 &&
          event.localPosition.dx < width - 32 &&
          withinDismissHeader;
      if (!_accepted) return;
      _pointer = event.pointer;
      _startPosition = event.localPosition;
      _startedAt = DateTime.now();
      _dragX = 0;
    },
    onPointerMove: (event) {
      if (!_accepted || event.pointer != _pointer) return;
      final start = _startPosition;
      if (start == null) return;
      final deltaX = event.localPosition.dx - start.dx;
      final deltaY = event.localPosition.dy - start.dy;
      final validDirection = widget.direction == SwipeCloseDirection.right
          ? deltaX > 0
          : deltaX < 0;
      if (validDirection && deltaX.abs() > deltaY.abs()) {
        setState(() => _dragX = deltaX);
      }
    },
    onPointerUp: (event) {
      if (!_accepted || event.pointer != _pointer) {
        _resetDrag();
        return;
      }
      final distance = _dragX;
      final elapsed = DateTime.now().difference(_startedAt ?? DateTime.now());
      final velocity = elapsed.inMilliseconds == 0
          ? 0.0
          : distance.abs() * 1000 / elapsed.inMilliseconds;
      final validDirection = widget.direction == SwipeCloseDirection.right
          ? distance > 0
          : distance < 0;
      final shouldClose =
          validDirection && (distance.abs() > 72 || velocity > 300);
      setState(_resetDrag);
      if (shouldClose) Navigator.of(context).maybePop();
    },
    onPointerCancel: (_) {
      if (_accepted) setState(_resetDrag);
    },
    child: ClipRect(
      child: ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: (_dragX.abs() / 20).clamp(0, 5),
          sigmaY: (_dragX.abs() / 20).clamp(0, 5),
        ),
        child: Transform.translate(
          offset: Offset(_dragX * .22, 0),
          child: widget.child,
        ),
      ),
    ),
  );
}
