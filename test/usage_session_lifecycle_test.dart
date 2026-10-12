import 'dart:async';

import 'package:connecso_client/domain/services/usage_session_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'end waits for an in-flight begin and closes even with no stats',
    () async {
      final beginGate = Completer<int>();
      final writes =
          <({int id, int upload, int download, DateTime? endedAt})>[];
      var beginStarted = false;
      final lifecycle = UsageSessionLifecycle(
        beginSession: (_) async {
          beginStarted = true;
          return beginGate.future;
        },
        updateSession:
            ({
              required id,
              required uploadBytes,
              required downloadBytes,
              endedAt,
            }) async {
              writes.add((
                id: id,
                upload: uploadBytes,
                download: downloadBytes,
                endedAt: endedAt,
              ));
            },
      );

      final begin = lifecycle.begin(DateTime.utc(2026, 1, 1));
      await Future<void>.delayed(Duration.zero);
      expect(beginStarted, isTrue);
      final endedAt = DateTime.utc(2026, 1, 1, 0, 1);
      final end = lifecycle.end(
        uploadBytes: 0,
        downloadBytes: 0,
        endedAt: endedAt,
      );

      expect(writes, isEmpty);
      beginGate.complete(17);
      await Future.wait([begin, end]);

      expect(writes, [(id: 17, upload: 0, download: 0, endedAt: endedAt)]);
    },
  );

  test(
    'counter writes serialize before end and closed session ignores writes',
    () async {
      final writes = <({int upload, int download, DateTime? endedAt})>[];
      final lifecycle = UsageSessionLifecycle(
        beginSession: (_) async => 5,
        updateSession:
            ({
              required id,
              required uploadBytes,
              required downloadBytes,
              endedAt,
            }) async {
              expect(id, 5);
              writes.add((
                upload: uploadBytes,
                download: downloadBytes,
                endedAt: endedAt,
              ));
            },
      );

      await lifecycle.begin(DateTime.utc(2026, 1, 1));
      final persist = lifecycle.persist(uploadBytes: 12, downloadBytes: 34);
      final endedAt = DateTime.utc(2026, 1, 1, 0, 2);
      final end = lifecycle.end(
        uploadBytes: 20,
        downloadBytes: 50,
        endedAt: endedAt,
      );
      await Future.wait([persist, end]);
      await lifecycle.persist(uploadBytes: 99, downloadBytes: 99);

      expect(writes, [
        (upload: 12, download: 34, endedAt: null),
        (upload: 20, download: 50, endedAt: endedAt),
      ]);
    },
  );
}
