// Output the capture must not record: the plugin's own diagnostics, what a log filter prints, what
// the framework prints while it forwards a captured `debugPrint`. A zone value, so it follows the
// asynchronous continuations of whatever runs inside (a throttled `debugPrint` prints from a timer;
// a filter may `await`). Internal.
import 'dart:async';

const Symbol _key = #bugsee_flutter.suppressLogCapture;

/// Whether [zone] (default: the current one) is inside [runSuppressed].
bool logCaptureSuppressed([Zone? zone]) => (zone ?? Zone.current)[_key] == true;

/// Runs [body] in a zone where the log capture records nothing. Nothing is swallowed: output goes
/// where it would have gone.
R runSuppressed<R>(R Function() body) {
  final zone = Zone.current;
  if (logCaptureSuppressed(zone)) return body();
  return zone.fork(zoneValues: <Object?, Object?>{_key: true}).run(body);
}
