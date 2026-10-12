import 'dart:io';

import 'package:connecso_client/data/database/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late AppDatabase store;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('connecso-db-');
    store = AppDatabase(
      factory: databaseFactoryFfi,
      path: '${directory.path}${Platform.pathSeparator}test.db',
    );
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('creates every migrated table and records connection history', () async {
    await store.recordConnection(
      nodeId: 'node-a',
      protocol: 'vless',
      core: 'xray',
      connected: true,
      occurredAt: DateTime.utc(2026, 9, 30),
      duration: const Duration(milliseconds: 850),
    );

    final rows = await store.recentConnections();
    expect(rows, hasLength(1));
    expect(rows.single['node_id'], 'node-a');
    expect(rows.single['duration_ms'], 850);
    final db = await store.database;
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    expect(
      tables.map((row) => row['name']),
      containsAll(['connection_history', 'probe_history', 'usage_sessions']),
    );
  });

  test(
    'records probe and usage session updates without negative counters',
    () async {
      await store.recordProbe(
        nodeId: 'node-b',
        protocol: 'trojan',
        reachable: true,
        checkedAt: DateTime.utc(2026, 9, 30),
        latency: const Duration(milliseconds: 24),
      );
      final sessionId = await store.beginUsageSession(
        DateTime.utc(2026, 9, 30),
      );
      await store.updateUsageSession(
        id: sessionId,
        uploadBytes: 10,
        downloadBytes: 20,
        endedAt: DateTime.utc(2026, 9, 30, 0, 1),
      );
      await expectLater(
        store.updateUsageSession(
          id: sessionId,
          uploadBytes: -1,
          downloadBytes: 0,
        ),
        throwsArgumentError,
      );

      final db = await store.database;
      expect(await db.query('probe_history'), hasLength(1));
      final usage = await db.query('usage_sessions');
      expect(usage.single['upload_bytes'], 10);
      expect(usage.single['download_bytes'], 20);
      expect(usage.single['source'], 'native');
    },
  );

  test('applies schema upgrades sequentially from an older database', () async {
    final path = '${directory.path}${Platform.pathSeparator}legacy.db';
    final legacy = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
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
        },
      ),
    );
    await legacy.close();

    final migrated = AppDatabase(factory: databaseFactoryFfi, path: path);
    final db = await migrated.database;
    expect(await db.getVersion(), AppDatabase.schemaVersion);
    expect(await db.query('probe_history'), isEmpty);
    await migrated.close();
  });

  test(
    'drops obsolete runtime comparison data while preserving node history',
    () async {
      final path =
          '${directory.path}${Platform.pathSeparator}runtime-history.db';
      final legacy = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE connection_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              node_id TEXT NOT NULL,
              protocol TEXT NOT NULL,
              core TEXT NOT NULL,
              outcome TEXT NOT NULL,
              duration_ms INTEGER,
              occurred_at TEXT NOT NULL
            )
          ''');
            await db.execute('''
            CREATE TABLE core_performance (
              core TEXT NOT NULL,
              protocol TEXT NOT NULL,
              success_count INTEGER NOT NULL,
              failure_count INTEGER NOT NULL,
              total_connect_ms INTEGER NOT NULL,
              updated_at TEXT NOT NULL,
              PRIMARY KEY (core, protocol)
            )
          ''');
            await db.insert('connection_history', {
              'node_id': 'node-a',
              'protocol': 'vless',
              'core': 'xray',
              'outcome': 'connected',
              'occurred_at': DateTime.utc(2026, 9, 30).toIso8601String(),
            });
          },
        ),
      );
      await legacy.close();

      final migrated = AppDatabase(factory: databaseFactoryFfi, path: path);
      final db = await migrated.database;
      expect(await db.getVersion(), AppDatabase.schemaVersion);
      expect(await db.query('connection_history'), hasLength(1));
      final obsoleteTable = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'core_performance'",
      );
      expect(obsoleteTable, isEmpty);
      await migrated.close();
    },
  );
}
