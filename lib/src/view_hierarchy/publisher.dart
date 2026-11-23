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
//  * a walk is cut by its own time budget and node/byte caps (see [HierarchyLimits]); while a frame
//    is already due (an animation is running) the budget is a share of one frame at the display's
//    refresh rate ([frameShare], never over the limit's own budget), so it fits the slack of a
//    120 Hz frame as well as a 60 Hz one; with nothing due the full budget applies;
//  * a walk taken after a quiet stretch is SLICED: it runs a couple of milliseconds at a time (a share
//    of one frame, [sliceShare]), each slice from its own timer, so an input or a frame that arrives
//    meanwhile waits for one slice and not for the whole walk. The walk is STRICT: a frame that is
//    drawn or due while it is under way abandons it (the tree it was reading is gone) and the next
//    quiet stretch starts over; after [maxAbandons] abandoned walks in a row, or when a snapshot is
//    needed at once (nothing held natively, a stretch of frames that never stops, an explicit
//    capture), the walk is taken in one piece as before;
//  * a walk is only taken when the app has been quiet: no frame for [busyGap]. A walk straight
//    after a frame lands next to the following frame of a scroll, a fling, an animation or a
//    route transition, and delays it; after a quiet stretch it can only collide with an input
//    that arrives during the walk. A stretch of frames that never stops (a spinner) still gets a
//    walk every [busyCap], so its snapshot is refreshed;
//  * nothing is built while the publisher is not active (not launched, option off, background).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';

import '../bridge/epoch.dart';
import '../bridge/messages.g.dart';
import 'hierarchy_builder.dart';

/// Sends one message to native. Returns whether it was applied.
typedef ViewHierarchySender = Future<bool> Function(ViewHierarchyMessage m);

/// Starts a resumable walk (replaced in tests). `null`: nothing to describe.
typedef ViewHierarchyWalkStarter = HierarchyWalk? Function(
  HierarchyLimits limits,
  Duration Function() now,
);

/// Schedules the next slice of a walk: after whatever event is already waiting. A test holds it.
typedef ViewHierarchySliceScheduler = Timer Function(void Function() run);

/// Builds a snapshot (replaced in tests).
typedef ViewHierarchyBuilder = HierarchySnapshot? Function(
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
    this.frameWait = const Duration(milliseconds: 400),
    this.busyGap = const Duration(milliseconds: 100),
    this.busyCap = const Duration(seconds: 3),
    this.frameShare = 0.35,
    this.minBudget = const Duration(milliseconds: 2),
    this.sliceShare = 0.12,
    this.minSlice = const Duration(milliseconds: 1),
    this.maxSlice = const Duration(milliseconds: 4),
    this.slicedBudget = const Duration(milliseconds: 100),
    this.maxAbandons = 3,
    Duration Function()? frameInterval,
    bool Function()? framePending,
    Duration Function()? clock,
    ViewHierarchyBuilder? builder,
    ViewHierarchyWalkStarter? walkStarter,
    ViewHierarchySliceScheduler? sliceScheduler,
  }) : epoch = epoch ?? newIsolateEpoch(),
       _frameInterval = frameInterval ?? _displayFrameInterval,
       _framePending = framePending ?? _schedulerFramePending,
       _now = clock ?? _stopwatchClock(),
       _builder =
           builder ??
           ((limits, now) => buildViewHierarchy(limits: limits, clock: now)),
       // A test that supplies its own builder gets no slicing unless it supplies a walk too.
       _sliceScheduler = sliceScheduler ?? _nextEvent,
       _walkStarter =
           walkStarter ??
           (builder == null
               ? ((limits, now) =>
                     HierarchyWalk.start(limits: limits, clock: now))
               : null);

  /// One frame at the display's refresh rate (60 Hz when it is unknown).
  static Duration _displayFrameInterval() {
    try {
      final views = PlatformDispatcher.instance.views;
      final double hz = views.isEmpty ? 60 : views.first.display.refreshRate;
      if (hz.isFinite && hz >= 24 && hz <= 480) {
        return Duration(microseconds: (1e6 / hz).round());
      }
    } catch (_) {
      // Unknown display: assume 60 Hz.
    }
    return const Duration(microseconds: 16667);
  }

  static bool _schedulerFramePending() {
    try {
      return SchedulerBinding.instance.hasScheduledFrame;
    } catch (_) {
      return false;
    }
  }

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

  /// The longest [flush] waits for a frame that is already scheduled (a screen change that has
  /// not been drawn yet), so the snapshot is of the screen as it will be, not as it was.
  final Duration frameWait;

  /// A walk waits until no frame has been drawn for this long; frames closer together than this
  /// are one stretch of activity. `Duration.zero` turns the wait off (tests).
  final Duration busyGap;

  /// The most a stretch of activity postpones a walk: after this the walk is taken anyway.
  final Duration busyCap;

  /// The share of one frame a walk may take while a frame is due, and the least it is given.
  final double frameShare;
  final Duration minBudget;

  /// The length of one slice of a sliced walk: this share of one frame at the display's refresh
  /// rate (0.12 of 16.7 ms is 2 ms; of 8.3 ms, 1 ms), kept between [minSlice] and [maxSlice]. A
  /// slice is a time between two chances for an input or a frame to be handled.
  final double sliceShare;
  final Duration minSlice;
  final Duration maxSlice;

  /// How much time, summed over its slices, a sliced walk may spend before the rest is cut (the
  /// jank of each slice is bounded by the slice, so the total may be larger than [limits]'s).
  final Duration slicedBudget;

  /// After this many sliced walks in a row that a frame abandoned, the next walk is taken in one
  /// piece: a screen that draws a frame every so often must still get a complete snapshot.
  final int maxAbandons;
  final Duration Function() _frameInterval;
  final bool Function() _framePending;
  final Duration Function() _now;
  final ViewHierarchyBuilder _builder;
  final ViewHierarchyWalkStarter? _walkStarter;
  final ViewHierarchySliceScheduler _sliceScheduler;

  static Timer _nextEvent(void Function() run) => Timer(Duration.zero, run);

  /// The sliced walk under way, its next slice's timer, and how many walks in a row a frame
  /// abandoned.
  HierarchyWalk? _walk;
  Timer? _sliceTimer;
  int _abandons = 0;

  bool _active = false;
  bool _frameArmed = false;
  bool _dirty = false;
  Timer? _timer;
  Timer? _settleTimer;
  Duration? _lastFrameAt;
  Duration? _busySince;
  Duration _nextAllowed = Duration.zero;
  int _sequence = 0;
  int _failures = 0;

  /// What native is known to hold; `null` with [_nativeKnown] true means "nothing".
  HierarchySnapshot? _lastSent;

  /// `false` after a failed send: native's state is unknown, so the next result is sent even if
  /// it equals [_lastSent], and an empty one is sent too.
  bool _nativeKnown = true;

  /// Whether a sliced walk is under way. For tests.
  @visibleForTesting
  bool get walking => _walk != null;

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
    _abandonWalk(counted: false);
    _abandons = 0;
    _timer?.cancel();
    _timer = null;
    _settleTimer?.cancel();
    _settleTimer = null;
    _busySince = null;
    _lastFrameAt = null;
    _dirty = false;
    if (_lastSent == null && _nativeKnown) return;
    await _publish(null);
    if (!_nativeKnown && !_active) _armTimer(_backoff());
  }

  /// Takes a snapshot now, ignoring the throttle, and completes when native has it. A no-op while
  /// not active. For `Bugsee.captureViewHierarchy`: the SDK's pass then sees the screen as it is.
  Future<void> flush() async {
    if (!_active) return;
    _abandonWalk(counted: false); // the explicit walk replaces it, in one piece
    await _awaitScheduledFrame();
    if (!_active) return;
    _abandonWalk(counted: false);
    _dirty = false;
    await _buildAndSend(explicit: true);
  }

  /// A change is on its way to the screen: wait for its frame (a new route needs two: it is built
  /// off stage first and shown by the next), so the walk sees the new tree and not the old one.
  /// Bounded in frames (3) and in time ([frameWait]): a screen that never draws, or one that
  /// animates forever, must not hang the caller.
  Future<void> _awaitScheduledFrame() async {
    try {
      final SchedulerBinding binding = SchedulerBinding.instance;
      Future<void> frames() async {
        for (var i = 0; i < 3 && binding.hasScheduledFrame; i++) {
          await binding.endOfFrame;
        }
      }

      await frames().timeout(frameWait, onTimeout: () {});
    } catch (_) {
      // Build from what there is.
    }
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
    final Duration now = _now();
    final Duration? last = _lastFrameAt;
    _lastFrameAt = now;
    if (last == null || now - last >= busyGap) _busySince = now;
    // The tree a sliced walk was reading may be gone: strict, start over after the quiet.
    _abandonWalk();
    _dirty = true;
    _armFrame();
    _consider();
  }

  /// Whether a frame was drawn too recently for a walk (and the stretch of frames it belongs to
  /// has not gone on for [busyCap]).
  bool _busy(Duration now) {
    final Duration? since = _busySince;
    final Duration? last = _lastFrameAt;
    if (since == null || last == null) return false;
    // Nothing is held natively (the first snapshot after activation or a resume, or after a
    // failed send): a report now would carry no hierarchy at all, which is worse than the one
    // walk next to a frame.
    if (_lastSent == null || !_nativeKnown) return false;
    if (now - last >= busyGap) return false; // quiet
    return now - since < busyCap;
  }

  /// Waits for the frames to stop, then takes the walk that was postponed.
  void _armSettle() {
    if (_settleTimer != null) return;
    _settleTimer = Timer(busyGap, () {
      _settleTimer = null;
      if (!_active) return;
      final Duration? last = _lastFrameAt;
      if (last != null && _now() - last < busyGap) {
        _armSettle(); // another frame came: still busy
        return;
      }
      _busySince = null;
      final SchedulerPhase phase = SchedulerBinding.instance.schedulerPhase;
      if (phase == SchedulerPhase.idle ||
          phase == SchedulerPhase.postFrameCallbacks) {
        _consider();
      }
    });
  }

  void _consider() {
    if (!_active || !_dirty || _walk != null) return;
    final Duration now = _now();
    if (_busy(now)) {
      _armSettle();
      return;
    }
    if (now < _nextAllowed) {
      _armTimer(_nextAllowed - now);
      return;
    }
    if (_busySince != null && now - _busySince! >= busyCap) {
      // The cap was reached and the walk goes ahead: the next stretch is counted from it (not
      // from a walk the throttle or a retry backoff still holds back).
      _busySince = now;
    }
    _dirty = false;
    if (_sliceable(now)) {
      _startSlicedWalk();
    } else {
      unawaited(_buildAndSend());
    }
  }

  /// Whether the walk about to be taken is sliced: after a real quiet stretch with nothing due,
  /// while native holds a snapshot (so a slow walk costs a stale answer at worst, not none) and
  /// walks have not been starved by frames. Every other walk is taken in one piece, as it was
  /// before slicing existed: the first snapshot, one forced by [busyCap], one after
  /// [maxAbandons] abandoned walks, an explicit capture.
  bool _sliceable(Duration now) {
    if (_walkStarter == null || _abandons >= maxAbandons) return false;
    if (_lastSent == null || !_nativeKnown) return false;
    final Duration? last = _lastFrameAt;
    if (last != null && now - last < busyGap) return false;
    return !_framePending();
  }

  /// The length of a slice now. For tests.
  @visibleForTesting
  Duration get sliceLengthForTest => _sliceLength();

  /// One slice of the walk: a share of one frame, between [minSlice] and [maxSlice].
  Duration _sliceLength() {
    Duration slice = _frameInterval() * sliceShare;
    if (slice < minSlice) slice = minSlice;
    if (slice > maxSlice) slice = maxSlice;
    return slice;
  }

  void _startSlicedWalk() {
    HierarchyWalk? walk;
    try {
      walk = _walkStarter!(limits.withBudget(slicedBudget), _now);
    } catch (_) {
      walk = null; // fail closed, as an error in a walk in one piece
    }
    if (walk == null) {
      unawaited(_finishBuild(null, Duration.zero));
      return;
    }
    _walk = walk;
    _runSlice();
  }

  void _runSlice() {
    _sliceTimer = null;
    final HierarchyWalk? walk = _walk;
    if (walk == null) return;
    // A frame is due: it will draw into the tree being read. Do not spend a slice on a walk it
    // is about to void (its own post-frame callback abandons it, counted once).
    if (!_active || _framePending()) {
      _abandonWalk();
      return;
    }
    bool done;
    try {
      done = walk.step(_sliceLength());
    } catch (_) {
      done = true;
    }
    if (!done) {
      // The next slice is a timer of its own: whatever input or frame is waiting is handled first.
      _sliceTimer = _sliceScheduler(_runSlice);
      return;
    }
    _walk = null;
    if (walk.invalid) {
      // The tree changed with no frame seen: start over after the quiet, never use a mixed one.
      _abandons++;
      _dirty = true;
      _armSettle();
      return;
    }
    unawaited(_finishBuild(walk.result, walk.spent));
  }

  /// Gives up the walk under way. [counted]: a frame (or the lack of a quiet stretch) abandoned
  /// it, which counts towards [maxAbandons]; a stop or an explicit capture does not.
  void _abandonWalk({bool counted = true}) {
    _sliceTimer?.cancel();
    _sliceTimer = null;
    if (_walk == null) return;
    _walk = null;
    if (counted) _abandons++;
    _dirty = true;
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

  /// The limits for a walk taken now: the walk is cut at a share of one frame when a frame is
  /// already due, because then the walk would be added to a frame on a tight budget. An explicit
  /// capture keeps the full budget (the caller waits for it, nothing is drawn because of it).
  HierarchyLimits _limitsNow({required bool explicit}) {
    if (explicit || !_framePending()) return limits;
    Duration share = _frameInterval() * frameShare;
    if (share < minBudget) share = minBudget;
    return share >= limits.budget ? limits : limits.withBudget(share);
  }

  Future<void> _buildAndSend({bool explicit = false}) async {
    HierarchySnapshot? snapshot;
    final Duration started = _now();
    try {
      snapshot = _builder(_limitsNow(explicit: explicit), _now);
    } catch (_) {
      snapshot = null; // fail closed: nothing is sent as a hierarchy
    }
    await _finishBuild(snapshot, _now() - started);
  }

  /// What follows a walk, sliced or not: spaces the next one by its [cost], and sends the
  /// [snapshot] when it is not what native holds.
  Future<void> _finishBuild(HierarchySnapshot? snapshot, Duration cost) async {
    _abandons = 0; // a walk completed: frames have not starved them
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
      // A sliced walk that is under way would finish into the backoff and send before it ends:
      // the retry is the next walk, in one piece, from the timer below.
      _abandonWalk(counted: false);
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
    _abandonWalk(counted: false);
    _timer?.cancel();
    _timer = null;
    _settleTimer?.cancel();
    _settleTimer = null;
  }
}
