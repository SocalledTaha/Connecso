import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/services/usage_service.dart';

class SavedSubscription {
  const SavedSubscription({
    required this.id,
    required this.name,
    this.endpoint,
    this.quota = const QuotaSnapshot(),
    this.nameCustomized = false,
    this.pinned = false,
    this.serverName,
    this.accountEmail,
    this.supportUrl,
    this.profileUrl,
    this.announcement,
    this.autoRefreshEnabled = true,
    this.refreshIntervalHours,
  });

  final String id;
  final String name;
  final String? endpoint;
  final QuotaSnapshot quota;
  final bool nameCustomized;
  final bool pinned;
  final String? serverName;
  final String? accountEmail;
  final String? supportUrl;
  final String? profileUrl;
  final String? announcement;
  final bool autoRefreshEnabled;
  final int? refreshIntervalHours;

  SavedSubscription copyWith({
    String? name,
    String? endpoint,
    QuotaSnapshot? quota,
    bool? nameCustomized,
    bool? pinned,
    String? serverName,
    String? accountEmail,
    String? supportUrl,
    String? profileUrl,
    String? announcement,
    bool? autoRefreshEnabled,
    int? refreshIntervalHours,
  }) => SavedSubscription(
    id: id,
    name: name ?? this.name,
    endpoint: endpoint ?? this.endpoint,
    quota: quota ?? this.quota,
    nameCustomized: nameCustomized ?? this.nameCustomized,
    pinned: pinned ?? this.pinned,
    serverName: serverName ?? this.serverName,
    accountEmail: accountEmail ?? this.accountEmail,
    supportUrl: supportUrl ?? this.supportUrl,
    profileUrl: profileUrl ?? this.profileUrl,
    announcement: announcement ?? this.announcement,
    autoRefreshEnabled: autoRefreshEnabled ?? this.autoRefreshEnabled,
    refreshIntervalHours: refreshIntervalHours ?? this.refreshIntervalHours,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'endpoint': endpoint,
    'quota': quota.toJson(),
    'nameCustomized': nameCustomized,
    'pinned': pinned,
    'serverName': serverName,
    'accountEmail': accountEmail,
    'supportUrl': supportUrl,
    'profileUrl': profileUrl,
    'announcement': announcement,
    'autoRefreshEnabled': autoRefreshEnabled,
    'refreshIntervalHours': refreshIntervalHours,
  };

  factory SavedSubscription.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty) {
      throw const FormatException('Saved subscription metadata is invalid.');
    }
    final quotaJson = json['quota'];
    return SavedSubscription(
      id: id,
      name: name.trim(),
      endpoint: json['endpoint'] as String?,
      quota: quotaJson is Map
          ? QuotaSnapshot.fromJson(Map<String, Object?>.from(quotaJson))
          : QuotaSnapshot.unavailable(),
      nameCustomized: json['nameCustomized'] as bool? ?? false,
      pinned: json['pinned'] as bool? ?? false,
      serverName: _optionalText(json['serverName']),
      accountEmail: _optionalText(json['accountEmail']),
      supportUrl: _optionalText(json['supportUrl']),
      profileUrl: _optionalText(json['profileUrl']),
      announcement: _optionalText(json['announcement']),
      autoRefreshEnabled: json['autoRefreshEnabled'] as bool? ?? true,
      refreshIntervalHours: (json['refreshIntervalHours'] as num?)?.round(),
    );
  }

  static String? _optionalText(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  String get displayName {
    final base = nameCustomized ? name : (serverName ?? name);
    final email = accountEmail;
    if (email == null || email.isEmpty || base.contains(email)) return base;
    final account = email.contains('@') ? email.split('@').first : email;
    return '$base - $account';
  }

  int effectiveRefreshIntervalHours({required bool active}) =>
      refreshIntervalHours ?? (active ? 6 : 12);
}

class SavedSubscriptionsStore {
  SavedSubscriptionsStore(this._storage);

  static const _key = 'saved_subscriptions_v1';
  static const _backupKey = 'saved_subscriptions_backup_v1';
  final FlutterSecureStorage _storage;
  Future<void> _writeQueue = Future<void>.value();

  Future<List<SavedSubscription>> read() async {
    final encoded = await _storage.read(key: _key);
    if (encoded != null) {
      final decoded = _decode(encoded);
      if (decoded != null) return decoded;
    }
    final backup = await _storage.read(key: _backupKey);
    return _decode(backup) ?? const [];
  }

  List<SavedSubscription>? _decode(String? encoded) {
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) return null;
      final subscriptions = <SavedSubscription>[];
      final ids = <String>{};
      for (final row in decoded.whereType<Map>()) {
        try {
          final item = SavedSubscription.fromJson(
            Map<String, Object?>.from(row),
          );
          if (ids.add(item.id)) subscriptions.add(item);
        } on FormatException {
          // A single damaged row must not hide other saved subscriptions.
        } on TypeError {
          // Ignore only malformed metadata rows.
        }
      }
      return subscriptions;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> write(List<SavedSubscription> subscriptions) {
    final operation = _writeQueue.then((_) => _write(subscriptions));
    _writeQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _write(List<SavedSubscription> subscriptions) async {
    final ids = <String>{};
    for (final subscription in subscriptions) {
      if (!ids.add(subscription.id)) {
        throw ArgumentError('Saved subscription IDs must be unique.');
      }
    }
    final previous = await _storage.read(key: _key);
    if (previous != null && _decode(previous) != null) {
      await _storage.write(key: _backupKey, value: previous);
    }
    await _storage.write(
      key: _key,
      value: jsonEncode(subscriptions.map((item) => item.toJson()).toList()),
    );
  }
}
