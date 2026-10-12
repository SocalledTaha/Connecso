typedef BeginUsageSession = Future<int> Function(DateTime startedAt);

typedef UpdateUsageSession = Future<void> Function({
  required int id,
  required int uploadBytes,
  required int downloadBytes,
  DateTime? endedAt,
});

/// Serializes asynchronous usage-session creation, counter writes, and closure.
///
/// In particular, an end queued immediately after a begin waits for the row to
/// be created, so it cannot be lost to an unset session ID.
class UsageSessionLifecycle {
  UsageSessionLifecycle({
    required BeginUsageSession beginSession,
    required UpdateUsageSession updateSession,
  }) : _beginSession = beginSession,
       _updateSession = updateSession;

  final BeginUsageSession _beginSession;
  final UpdateUsageSession _updateSession;

  Future<void> _pending = Future<void>.value();
  int? _sessionId;
  int _uploadBytes = 0;
  int _downloadBytes = 0;

  Future<void> begin(DateTime startedAt) => _enqueue(() async {
    final previousId = _sessionId;
    if (previousId != null) {
      await _updateSession(
        id: previousId,
        uploadBytes: _uploadBytes,
        downloadBytes: _downloadBytes,
        endedAt: startedAt,
      );
    }
    final id = await _beginSession(startedAt);
    _sessionId = id;
    _uploadBytes = 0;
    _downloadBytes = 0;
  });

  Future<void> persist({
    required int uploadBytes,
    required int downloadBytes,
  }) => _write(uploadBytes: uploadBytes, downloadBytes: downloadBytes);

  Future<void> end({
    required int uploadBytes,
    required int downloadBytes,
    required DateTime endedAt,
  }) => _write(
    uploadBytes: uploadBytes,
    downloadBytes: downloadBytes,
    endedAt: endedAt,
  );

  Future<void> _write({
    required int uploadBytes,
    required int downloadBytes,
    DateTime? endedAt,
  }) => _enqueue(() async {
    final id = _sessionId;
    if (id == null) return;
    await _updateSession(
      id: id,
      uploadBytes: uploadBytes,
      downloadBytes: downloadBytes,
      endedAt: endedAt,
    );
    if (endedAt == null) {
      _uploadBytes = uploadBytes;
      _downloadBytes = downloadBytes;
    } else {
      _sessionId = null;
      _uploadBytes = 0;
      _downloadBytes = 0;
    }
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _pending.then((_) => operation());
    // Keep the queue usable after an individual storage failure, while
    // returning the original error to the caller for logging.
    _pending = result.catchError((Object _) {});
    return result;
  }
}
