// Installs the capture, keeps the policy current, owns the pipeline. Internal; the `Bugsee` facade
// is a thin layer over it (through `BugseeRuntime`).
import 'dart:async';

import 'package:flutter/foundation.dart'
    show DebugPrintCallback, debugPrint, debugPrintSynchronously;

import '../errors.dart';
import '../options/bugsee_options.g.dart' show LogLevel;
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
    void Function(String message)? warn,
    LogPipeline Function(LogSend send, LogPolicy Function() policy)?
    pipelineFactory,
  }) : _loadPolicy = loadPolicy,
       _ensureAttached = ensureAttached,
       _statuses = statuses,
       _supported = supported,
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
    if (_active && identical(debugPrint, _ourDebugPrint)) return true;
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
    // A (re)install believes nothing until the SDK's status and options are read.
    _policy = _policy.notAccepting();
    _statusSubscription ??= _statuses().listen((status) {
      if (status != BugseeStatus.launched && status != BugseeStatus.launching) {
        _policy = _policy.notAccepting();
      }
      unawaited(refreshPolicy());
    }, onError: (Object _) {});
    _ensureAttached();
    unawaited(refreshPolicy());
    return true;
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
    if (generation == _generation && _active) _policy = next;
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
  }

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
    _record(message ?? 'null', LogTags.debugPrint, Zone.current);
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
      if (looksLikeFlutterErrorDump(text)) {
        pipeline.noteErrorDump();
        return;
      }
      pipeline.submit(text, _level, tag);
    } catch (_) {
      // Capture must never throw into the app.
    }
  }

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
