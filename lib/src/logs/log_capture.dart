// Installs the capture, keeps the policy current, owns the pipeline. Internal; the `Bugsee` facade
// is a thin layer over it (through `BugseeRuntime`).
import 'dart:async';

import 'package:flutter/foundation.dart'
    show
        DebugPrintCallback,
        FlutterError,
        FlutterErrorDetails,
        FlutterExceptionHandler,
        debugPrint,
        debugPrintSynchronously;

import '../errors.dart';
import '../options/bugsee_options.g.dart' show LogLevel;
import '../network/network_event.dart' show monotonicMicros;
import '../status.dart';
import 'log_event.dart';
import 'log_pipeline.dart';
import 'log_policy.dart';
import 'log_suppress.dart';

/// The tags a captured line carries on Android (`log.json` `tag`; iOS has no tag).
abstract final class LogTags {
  static const print = 'print';
  static const debugPrint = 'debugPrint';
}

/// What the plugin prints about itself starts with this. It is never recorded: a diagnostic that
/// reached the pipeline it is about could meet the same failing filter again (the wrapper-channel
/// spec's "at most once" rule).
const String ownOutputPrefix = 'bugsee_flutter: ';

/// Whether [text] is the framework's own error presentation (`FlutterError.dumpErrorToConsole`
/// prints the error's diagnostics tree, widget trees and all, as ONE `debugPrint`, headed
/// `══╡ EXCEPTION CAUGHT BY ... ╞═══`; a second error prints `Another exception was thrown: ...`).
/// Never recorded: the error itself is Phase 5a's business, and the tree is the part of a log most
/// likely to hold what the app shows its user.
bool looksLikeFlutterErrorDump(String text) {
  final head = text.trimLeft();
  return head.startsWith('══╡') ||
      head.startsWith('════════ Exception caught') ||
      head.startsWith('Another exception was thrown: ');
}

final class LogCaptureService {
  LogCaptureService({
    required LogSend send,
    required Future<LogPolicy> Function() loadPolicy,
    required void Function() ensureAttached,
    required Stream<BugseeStatus> Function() statuses,
    required bool Function() supported,
    bool Function()? echoRisk,
    void Function(String message)? warn,
    LogPipeline Function(LogSend send, LogPolicy Function() policy)?
    pipelineFactory,
  }) : _loadPolicy = loadPolicy,
       _ensureAttached = ensureAttached,
       _statuses = statuses,
       _supported = supported,
       _echoRisk = echoRisk ?? (() => false),
       _warn = warn ?? ((_) {}) {
    pipeline =
        (pipelineFactory ??
        (send, policy) => LogPipeline(send: send, policy: policy, warn: _warn))(
          send,
          () => _policy,
        );
  }

  final Future<LogPolicy> Function() _loadPolicy;
  final void Function() _ensureAttached;
  final Stream<BugseeStatus> Function() _statuses;
  final bool Function() _supported;
  final bool Function() _echoRisk;
  final void Function(String) _warn;

  late final LogPipeline pipeline;

  LogPolicy _policy = LogPolicy.off;
  bool _active = false;
  LogLevel _level = LogLevel.info;
  DebugPrintCallback? _previousDebugPrint;
  DebugPrintCallback? _ourDebugPrint;
  StreamSubscription<BugseeStatus>? _statusSubscription;
  int _generation = 0;
  bool _warnedUnsupported = false;
  bool _inPrint = false;
  bool _warnedEcho = false;
  FlutterExceptionHandler? _previousPresentError;
  FlutterExceptionHandler? _ourPresentError;
  FlutterExceptionHandler? _previousOnError;
  FlutterExceptionHandler? _ourOnError;

  /// `debugPrint` messages the capture just recorded, with when they stop counting: Flutter's
  /// throttle prints them later, in pieces, from a timer that may belong to a zone created before the
  /// install (it then prints outside the suppressed zone). Those pieces are the same lines, not new ones.
  final List<(String, int)> _echoes = <(String, int)>[];
  static const int _echoWindowMicros = 3 * 1000 * 1000;
  static const int _maxEchoes = 64;

  /// The policy in force (for tests and diagnostics).
  LogPolicy get policy => _policy;

  /// Whether the capture is installed and active.
  bool get installed => _active;

  /// Installs the capture: `debugPrint` is chained (the previous callback is still called with the
  /// same arguments), and the print hook of [zoneSpecification] starts recording. Idempotent.
  /// Returns whether it is in effect.
  bool install({LogLevel level = LogLevel.info}) {
    if (!_supported()) {
      if (!_warnedUnsupported) {
        _warnedUnsupported = true;
        _warn(
          'Bugsee log capture runs on Android and iOS only; nothing was installed',
        );
      }
      return false;
    }
    _level = level;
    final wasActive = _active;
    if (wasActive && identical(debugPrint, _ourDebugPrint)) {
      _chainErrorPresentation();
      return true;
    }
    // A repeat after the app replaced `debugPrint` without chaining puts the hook back in front of
    // the app's; one it wrapped keeps ours in its chain (and a line is recorded once: the forward
    // runs in a zone the capture ignores).
    if (!identical(debugPrint, _ourDebugPrint)) {
      final previous = debugPrint;
      _previousDebugPrint = previous;
      // One closure per install, each holding the callback it chains to: a hook the app wrapped
      // and that is installed again in front must never reach itself through `_previousDebugPrint`.
      void hook(String? message, {int? wrapWidth}) =>
          _debugPrintHook(previous, message, wrapWidth);
      _ourDebugPrint = hook;
      debugPrint = hook;
    }
    _active = true;
    _chainErrorPresentation();
    // A repeat install changes nothing about what the SDK accepts: it drops nothing.
    if (wasActive) return true;
    // A first install believes nothing until the SDK's status and options are read.
    _policy = _policy.notAccepting();
    _statusSubscription ??= _statuses().listen((status) {
      if (status != BugseeStatus.launched && status != BugseeStatus.launching) {
        _policy = _policy.notAccepting();
      }
      unawaited(refreshPolicy());
    }, onError: (Object _) {});
    _ensureAttached();
    unawaited(refreshPolicy());
    _maybeWarnEcho();
    return true;
  }

  /// `FlutterError.presentError` (and `onError` while it is still the framework's default, which is
  /// `dumpErrorToConsole` itself) are chained so that everything they print, however the app's
  /// `debugPrint` splits or throttles it, runs in a zone the capture ignores: the error's diagnostics
  /// tree never reaches the log, not even piece by piece. The previous handler is always called.
  void _chainErrorPresentation() {
    if (!identical(FlutterError.presentError, _ourPresentError)) {
      final previous = FlutterError.presentError;
      _previousPresentError = previous;
      void hook(FlutterErrorDetails details) =>
          _active ? runSuppressed(() => previous(details)) : previous(details);
      _ourPresentError = hook;
      FlutterError.presentError = hook;
    }
    final onError = FlutterError.onError;
    if (onError != null &&
        !identical(onError, _ourOnError) &&
        identical(onError, FlutterError.dumpErrorToConsole)) {
      _previousOnError = onError;
      void hook(FlutterErrorDetails details) =>
          _active ? runSuppressed(() => onError(details)) : onError(details);
      _ourOnError = hook;
      FlutterError.onError = hook;
    }
  }

  /// The Dart filter does not see what the SDK's own console capture records (Android logcat).
  void _maybeWarnEcho() {
    if (_warnedEcho || !_active || pipeline.filter == null) return;
    if (!_echoRisk() || !_policy.accepting) return;
    _warnedEcho = true;
    _warn(
      'a log filter is set, but on Android the SDK also records what is printed from logcat '
      '(source LogCat, tag flutter), and that route does not pass through it. To redact there too, '
      'set a native log filter that drops or redacts LogSource.LogCat events tagged "flutter" '
      '(Bugsee.setLogEventFilter, see doc/logs.md).',
    );
  }

  /// Stops capturing. Puts the previous `debugPrint` back when ours is still the current one; if
  /// the app wrapped it since, ours stays in that chain and forwards without recording. Lines
  /// already queued (already through the filter's turn) are still handed to the SDK.
  void uninstall() {
    _active = false;
    _generation++;
    final ours = _ourDebugPrint;
    if (ours != null && identical(debugPrint, ours)) {
      debugPrint = _previousDebugPrint ?? debugPrintSynchronously;
    }
    _previousDebugPrint = null;
    _ourDebugPrint = null;
    final ourPresent = _ourPresentError;
    if (ourPresent != null &&
        identical(FlutterError.presentError, ourPresent)) {
      FlutterError.presentError =
          _previousPresentError ?? FlutterError.dumpErrorToConsole;
    }
    final ourOnError = _ourOnError;
    if (ourOnError != null && identical(FlutterError.onError, ourOnError)) {
      FlutterError.onError = _previousOnError;
    }
    _previousPresentError = _ourPresentError = null;
    _previousOnError = _ourOnError = null;
    _echoes.clear();
    final sub = _statusSubscription;
    _statusSubscription = null;
    if (sub != null) unawaited(sub.cancel());
  }

  /// Reads the SDK's status and options again. A newer call supersedes an older one still in
  /// flight; a failure to read leaves nothing accepted (fail closed).
  Future<void> refreshPolicy() async {
    if (!_active) return;
    final generation = ++_generation;
    LogPolicy next;
    try {
      next = await _loadPolicy();
    } catch (_) {
      next = _policy.notAccepting();
    }
    if (generation == _generation && _active) {
      _policy = next;
      _maybeWarnEcho();
    }
  }

  /// Accepts nothing until the next [refreshPolicy] has read the SDK (a stop was asked for).
  void holdUntilRead() => _policy = _policy.notAccepting();

  void setFilter(BugseeLogFilter? filter, Duration timeout) {
    if (timeout <= Duration.zero || timeout > LogWire.maxFilterTimeout) {
      throw const BugseeArgumentException(
        'timeout',
        'the filter timeout must be positive and at most 5 minutes',
      );
    }
    pipeline.setFilter(filter, timeout);
    if (filter != null) _maybeWarnEcho();
  }

  /// Before a report is made (an upload, an error report, a created report, the dialog): hands what
  /// was printed so far to the SDK, so the report holds the lines that led to it. Waits at most
  /// [flushLimit]; never throws; does nothing when the capture is not installed or not accepting.
  Future<void> flushBeforeReport() async {
    if (!_active || !_policy.accepting) return;
    try {
      await pipeline.flush().timeout(flushLimit);
    } catch (_) {
      // A slow filter or native side must not hold a report back.
    }
  }

  /// How long a report waits for the pending lines.
  static const Duration flushLimit = Duration(milliseconds: 200);

  // ---- The hooks ---------------------------------------------------------------------------------

  /// The `print` of a zone: the original output happens first and unchanged, then the line is
  /// recorded. Never throws what the capture does (the original's own exception is the app's).
  late final ZoneSpecification zoneSpecification = ZoneSpecification(
    print: (self, parent, zone, line) {
      // A hook nested in another (a guarded zone inside a captured one) records the line once:
      // the innermost, which sees it first, records it, and the outer finds the flag set.
      final nested = _inPrint;
      _inPrint = true;
      try {
        parent.print(zone, line);
      } finally {
        _inPrint = nested;
      }
      if (nested) return;
      _record(line, LogTags.print, zone);
    },
  );

  void _debugPrintHook(
    DebugPrintCallback previous,
    String? message,
    int? wrapWidth,
  ) {
    if (!_active) {
      // Uninstalled but still in a chain the app built: forward, nothing else.
      previous(message, wrapWidth: wrapWidth);
      return;
    }
    // What is printed, `null` included, is what is recorded.
    final text = message ?? 'null';
    _record(text, LogTags.debugPrint, Zone.current);
    _noteEcho(text);
    // The output the framework makes of it (a throttled `debugPrint` prints from a timer, later,
    // maybe in pieces) must not be recorded a second time by the zone hook: it goes through a zone the
    // capture ignores. Nothing else changes: same callback, same arguments.
    runSuppressed(() => previous(message, wrapWidth: wrapWidth));
  }

  /// Records [text] unless it is output the capture ignores. Never throws.
  void _record(String text, String tag, Zone zone) {
    try {
      if (!_active || logCaptureSuppressed(zone)) return;
      if (text.startsWith(ownOutputPrefix)) return;
      if (tag == LogTags.print && _isEcho(text)) return;
      if (looksLikeFlutterErrorDump(text)) {
        pipeline.noteErrorDump();
        return;
      }
      pipeline.submit(text, _level, tag);
    } catch (_) {
      // Capture must never throw into the app.
    }
  }

  /// How many characters of `debugPrint` text are remembered (for a test).
  int get rememberedEchoChars => _echoes.fold(0, (n, e) => n + e.$1.length);

  void _noteEcho(String text) {
    final now = monotonicMicros();
    _echoes.removeWhere((e) => e.$2 < now);
    if (_echoes.length >= _maxEchoes) _echoes.removeAt(0);
    // The capped text, like the recorded line: bounded, and what a piece can be a piece of.
    _echoes.add((capLine(text), now + _echoWindowMicros));
  }

  /// A piece shorter than this is only an echo when it is a whole line of the message: a wrapped
  /// piece of a long message is longer, and a short `print` of the app ('12', '}') is its own line.
  static const int _minEchoPiece = 12;

  /// Whether [line] is a piece of a `debugPrint` message that was recorded a moment ago, at word
  /// boundaries. A match uses the piece up (one print per piece), so the same text printed again is a
  /// new line. Counted in the stats.
  bool _isEcho(String line) {
    if (_echoes.isEmpty) return false;
    final now = monotonicMicros();
    _echoes.removeWhere((e) => e.$2 < now);
    final piece = line.trim();
    if (piece.isEmpty) return false;
    for (var i = 0; i < _echoes.length; i++) {
      final (text, until) = _echoes[i];
      var from = 0;
      while (true) {
        final at = text.indexOf(piece, from);
        if (at < 0) break;
        final end = at + piece.length;
        final startsAtBoundary = at == 0 || _isSpace(text.codeUnitAt(at - 1));
        final endsAtBoundary =
            end == text.length || _isSpace(text.codeUnitAt(end));
        final wholeLine =
            (at == 0 || text.codeUnitAt(at - 1) == 0x0A) &&
            (end == text.length || text.codeUnitAt(end) == 0x0A);
        if (startsAtBoundary &&
            endsAtBoundary &&
            (piece.length >= _minEchoPiece || wholeLine)) {
          final rest = text.substring(0, at) + text.substring(end);
          if (rest.trim().isEmpty) {
            _echoes.removeAt(i);
          } else {
            _echoes[i] = (rest, until);
          }
          pipeline.noteEchoDrop();
          return true;
        }
        from = at + 1;
      }
    }
    return false;
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D;

  /// A line from the app's own logging (`Bugsee.forwardLog`). Whether it was taken.
  bool forward(String message, LogLevel level, String? tag) {
    if (!_active) return false;
    try {
      if (logCaptureSuppressed()) return false;
      pipeline.submit(message, level, tag);
      return true;
    } catch (_) {
      return false;
    }
  }
}
