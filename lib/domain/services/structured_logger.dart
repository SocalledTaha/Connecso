import 'dart:convert';
import 'dart:developer' as developer;

enum LogCategory {
  application,
  subscription,
  probe,
  routing,
  vpn,
  xray,
  recovery,
  platform,
}

enum LogSeverity {
  debug(500),
  info(800),
  warning(900),
  error(1000);

  const LogSeverity(this.developerLevel);
  final int developerLevel;
}

typedef StructuredLogSink = void Function({
  required String name,
  required String message,
  required int level,
});

/// Emits structured events from an allowlist so raw errors and credentials
/// cannot accidentally enter device logs.
class StructuredLogger {
  StructuredLogger({StructuredLogSink? sink}) : _sink = sink ?? _developerSink;

  final StructuredLogSink _sink;

  static const _allowedFields = {
    'attempt',
    'attemptCount',
    'core',
    'count',
    'durationMs',
    'failureType',
    'outcome',
    'protocol',
    'statusCode',
  };
  static final _identifier = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');
  static final _eventName = RegExp(r'^[a-z][a-z0-9_.]{0,63}$');

  void record({
    required LogCategory category,
    required LogSeverity severity,
    required String event,
    Map<String, Object?> fields = const {},
  }) {
    if (!_eventName.hasMatch(event)) return;
    final safeFields = <String, Object?>{};
    for (final entry in fields.entries) {
      if (!_allowedFields.contains(entry.key)) continue;
      final value = entry.value;
      if (value is String && _identifier.hasMatch(value)) {
        safeFields[entry.key] = value;
      } else if (value is num || value is bool) {
        safeFields[entry.key] = value;
      }
    }
    _sink(
      name: 'connecso.${category.name}',
      message: jsonEncode({'event': event, 'fields': safeFields}),
      level: severity.developerLevel,
    );
  }

  static void _developerSink({
    required String name,
    required String message,
    required int level,
  }) {
    developer.log(message, name: name, level: level);
  }
}
