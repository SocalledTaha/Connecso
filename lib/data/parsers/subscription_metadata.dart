import 'dart:convert';

/// Reads the optional display name used by Happ compatible subscription feeds.
/// HTTP headers take precedence over body comments.
String? parseSubscriptionProfileTitle(
  Map<String, String> headers,
  String body,
) {
  final normalized = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  final headerTitle = _cleanTitle(normalized['profile-title']);
  if (headerTitle != null) return headerTitle;

  final match = RegExp(
    r'(?:^|\r?\n)\s*#profile-title\s*:\s*([^\r\n]*)',
    caseSensitive: false,
  ).firstMatch(body.replaceFirst(RegExp(r'^\uFEFF'), ''));
  return _cleanTitle(match?.group(1));
}

String? parseSubscriptionSupportUrl(Map<String, String> headers, String body) =>
    _parseMetadataValue(
      headers,
      body,
      headerKeys: const ['support-url', 'profile-support-url', 'support'],
      bodyKeys: const ['support-url', 'profile-support-url', 'support'],
      validator: _cleanUrl,
    );

String? parseSubscriptionProfileUrl(Map<String, String> headers, String body) =>
    _parseMetadataValue(
      headers,
      body,
      headerKeys: const [
        'profile-web-page-url',
        'profile-url',
        'profile-website',
        'website',
      ],
      bodyKeys: const [
        'profile-web-page-url',
        'profile-url',
        'profile-website',
        'website',
      ],
      validator: _cleanUrl,
    );

String? parseSubscriptionAnnouncement(
  Map<String, String> headers,
  String body,
) => _parseMetadataValue(
  headers,
  body,
  headerKeys: const ['announce', 'announcement', 'profile-announce'],
  bodyKeys: const ['announce', 'announcement', 'profile-announce'],
  validator: _cleanAnnouncement,
);

String? _parseMetadataValue(
  Map<String, String> headers,
  String body, {
  required List<String> headerKeys,
  required List<String> bodyKeys,
  required String? Function(String?) validator,
}) {
  final normalized = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  for (final key in headerKeys) {
    final value = validator(normalized[key]);
    if (value != null) return value;
  }
  final source = body.replaceFirst(RegExp(r'^\uFEFF'), '');
  for (final key in bodyKeys) {
    final match = RegExp(
      '^\\s*#?${RegExp.escape(key)}\\s*[:=]\\s*([^\\r\\n]*)',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(source);
    final value = validator(match?.group(1));
    if (value != null) return value;
  }
  return null;
}

String? _cleanUrl(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  if (value.startsWith('base64:')) {
    try {
      value = utf8.decode(
        base64.decode(base64.normalize(value.substring('base64:'.length))),
        allowMalformed: false,
      );
    } on FormatException {
      return null;
    }
  }
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  return uri.toString();
}

String? _cleanAnnouncement(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  if (value.startsWith('base64:')) {
    try {
      value = utf8.decode(
        base64.decode(base64.normalize(value.substring('base64:'.length))),
        allowMalformed: false,
      );
    } on FormatException {
      return null;
    }
  }
  value = value.trim();
  if (value.isEmpty || value.runes.length > 500) return null;
  if (value.runes.any((rune) => rune < 0x20 && rune != 0x09)) return null;
  return value;
}

/// Reads an account identity only from explicit provider metadata fields.
/// Server remarks and node names are deliberately not treated as account names.
String? parseSubscriptionAccountEmail(
  Map<String, String> headers,
  String body, {
  Uri? endpoint,
}) {
  final normalized = {
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };
  final headerEmail = _cleanAccountName(
    normalized['subscription-email'] ??
        normalized['x-subscription-email'] ??
        normalized['x-user-email'] ??
        normalized['profile-email'] ??
        normalized['x-email'] ??
        normalized['email'],
  );
  if (headerEmail != null) return headerEmail;

  if (endpoint != null) {
    for (final key in const [
      'email',
      'account_email',
      'account-email',
      'username',
      'user',
    ]) {
      final queryEmail = _cleanAccountName(endpoint.queryParameters[key]);
      if (queryEmail != null) return queryEmail;
    }
  }

  for (final candidate in _textCandidates(body)) {
    final structured = _accountNameFromJson(candidate);
    if (structured != null) return structured;
    final match = RegExp(
      r'(?:^|\r?\n)\s*#?\s*(?:subscription[-_ ]?)?email\s*[:=]\s*([^\r\n]*)',
      caseSensitive: false,
    ).firstMatch(candidate.replaceFirst(RegExp(r'^\uFEFF'), ''));
    final account = _cleanAccountName(match?.group(1));
    if (account != null) return account;
  }
  return null;
}

/// Some providers append the account label to every node name, for example
/// `45ypi555yyuvurjo - Hamin`. Use that label only as a fallback when the
/// provider did not expose an explicit account field.
String? parseSubscriptionAccountFromNodeNames(Iterable<String> names) {
  for (final name in names) {
    final match = RegExp(
      r'^\s*[A-Za-z0-9_-]{8,}\s*[-–—]\s*([A-Za-z][^|]{1,79}?)\s*$',
    ).firstMatch(name.trim());
    final account = _cleanAccountName(match?.group(1));
    if (account != null) return account;
  }
  return null;
}

/// Some feeds put the account label before the first proxy line, such as
/// `45ypi555yyuvurjo - Hamin` followed by vless links.
String? parseSubscriptionAccountFromPreamble(String body) {
  for (final candidate in _textCandidates(body)) {
    final lines = candidate
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final trimmed = line.trim();
      if (RegExp(
        r'^(?:vless|vmess|trojan|ss)://',
        caseSensitive: false,
      ).hasMatch(trimmed)) {
        break;
      }
      final match = RegExp(
        r'^\s*[A-Za-z0-9_-]{8,}\s*[-–—]\s*([A-Za-z][^|]{1,79}?)\s*$',
      ).firstMatch(trimmed);
      final account = _cleanAccountName(match?.group(1));
      if (account != null) return account;
    }
  }
  return null;
}

String? _accountNameFromJson(String source) {
  try {
    final decoded = jsonDecode(source);
    return _findAccountName(decoded);
  } on FormatException {
    return null;
  }
}

String? _findAccountName(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is String &&
          const {
            'email',
            'subscription-email',
            'subscription_email',
            'account-email',
            'account_email',
            'profile-email',
            'profile_email',
          }.contains((entry.key as String).toLowerCase())) {
        final account = _cleanAccountName(entry.value?.toString());
        if (account != null) return account;
      }
    }
    for (final nested in value.values) {
      final account = _findAccountName(nested);
      if (account != null) return account;
    }
  } else if (value is List) {
    for (final nested in value) {
      final account = _findAccountName(nested);
      if (account != null) return account;
    }
  }
  return null;
}

Iterable<String> _textCandidates(String body) sync* {
  yield body;
  final compact = body.trim().replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty || !RegExp(r'^[A-Za-z0-9_+/=-]+$').hasMatch(compact)) {
    return;
  }
  try {
    final decoded = utf8.decode(
      base64.decode(base64.normalize(compact)),
      allowMalformed: false,
    );
    if (decoded.contains('://') ||
        decoded.trimLeft().startsWith('{') ||
        decoded.trimLeft().startsWith('[') ||
        RegExp(
          r'(?:^|\r?\n)\s*#?\s*(?:subscription[-_ ]?)?email\s*[:=]',
          caseSensitive: false,
        ).hasMatch(decoded)) {
      yield decoded;
    }
  } on FormatException {
    // The response body is not a base64-encoded metadata document.
  }
}

String? _cleanAccountName(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    value = value.substring(1, value.length - 1).trim();
  }
  if (value.startsWith('base64:')) {
    try {
      value = utf8.decode(
        base64.decode(base64.normalize(value.substring('base64:'.length))),
        allowMalformed: false,
      );
    } on FormatException {
      return null;
    }
  } else if (!value.contains('@') &&
      RegExp(r'^[A-Za-z0-9_+/=-]{8,}$').hasMatch(value)) {
    try {
      final decoded = utf8.decode(
        base64.decode(base64.normalize(value)),
        allowMalformed: false,
      );
      if (decoded.runes.every((rune) => rune >= 0x20 && rune != 0x7f)) {
        value = decoded;
      }
    } on FormatException {
      // Keep an ordinary account label that merely resembles base64.
    }
  }
  value = value.trim();
  if (value.isEmpty ||
      value.runes.length > 80 ||
      value.runes.any((rune) => rune < 0x20 || rune == 0x7f) ||
      value.contains('://') ||
      value.contains('#')) {
    return null;
  }
  return value;
}

String? _cleanTitle(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  if (value.startsWith('base64:')) {
    try {
      value = utf8.decode(
        base64.decode(base64.normalize(value.substring('base64:'.length))),
        allowMalformed: false,
      );
    } on FormatException {
      return null;
    }
  }
  value = value.trim();
  if (value.isEmpty || value.runes.length > 25) return null;
  if (value.runes.any((rune) => rune < 0x20 || rune == 0x7f)) return null;
  return value;
}
