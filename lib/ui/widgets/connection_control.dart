import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../../domain/models/connection_state.dart';
import '../../domain/services/connect_trace.dart';

class ConnectionControl extends StatefulWidget {
  const ConnectionControl({
    required this.phase,
    required this.label,
    required this.actionLabel,
    required this.onPressed,
    super.key,
  });

  final ConnectionPhase phase;
  final String label;
  final String actionLabel;
  final VoidCallback? onPressed;

  @override
  State<ConnectionControl> createState() => _ConnectionControlState();
}

class _ConnectionControlState extends State<ConnectionControl>
    with TickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  late final AnimationController _connectedRing = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  bool get _isBusy => {
    ConnectionPhase.preparing,
    ConnectionPhase.connecting,
    ConnectionPhase.verifying,
    ConnectionPhase.reconnecting,
    ConnectionPhase.disconnecting,
  }.contains(widget.phase);

  @override
  void initState() {
    super.initState();
    _connectedRing.value = widget.phase == ConnectionPhase.connected ? 1 : 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ConnectionControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (_isBusy && !reduced) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation
        ..stop()
        ..value = 0;
    }
    if (reduced) {
      _connectedRing.value = widget.phase == ConnectionPhase.connected ? 1 : 0;
    } else if (widget.phase == ConnectionPhase.connected) {
      _connectedRing.forward();
    } else {
      _connectedRing.reverse();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    _connectedRing.dispose();
    super.dispose();
  }

  void _handleTap() {
    final callback = widget.onPressed;
    if (callback == null) return;
    developer.log(
      'connect_button_pressed phase=${widget.phase.name}',
      name: 'CONNECSO_CONNECT_TRACE',
    );
    ConnectTrace.emit('connect_button_pressed phase=${widget.phase.name}');
    callback();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connected = widget.phase == ConnectionPhase.connected;
    final failed = widget.phase == ConnectionPhase.failed;
    final accent = connected
        ? const Color(0xFF31D393)
        : failed
        ? const Color(0xFFEF6C71)
        : colors.primary;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: accent),
      duration: const Duration(milliseconds: 260),
      builder: (context, animatedAccent, _) => Semantics(
        button: true,
        label: widget.label,
        hint: widget.actionLabel,
        enabled: widget.onPressed != null,
        child: GestureDetector(
          onTap: _handleTap,
          child: ExcludeSemantics(
            child: SizedBox(
              width: 126,
              height: 126,
              child: RepaintBoundary(
                child: RepaintBoundary(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      RotationTransition(
                        turns:
                            _isBusy && !MediaQuery.disableAnimationsOf(context)
                            ? _rotation
                            : const AlwaysStoppedAnimation<double>(0),
                        child: CustomPaint(
                          painter: _RingPainter(
                            color: animatedAccent ?? accent,
                            connectedProgress: _connectedRing,
                            busy:
                                _isBusy &&
                                !MediaQuery.disableAnimationsOf(context),
                            repaint: _connectedRing,
                          ),
                        ),
                      ),
                      Center(
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 260),
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF0B1E2C),
                            boxShadow: [
                              BoxShadow(
                                color: (animatedAccent ?? accent).withValues(
                                  alpha: connected ? .14 : .10,
                                ),
                                blurRadius: 32,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.power_settings_new_rounded,
                            size: 38,
                            color: Colors.white,
                          ),
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
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.color,
    required this.busy,
    required this.connectedProgress,
    super.repaint,
  });
  final Color color;
  final bool busy;
  final Animation<double> connectedProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(
      center: center,
      radius: size.shortestSide * .47,
    );
    canvas.drawCircle(
      center,
      size.shortestSide * .47,
      Paint()
        ..color = color.withValues(alpha: .10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
    if (busy) {
      canvas.drawArc(
        rect,
        -1.10,
        1.85,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    } else if (connectedProgress.value > 0) {
      final connectedPaint = Paint()
        ..color = color.withValues(alpha: .9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round;
      if (connectedProgress.value >= 1) {
        canvas.drawCircle(center, size.shortestSide * .47, connectedPaint);
      } else {
        canvas.drawArc(
          rect,
          -1.35,
          2.7 + (2 * 3.141592653589793 - 2.7) * connectedProgress.value,
          false,
          connectedPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.busy != busy ||
      oldDelegate.connectedProgress != connectedProgress;
}
