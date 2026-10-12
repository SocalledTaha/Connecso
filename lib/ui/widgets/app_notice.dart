import 'dart:async';

import 'package:flutter/material.dart';

/// A root-overlay notice that stays above modal sheets and nested routes.
class AppNotice {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(BuildContext context, String message) {
    final overlay = Overlay.of(context, rootOverlay: true);
    _timer?.cancel();
    _entry?.remove();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _AppNoticeBanner(
        message: message,
        onDismiss: () {
          if (identical(_entry, entry)) {
            _entry = null;
            entry.remove();
          }
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(const Duration(milliseconds: 2800), () {
      if (identical(_entry, entry)) {
        _entry = null;
        entry.remove();
      }
    });
  }
}

class _AppNoticeBanner extends StatefulWidget {
  const _AppNoticeBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  State<_AppNoticeBanner> createState() => _AppNoticeBannerState();
}

class _AppNoticeBannerState extends State<_AppNoticeBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 180),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 12,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.35),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: dark ? const Color(0xF20B2B3A) : const Color(0xF9F9FCFD),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: dark
                      ? const Color(0xFF2A5364)
                      : const Color(0xFFC4DCE7),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.32 : 0.12),
                    blurRadius: 18,
                    offset: const Offset(0, 7),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 13,
                ),
                child: Text(
                  widget.message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: dark
                        ? const Color(0xFFF4F7FA)
                        : const Color(0xFF10202B),
                    fontWeight: FontWeight.w600,
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
