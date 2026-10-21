// Publishes the managed view hierarchy to native memory (doc/view-hierarchy.md). Internal.
//
// Why a push and not an answer on request: the SDK asks the wrapper for `vh` on the platform's
// main thread and times the reply from when the request RETURNS (500 ms). Dart cannot answer
// from there without a thread hop, and waiting for Dart on the platform thread is the deadlock
// the report pipeline already avoids; an asynchronous answer misses the report on Android when
// the request is made on the main thread. So Dart keeps native's copy current and native
// answers from memory, synchronously.
//
// Cost model (nothing here ever runs inside a frame's build, layout or paint):
//  * a snapshot is taken in a POST-FRAME callback or a timer, never more often than
//    [minInterval], and never more often than 20 times its own cost (a walk that took 10 ms
//    pushes the next one 200 ms out, capped at [maxInterval]);
//  * only a frame that happened can have changed anything, so no frame is ever scheduled except
//    the one that starts the publisher; with the app idle nothing runs;
//  * a snapshot identical to the one native holds is not sent;
//  * a walk is cut by its own time budget and node/byte caps (see [HierarchyLimits]);
//  * nothing is built while the publisher is not active (not launched, option off, background).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

import '../bridge/epoch.dart';
import '../bridge/messages.g.dart';
import 'hierarchy_builder.dart';

/// Sends one message to native. Returns whether it was applied.
typedef ViewHierarchySender = Future<bool> Function(ViewHierarchyMessage m);

/// Builds a snapshot (replaced in tests).
typedef ViewHierarchyBuilder =
    HierarchySnapshot? Function(
      HierarchyLimits limits,
      Duration Function() now,
    );

class ViewHierarchyPublisher {
  ViewHierarchyPublisher({
    required this.send,
    int? epoch,
    this.minInterval = const Duration(milliseconds: 300),
    this.maxInterval = const Duration(seconds: 5),
    this.limits = const HierarchyLimits(),
    Duration Function()? clock,
    ViewHierarchyBuilder? builder,
  }) : epoch = epoch ?? newIsolateEpoch(),
       _now = clock ?? _stopwatchClock(),
       _builder =
           builder ??
           ((limits, now) => buildViewHierarchy(limits: limits, clock: now));

  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// The process-wide publisher: the one native is told about.
  static ViewHierarchyPublisher get instance =>
      _instance ??= ViewHierarchyPublisher(send: _sendToNative);
  static ViewHierarchyPublisher? _instance;

  static Future<bool> _sendToNative(ViewHierarchyMessage m) =>
      BugseeBridgeHostApi().setViewHierarchy(m);

  final ViewHierarchySender send;

  /// Identifies this isolate to native (see [ViewHierarchyMessage]).
  final int epoch;

  /// The least time between two snapshots.
  final Duration minInterval;

  /// The most the cost-based spacing (and a failing channel's backoff) can reach.
  final Duration maxInterval;
  final HierarchyLimits limits;
  final Duration Function() _now;
  final ViewHierarchyBuilder _builder;

  bool _active = false;
  bool _frameArmed = false;
  bool _dirty = false;
  Timer? _timer;
  Duration _nextAllowed = Duration.zero;
  int _sequence = 0;
  int _failures = 0;

  /// What native is known to hold; `null` with [_nativeKnown] true means "nothing".
  HierarchySnapshot? _lastSent;

  /// `false` after a failed send: native's state is unknown, so the next result is sent even if
  /// it equals [_lastSent], and an empty one is sent too.
  bool _nativeKnown = true;

  /// How many messages were sent. For tests.
  @visibleForTesting
  int get sendCount => _sequence;

  /// Whether snapshots are being taken.
  bool get active => _active;

  /// Starts taking snapshots (idempotent). Schedules the one frame that gets the first one.
  void activate() {
    if (_active) return;
    _active = true;
    _dirty = true;
    _nextAllowed = Duration.zero;
    _armFrame();
    try {
      SchedulerBinding.instance.ensureVisualUpdate();
    } catch (_) {
      // No binding (a test without one): the next frame that happens is the first.
    }
  }

  /// Stops taking snapshots and clears native's copy, so a report taken from now on carries no
  /// stale hierarchy (idempotent). The clear is retried until it lands.
  Future<void> deactivate() async {
    _active = false;
    _timer?.cancel();
    _timer = null;
    _dirty = false;
    if (_lastSent == null && _nativeKnown) return;
    await _publish(null);
    if (!_nativeKnown && !_active) _armTimer(_backoff());
  }

  /// Takes a snapshot now, ignoring the throttle, and completes when native has it. A no-op while
  /// not active. For `Bugsee.captureViewHierarchy`: the SDK's pass then sees the screen as it is.
  Future<void> flush() async {
    if (!_active) return;
    _dirty = false;
    await _buildAndSend();
  }

  void _armFrame() {
    if (_frameArmed) return;
    _frameArmed = true;
    try {
      SchedulerBinding.instance.addPostFrameCallback(_onFrame);
    } catch (_) {
      _frameArmed = false;
    }
  }

  void _onFrame(Duration _) {
    _frameArmed = false;
    if (!_active) return;
    // A frame happened: the only thing that can have changed the tree. This schedules no frame.
    _dirty = true;
    _armFrame();
    _consider();
  }

  void _consider() {
    if (!_active || !_dirty) return;
    final Duration now = _now();
    if (now < _nextAllowed) {
      _armTimer(_nextAllowed - now);
      return;
    }
    _dirty = false;
    unawaited(_buildAndSend());
  }

  void _armTimer(Duration wait) {
    if (_timer != null) return;
    _timer = Timer(wait, () {
      _timer = null;
      if (!_active) {
        // Only a failed clear is retried while inactive.
        if (!_nativeKnown) unawaited(_publish(null));
        return;
      }
      final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
      if (phase == SchedulerPhase.idle ||
          phase == SchedulerPhase.postFrameCallbacks) {
        _consider();
      }
      // Otherwise a frame is in progress and its post-frame callback calls _consider.
    });
  }

  Duration _backoff() {
    final int doublings = math.min(_failures - 1, 12);
    final Duration wait = minInterval * (1 << (doublings < 0 ? 0 : doublings));
    return wait > _maxBackoff ? _maxBackoff : wait;
  }

  static const Duration _maxBackoff = Duration(seconds: 30);

  Future<void> _buildAndSend() async {
    HierarchySnapshot? snapshot;
    final Duration started = _now();
    try {
      snapshot = _builder(limits, _now);
    } catch (_) {
      snapshot = null; // fail closed: nothing is sent as a hierarchy
    }
    final Duration cost = _now() - started;
    final Duration spaced = cost * 20;
    Duration gap = spaced > minInterval ? spaced : minInterval;
    if (gap > maxInterval) gap = maxInterval;
    _nextAllowed = _now() + gap;
    final HierarchySnapshot? held = _lastSent;
    if (_nativeKnown) {
      if (snapshot == null && held == null) return; // nothing to take back
      if (snapshot != null && held != null && snapshot.sameContent(held)) {
        return;
      }
    }
    await _publish(snapshot);
  }

  Future<void> _publish(HierarchySnapshot? snapshot) async {
    final int sequence = ++_sequence;
    final ViewHierarchyMessage message = ViewHierarchyMessage(
      epoch: epoch,
      sequence: sequence,
      viewId: snapshot?.viewId ?? 0,
      devicePixelRatio: snapshot?.devicePixelRatio ?? 1,
      segments: snapshot?.segments ?? const <String>[],
      bounds: snapshot?.bounds ?? const <double>[],
    );
    // Assume it lands: the next frame must not resend the same thing.
    _lastSent = snapshot;
    _nativeKnown = true;
    try {
      await send(message);
      if (sequence == _sequence) _failures = 0;
    } catch (_) {
      // Only the newest attempt decides what native holds.
      if (sequence != _sequence) return;
      _nativeKnown = false;
      _failures++;
      _dirty = true;
      _nextAllowed = _now() + _backoff();
      _armTimer(_backoff());
    }
  }

  /// Cancels timers. For tests.
  @visibleForTesting
  void dispose() {
    _active = false;
    _timer?.cancel();
    _timer = null;
  }
}
