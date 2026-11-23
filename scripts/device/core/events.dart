// The verification app's events as the mock stores them. The app (example/lib/verify_main.dart) retries an
// event the mock did not answer in time, and the first attempt can still have been stored, so the same
// event can arrive twice: every event carries `rid` (the app isolate) and `seq` (its order).

/// [events] without repeats: the first copy of each `rid:seq` stays, in order. An event without both
/// fields (an older app, a hand-posted one) is kept as it is.
List<Map<String, Object?>> dropRepeatedEvents(
  Iterable<Map<String, Object?>> events,
) {
  final seen = <String>{};
  final out = <Map<String, Object?>>[];
  for (final e in events) {
    final data = e['data'] is Map ? (e['data'] as Map) : e;
    final rid = data['rid'];
    final seq = data['seq'];
    if (rid is String && seq is int && !seen.add('$rid:$seq')) continue;
    out.add(e);
  }
  return out;
}

/// Whether [event] (already decoded) belongs to the launch that was given [token]: a launch event of an
/// earlier process of the same install, replayed by the mock or by a late retry, carries another token (or
/// none) and must not satisfy this launch's wait.
bool eventHasToken(Map<String, Object?> event, String token) {
  final data = event['data'] is Map ? (event['data'] as Map) : event;
  return data['token'] == token;
}
