import 'dart:convert';

class QuotaSnapshot {
  const QuotaSnapshot({
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expiresAt,
    this.neverExpires = false,
    this.unlimited = false,
  });

  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final DateTime? expiresAt;

  /// True when the subscription server explicitly reports `expire=0`.
  /// This differs from missing or malformed expiry metadata.
  final bool neverExpires;

  /// Explicitly reported zero total means the provider has no quota cap.
  final bool unlimited;

  Map<String, Object?> toJson() => {
    'uploadBytes': uploadBytes,
    'downloadBytes': downloadBytes,
    'totalBytes': totalBytes,
    'expiresAt': expiresAt?.toIso8601String(),
    'neverExpires': neverExpires,
    'unlimited': unlimited,
  };

  factory QuotaSnapshot.fromJson(Map<String, Object?> json) => QuotaSnapshot(
    uploadBytes: _readNonNegativeInt(json['uploadBytes']),
    downloadBytes: _readNonNegativeInt(json['downloadBytes']),
    totalBytes: _readNonNegativeInt(json['totalBytes']),
    expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    neverExpires: json['neverExpires'] == true,
    unlimited: json['unlimited'] == true,
  );

  static QuotaSnapshot? decode(String? source) {
    if (source == null) return null;
    try {
      final decoded = jsonDecode(source);
      return decoded is Map<String, Object?>
          ? QuotaSnapshot.fromJson(decoded)
          : null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  int? get usedBytes {
    final upload = uploadBytes;
    final download = downloadBytes;
    if (upload == null ||
        download == null ||
        upload > 0x7fffffffffffffff - download) {
      return null;
    }
    return upload + download;
  }

  int? get remainingBytes {
    final total = totalBytes;
    final used = usedBytes;
    return total == null || used == null
        ? null
        : (total - used).clamp(0, total);
  }

  static QuotaSnapshot unavailable() => const QuotaSnapshot();
}

int? _readNonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

class UsageService {
  const UsageService();

  /// Subscription metadata is deliberately tolerant: absent values stay null
  /// and are shown as "Unavailable", never as zero quota.
  QuotaSnapshot parseHeaders(Map<String, String> headers) {
    final normalized = {
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    final metadata = <String, String>{};
    for (final part in (normalized['subscription-userinfo'] ?? '').split(';')) {
      final separator = part.indexOf('=');
      if (separator > 0) {
        metadata[part.substring(0, separator).trim().toLowerCase()] = part
            .substring(separator + 1)
            .trim();
      }
    }
    final upload = _bytes(
      normalized['upload'] ?? normalized['x-upload'] ?? metadata['upload'],
    );
    final download = _bytes(
      normalized['download'] ??
          normalized['x-download'] ??
          metadata['download'],
    );
    final rawTotal =
        normalized['total'] ?? normalized['x-total'] ?? metadata['total'];
    final total = _bytes(rawTotal);
    final expiryRaw =
        normalized['expire'] ?? normalized['x-expire'] ?? metadata['expire'];
    final expirySeconds = int.tryParse(expiryRaw ?? '');
    return QuotaSnapshot(
      uploadBytes: upload,
      downloadBytes: download,
      totalBytes: total,
      expiresAt: _expiry(expirySeconds),
      neverExpires: expirySeconds == 0,
      unlimited: rawTotal != null && total == 0,
    );
  }

  /// Reads Happ-style metadata from response headers and subscription comments.
  QuotaSnapshot parseSubscriptionMetadata(
    Map<String, String> headers,
    String body,
  ) {
    final normalized = {
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    final bodyValue = _subscriptionDirective(body, 'subscription-userinfo');
    return _merge(
      parseHeaders(normalized),
      parseHeaders({'subscription-userinfo': ?bodyValue}),
    );
  }

  QuotaSnapshot _merge(QuotaSnapshot headers, QuotaSnapshot body) =>
      QuotaSnapshot(
        uploadBytes: headers.uploadBytes ?? body.uploadBytes,
        downloadBytes: headers.downloadBytes ?? body.downloadBytes,
        totalBytes: headers.totalBytes ?? body.totalBytes,
        expiresAt: headers.neverExpires
            ? null
            : headers.expiresAt ?? body.expiresAt,
        neverExpires:
            headers.neverExpires ||
            (headers.expiresAt == null && body.neverExpires),
        unlimited: headers.unlimited || body.unlimited,
      );

  String? _subscriptionDirective(String body, String name) {
    final expression = RegExp(
      r'^\s*#' + name + r'\s*:\s*(.*?)\s*$',
      caseSensitive: false,
      multiLine: true,
    );
    final normalized = body.replaceFirst(RegExp(r'^\uFEFF'), '');
    final directMatch = expression.firstMatch(normalized);
    if (directMatch != null) return directMatch.group(1);
    try {
      final compact = normalized.replaceAll(RegExp(r'\s+'), '');
      final decoded = utf8.decode(
        base64Decode(base64.normalize(compact)),
        allowMalformed: true,
      );
      return expression.firstMatch(decoded)?.group(1);
    } on FormatException {
      return null;
    }
  }

  int? _bytes(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final value = int.tryParse(raw);
    return value != null && value >= 0 ? value : null;
  }

  DateTime? _expiry(int? seconds) {
    if (seconds == null || seconds <= 0 || seconds > 253402300799) {
      // 9999-12-31T23:59:59Z
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  }
}
