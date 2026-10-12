import 'package:sqflite/sqflite.dart' as sqflite;

/// Asynchronous local history store. Secrets and full node configurations stay
/// in encrypted secure storage; this database contains operational metadata.
class AppDatabase {
  AppDatabase({sqflite.DatabaseFactory? factory, String? path})
    : _factory = factory,
      _path = path;

  static const schemaVersion = 5;
  static const databaseName = 'connecso_history.db';

  final sqflite.DatabaseFactory? _factory;
  final String? _path;
  Future<sqflite.Database>? _opening;

  Future<sqflite.Database> get database =>
      _opening ??= _open().catchError((Object error) {
        _opening = null;
        throw error;
      });

  Future<sqflite.Database> _open() async {
    final factory = _factory ?? sqflite.databaseFactory;
    final path = _path ?? '${await factory.getDatabasesPath()}/$databaseName';
    return factory.openDatabase(
      path,
      options: sqflite.OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) => _createThrough(db, version),
        onUpgrade: (db, oldVersion, newVersion) =>
            _upgrade(db, oldVersion, newVersion),
      ),
    );
  }

  Future<void> _createThrough(sqflite.DatabaseExecutor db, int version) async {
    for (var next = 1; next <= version; next++) {
      await _migration(next, db);
    }
  }

  Future<void> _upgrade(
    sqflite.Database db,
    int oldVersion,
    int newVersion,
  ) async {
    for (var next = oldVersion + 1; next <= newVersion; next++) {
      await _migration(next, db);
    }
  }

  Future<void> _migration(int version, sqflite.DatabaseExecutor db) async {
    switch (version) {
      case 1:
        await db.execute('''
          CREATE TABLE connection_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id TEXT NOT NULL,
            protocol TEXT NOT NULL,
            core TEXT NOT NULL,
            outcome TEXT NOT NULL CHECK (outcome IN ('connected', 'failed')),
            duration_ms INTEGER,
            occurred_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX connection_history_occurred_at '
          'ON connection_history(occurred_at DESC)',
        );
        break;
      case 2:
        await db.execute('''
          CREATE TABLE probe_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id TEXT NOT NULL,
            protocol TEXT NOT NULL,
            reachable INTEGER NOT NULL CHECK (reachable IN (0, 1)),
            latency_ms INTEGER,
            failure_category TEXT,
            checked_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX probe_history_node_checked '
          'ON probe_history(node_id, checked_at DESC)',
        );
        break;
      case 3:
        await db.execute('''
          CREATE TABLE usage_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
            download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
            source TEXT NOT NULL CHECK (source IN ('native', 'unavailable'))
          )
        ''');
        break;
      case 4:
        await db.execute('''
          CREATE TABLE core_performance (
            core TEXT NOT NULL,
            protocol TEXT NOT NULL,
            success_count INTEGER NOT NULL DEFAULT 0 CHECK (success_count >= 0),
            failure_count INTEGER NOT NULL DEFAULT 0 CHECK (failure_count >= 0),
            total_connect_ms INTEGER NOT NULL DEFAULT 0 CHECK (total_connect_ms >= 0),
            updated_at TEXT NOT NULL,
            PRIMARY KEY (core, protocol)
          )
        ''');
        break;
      case 5:
        await db.execute('DROP TABLE IF EXISTS core_performance');
        break;
      default:
        throw ArgumentError.value(version, 'version', 'Unknown DB migration.');
    }
  }

  Future<void> recordConnection({
    required String nodeId,
    required String protocol,
    required String core,
    required bool connected,
    required DateTime occurredAt,
    Duration? duration,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert('connection_history', {
        'node_id': nodeId,
        'protocol': protocol,
        'core': core,
        'outcome': connected ? 'connected' : 'failed',
        'duration_ms': duration?.inMilliseconds,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
      });
    });
  }

  Future<void> recordProbe({
    required String nodeId,
    required String protocol,
    required bool reachable,
    required DateTime checkedAt,
    Duration? latency,
    String? failureCategory,
  }) async {
    final db = await database;
    await db.insert('probe_history', {
      'node_id': nodeId,
      'protocol': protocol,
      'reachable': reachable ? 1 : 0,
      'latency_ms': latency?.inMilliseconds,
      'failure_category': failureCategory,
      'checked_at': checkedAt.toUtc().toIso8601String(),
    });
  }

  Future<int> beginUsageSession(DateTime startedAt) async {
    final db = await database;
    return db.insert('usage_sessions', {
      'started_at': startedAt.toUtc().toIso8601String(),
      'source': 'unavailable',
    });
  }

  Future<void> updateUsageSession({
    required int id,
    required int uploadBytes,
    required int downloadBytes,
    bool sourceAvailable = true,
    DateTime? endedAt,
  }) async {
    if (uploadBytes < 0 || downloadBytes < 0) {
      throw ArgumentError('Usage counters cannot be negative.');
    }
    final db = await database;
    final updated = await db.update(
      'usage_sessions',
      {
        'upload_bytes': uploadBytes,
        'download_bytes': downloadBytes,
        'source': sourceAvailable ? 'native' : 'unavailable',
        'ended_at': endedAt?.toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    if (updated != 1) throw StateError('Usage session does not exist.');
  }

  Future<List<Map<String, Object?>>> recentConnections({
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 1000) {
      throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 1000.');
    }
    final db = await database;
    return db.query(
      'connection_history',
      orderBy: 'occurred_at DESC, id DESC',
      limit: limit,
    );
  }

  Future<void> close() async {
    final opening = _opening;
    if (opening == null) return;
    try {
      final db = await opening;
      await db.close();
    } finally {
      _opening = null;
    }
  }
}
