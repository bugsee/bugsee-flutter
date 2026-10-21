// The opt-in capture of unhandled Dart errors: FlutterError.onError, PlatformDispatcher.onError,
// the root isolate's error listener, zone errors and the listeners the app adds to isolates it
// spawns. Internal; the public face is `Bugsee.installErrorHandlers` and friends.
//
// The rules (doc/exceptions.md, each with a test):
//  * CHAIN, never replace: the handler that was installed first is called after ours, whatever
//    ours did, and its answer is returned (a PlatformDispatcher handler's `true` means "handled").
//    Without one, the platform handler answers `false`, so the engine's own reporting still runs.
//  * Uninstall restores the previous handlers only if ours are still the current ones. If
//    something else wrapped ours since, they cannot be unlinked: ours turn into pass-throughs.
//  * Never throws and never blocks: our part of every handler is guarded, the report is sent
//    without waiting, and a failure of the report is swallowed.
//  * Each error once: an object is reported once per process (an Expando); text and everything
//    else by fingerprint, at most once per [ReportLimiter.perFingerprint]; and a global ceiling.
//  * `FlutterErrorDetails.silent` errors are not reported (the framework marks expected ones so).
import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show ErrorCallback, PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show FlutterError, FlutterErrorDetails, FlutterExceptionHandler;
import 'package:meta/meta.dart' show visibleForTesting;

import 'exception_payload.dart';

/// What the capture hands on for each error it lets through.
typedef ErrorReporter =
    Future<void> Function(ExceptionPayload payload, {required bool handled});

/// A monotonic clock: time since something fixed, never going backwards (a wall clock does, when it
/// is set). Injectable for tests.
typedef MonotonicClock = Duration Function();

MonotonicClock _stopwatchClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

/// What the limiter says about an error.
enum LimiterVerdict {
  /// Report it.
  allowed,

  /// The same error was reported within [ReportLimiter.duplicateWindow]: the same throw arriving by
  /// a second route (a root-zone error reaches `PlatformDispatcher.onError` and the isolate
  /// listener). Dropped without counting it, and without a warning.
  duplicate,

  /// Over a limit: counted, and warned about once.
  limited,
}

/// Flood protection for the installed handlers (an explicit `Bugsee.logException` is never limited).
///
/// A render error repeats every frame, a timer error every tick: without a limit one bug would
/// open a report (video, logs, a disk write) sixty times a second.
final class ReportLimiter {
  ReportLimiter({
    this.perFingerprint = const Duration(seconds: 30),
    this.window = const Duration(seconds: 60),
    this.maxInWindow = 10,
    this.maxTracked = 64,
    this.duplicateWindow = const Duration(seconds: 1),
    MonotonicClock? now,
  }) : _now = now ?? _stopwatchClock();

  /// The same error is reported at most once in this long.
  final Duration perFingerprint;

  /// At most [maxInWindow] reports in any [window], whatever they are.
  final Duration window;
  final int maxInWindow;

  /// How many fingerprints are remembered; the oldest is forgotten first.
  final int maxTracked;

  /// An error reported within this long ago is the same throw seen twice, not a repeat.
  final Duration duplicateWindow;
  final MonotonicClock _now;

  /// The current time of this limiter's clock.
  Duration get now => _now();

  final Map<String, Duration> _last = <String, Duration>{};
  final List<Duration> _recent = <Duration>[];
  int _suppressed = 0;

  /// How many errors were turned away for a limit (not the duplicates).
  int get suppressed => _suppressed;

  /// What to do with an error with [fingerprint] now; [allowed] counts it.
  LimiterVerdict check(String fingerprint) {
    final now = _now();
    final last = _last[fingerprint];
    if (last != null) {
      final age = now - last;
      if (age < duplicateWindow) return LimiterVerdict.duplicate;
      if (age < perFingerprint) {
        _suppressed++;
        return LimiterVerdict.limited;
      }
    }
    _recent.removeWhere((t) => now - t >= window);
    if (_recent.length >= maxInWindow) {
      _suppressed++;
      return LimiterVerdict.limited;
    }
    _recent.add(now);
    _last.remove(fingerprint);
    _last[fingerprint] = now;
    if (_last.length > maxTracked) _last.remove(_last.keys.first);
    return LimiterVerdict.allowed;
  }
}

/// An isolate listener added with [ErrorCapture.listenTo]; [cancel] removes it.
final class IsolateErrorListener {
  IsolateErrorListener._(this._isolate, this._port);

  final Isolate _isolate;
  final RawReceivePort _port;
  bool _cancelled = false;

  /// Removes the listener. Idempotent.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    try {
      _isolate.removeErrorListener(_port.sendPort);
    } catch (_) {
      // the isolate is gone
    }
    _port.close();
  }
}

final class ErrorCapture {
  ErrorCapture({
    required ErrorReporter report,
    required bool Function() enabled,
    ReportLimiter? limiter,
    PlatformDispatcher? dispatcher,
    void Function(String message)? warn,
  }) : _report = report,
       _enabled = enabled,
       _limiter = limiter ?? ReportLimiter(),
       _dispatcher = dispatcher,
       _warn = warn ?? ((_) {});

  final ErrorReporter _report;
  final bool Function() _enabled;
  final ReportLimiter _limiter;
  final PlatformDispatcher? _dispatcher;
  final void Function(String) _warn;

  PlatformDispatcher get _platform =>
      _dispatcher ?? PlatformDispatcher.instance;

  _Installation? _installation;
  bool _busy = false;
  bool _warnedSuppression = false;
  bool _warnedReplaced = false;
  final Expando<Duration> _seen = Expando<Duration>('bugsee reported errors');

  /// Whether [install] was called (and not undone).
  bool get isInstalled => _installation != null;

  /// Whether every hook this installed is still the CURRENT handler. False after another tool
  /// assigned `FlutterError.onError` / `PlatformDispatcher.onError` without calling ours (Crashlytics'
  /// documented setup does), and also when a tool wrapped ours (which still reports whenever it calls
  /// through: that case cannot be told apart from the first by looking at the handler).
  bool get isActive {
    final installation = _installation;
    if (installation == null) return false;
    final flutter = installation.flutterHandler;
    if (flutter != null && !identical(FlutterError.onError, flutter)) {
      return false;
    }
    final platform = installation.platformHandler;
    if (platform != null && !identical(_platform.onError, platform)) {
      return false;
    }
    return true;
  }

  /// Debug aid: says so (once) when [install]ed handlers are no longer the current ones.
  void warnIfReplaced() {
    if (isInstalled && !isActive && !_warnedReplaced) {
      _warnedReplaced = true;
      _warn(
        'the Dart error handlers installed by Bugsee.installErrorHandlers are no longer '
        'FlutterError.onError / PlatformDispatcher.onError: another tool replaced or wrapped them. '
        'If it replaced them, Bugsee reports nothing from them: call installErrorHandlers AFTER the '
        'tools that assign these handlers (Crashlytics, Sentry).',
      );
    }
  }

  /// Where the root isolate's error listener receives messages (a test sends it the
  /// `[error, stack]` pair the VM would).
  @visibleForTesting
  SendPort? get debugIsolateSendPort => _installation?.isolatePort?.sendPort;

  /// How many errors the limiter turned away.
  int get suppressedCount => _limiter.suppressed;

  /// Installs the handlers, chained to what is there. A second call while installed does nothing
  /// (another SDK may have replaced the handlers since: [uninstall], then install again).
  void install({
    bool flutterErrors = true,
    bool platformErrors = true,
    bool isolateErrors = true,
    bool reportAsCrash = false,
  }) {
    if (_installation != null) return;
    final installation = _Installation(handled: !reportAsCrash);
    _installation = installation;

    if (flutterErrors) {
      final previous = FlutterError.onError;
      installation.previousFlutter = previous;
      void handler(FlutterErrorDetails details) {
        if (installation.active) {
          _guarded(() => _onFlutterError(details, installation.handled));
        }
        previous?.call(details);
      }

      installation.flutterHandler = handler;
      FlutterError.onError = handler;
    }

    if (platformErrors) {
      final dispatcher = _platform;
      final previous = dispatcher.onError;
      installation.previousPlatform = previous;
      bool handler(Object error, StackTrace stack) {
        // The previous handler first: its answer decides what this is. `true` says the app dealt
        // with the error, so it is not reported as a crash whatever `reportAsCrash` says. The report
        // is still made when the previous handler throws (its exception goes on to the app).
        bool? answer;
        try {
          answer = previous?.call(error, stack);
        } finally {
          if (installation.active) {
            _guarded(
              () => _captureObject(
                error,
                stack,
                installation.handled || answer == true,
              ),
            );
          }
        }
        return answer ?? false;
      }

      installation.platformHandler = handler;
      dispatcher.onError = handler;
    }

    if (isolateErrors) {
      try {
        final port = RawReceivePort((Object? message) {
          if (installation.active) {
            _guarded(() => _onIsolateMessage(message, installation.handled));
          }
        });
        Isolate.current.addErrorListener(port.sendPort);
        installation.isolatePort = port;
      } catch (_) {
        // an isolate that cannot be listened to is not a reason to fail the install
      }
    }
  }

  /// Restores the handlers that were there (see the class comment for when they cannot be).
  void uninstall() {
    final installation = _installation;
    if (installation == null) return;
    _installation = null;
    installation.active = false;

    final flutterHandler = installation.flutterHandler;
    if (flutterHandler != null &&
        identical(FlutterError.onError, flutterHandler)) {
      FlutterError.onError = installation.previousFlutter;
    }
    final platformHandler = installation.platformHandler;
    if (platformHandler != null &&
        identical(_platform.onError, platformHandler)) {
      _platform.onError = installation.previousPlatform;
    }
    final port = installation.isolatePort;
    if (port != null) {
      try {
        Isolate.current.removeErrorListener(port.sendPort);
      } catch (_) {}
      port.close();
    }
  }

  /// An error that reached a `runZonedGuarded` handler. Reported like the hooks (an error report unless crash reports were asked for), whether
  /// or not they are installed (the zone is the app's own choice).
  void captureZoneError(Object error, StackTrace stack, {bool? handled}) {
    final installation = _installation;
    _guarded(
      () => _captureObject(
        error,
        stack,
        handled ?? installation?.handled ?? true,
      ),
    );
  }

  /// Reports errors of [isolate] (an isolate the app spawned) until cancelled. Start the isolate
  /// paused, add the listener, then resume it: an isolate that exits first is missed.
  IsolateErrorListener listenTo(Isolate isolate, {bool? handled}) {
    final port = RawReceivePort((Object? message) {
      _guarded(
        () => _onIsolateMessage(
          message,
          handled ?? _installation?.handled ?? true,
        ),
      );
    });
    isolate.addErrorListener(port.sendPort);
    return IsolateErrorListener._(isolate, port);
  }

  void _onFlutterError(FlutterErrorDetails details, bool handled) {
    if (details.silent) return;
    _captureObject(details.exception, details.stack, handled);
  }

  void _onIsolateMessage(Object? message, bool handled) {
    // `[errorAsString, stackAsString or null]` (Isolate.addErrorListener).
    if (message is! List || message.length != 2) return;
    final text = '${message[0]}';
    final stackText = message[1];
    final stack = stackText is String && stackText.isNotEmpty
        ? StackTrace.fromString(stackText)
        : null;
    _process(
      identityKey: null,
      reason: capText(text, ExceptionWire.maxReasonLength),
      stack: stack,
      handled: handled,
      build: () => buildExceptionPayload(
        text,
        stack,
        name: classifyErrorText(text),
        reason: text,
      ),
    );
  }

  void _captureObject(Object error, StackTrace? stack, bool handled) {
    _process(
      identityKey: error,
      reason: describeError(error),
      stack: stack,
      handled: handled,
      build: () => buildExceptionPayload(error, stack),
    );
  }

  void _process({
    required Object? identityKey,
    required String reason,
    required StackTrace? stack,
    required bool handled,
    required ExceptionPayload Function() build,
  }) {
    if (!_enabled()) return;
    if (identityKey != null && _seenJustNow(identityKey)) return;
    String? raw;
    try {
      raw = stack == null
          ? null
          : FlutterError.demangleStackTrace(stack).toString();
    } catch (_) {}
    final verdict = _limiter.check(exceptionFingerprint(reason, raw));
    if (verdict == LimiterVerdict.duplicate) return;
    if (verdict == LimiterVerdict.limited) {
      if (!_warnedSuppression) {
        _warnedSuppression = true;
        _warn(
          'repeated Dart errors are being limited: the same error is reported once in '
          '${_limiter.perFingerprint.inSeconds} s, and at most ${_limiter.maxInWindow} in '
          '${_limiter.window.inSeconds} s',
        );
      }
      return;
    }
    final payload = build();
    try {
      unawaited(
        _report(payload, handled: handled).then<void>(
          (_) {},
          // The report is best effort; nothing may come back into the app's error path.
          onError: (Object _) {},
        ),
      );
    } catch (_) {}
  }

  /// Whether this very object was reported within the limiter's duplicate window: the same throw
  /// arriving by two routes. An older sighting does not count (a constant error such as
  /// `throw const FormatException('x')` is the same object every time; the per-fingerprint limit
  /// decides about it). Strings, numbers and the like cannot be remembered by identity (an Expando
  /// refuses them); the fingerprint covers them.
  bool _seenJustNow(Object error) {
    try {
      final now = _limiter.now;
      final before = _seen[error];
      if (before != null && now - before < _limiter.duplicateWindow) {
        return true;
      }
      _seen[error] = now;
    } catch (_) {}
    return false;
  }

  /// Runs [body] so that nothing it does reaches the app, and so that an error raised while
  /// reporting an error does not report itself again.
  void _guarded(void Function() body) {
    if (_busy) return;
    _busy = true;
    try {
      body();
    } catch (_) {
      // never throws from a handler
    } finally {
      _busy = false;
    }
  }
}

final class _Installation {
  _Installation({required this.handled});

  final bool handled;
  bool active = true;
  FlutterExceptionHandler? previousFlutter;
  ErrorCallback? previousPlatform;
  FlutterExceptionHandler? flutterHandler;
  ErrorCallback? platformHandler;
  RawReceivePort? isolatePort;
}
