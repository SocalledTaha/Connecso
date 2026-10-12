import 'dart:async';

import 'package:flutter/services.dart';

/// Temporary release-safe bridge for connection timing diagnostics.
class ConnectTrace {
  ConnectTrace._();

  static const _channel = MethodChannel('com.connecso.client/vpn');

  static void emit(String message) {
    unawaited(
      _channel.invokeMethod<void>('traceLog', message).catchError((_) {}),
    );
  }
}
