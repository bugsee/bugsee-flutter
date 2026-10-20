// Secure regions: the Dart half of workbook Part 5. Internal: not exported from
// package:bugsee_flutter; Phase 4 decides the public shape.
//
// A Flutter app is ONE host view, so the SDK's only way to learn what must not
// be recorded is a set of rectangles that this code measures and publishes. A
// wrong rectangle leaks pixels and also tap coordinates, so every ambiguous
// case here resolves to "cover MORE".
//
// What is reported, and why each case fails closed:
//
// * Position: the region's box, run through every ancestor's paint transform
//   (Transform, RotatedBox, scrolling offsets, ...), as the bounding box of the
//   result. A rotated region is reported as its (larger) axis-aligned box.
// * Clipping: NOT applied. A region that a ClipRect/viewport clips partly is
//   reported with its full, unclipped box, so every visible part of it is
//   covered (at the cost of covering some neighbouring pixels the clip hid).
//   Intersecting with ancestor clips would need every clip shape modelled
//   exactly (paths, rounded rects, a clip that animates); one error leaks.
// * Scrolled out / offstage / not painted: a region that contributes nothing to
//   the composited frame (its layer is not in the layer tree: the sliver did not
//   paint it, an Offstage or an inactive route hides it) is NOT reported, and is
//   removed the frame it stops painting. Reporting its stale geometry would
//   black out whatever now sits at that spot. A region that has never been laid
//   out or painted is in the same state.
// * Not measurable (a transform that yields NaN/infinity, an exception while
//   measuring): the WHOLE view is reported.
// * Degenerate (zero or negative area): nothing to hide; not reported.
//
// Changes are coalesced: the registry measures once per frame, after the frame
// (a post-frame callback), and publishes only when the set differs from what it
// last sent. Position changes that need no layout or paint of the region itself
// (scrolling inside a RepaintBoundary, a transform animation) are caught
// because the registry measures every frame while any region exists; a frame
// that never happens cannot have moved anything.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../bridge/messages.g.dart';

/// Sends one whole-state message to native. Returns whether it was applied.
typedef SecureRectanglesPublisher =
    Future<bool> Function(SecureRectanglesMessage state);

/// One region's measured box: logical pixels, relative to its view.
@immutable
class MeasuredRegion {
  const MeasuredRegion(this.viewId, this.rect);
  final int viewId;
  final Rect rect;

  @override
  bool operator ==(Object other) =>
      other is MeasuredRegion && other.viewId == viewId && other.rect == rect;

  @override
  int get hashCode => Object.hash(viewId, rect);

  @override
  String toString() => 'MeasuredRegion(view $viewId, $rect)';
}

/// The rectangles of every view: view id to its canonical rectangles.
typedef SecureState = Map<int, List<Rect>>;

bool _finite(double v) => v.isFinite;

bool _rectFinite(Rect r) =>
    _finite(r.left) && _finite(r.top) && _finite(r.right) && _finite(r.bottom);

/// Sorted, de-duplicated, without empty rectangles: the same set in any order
/// is the same state, so reordering regions never counts as a change.
List<Rect> canonicalRects(Iterable<Rect> rects) {
  final list =
      rects.where((r) => r.right > r.left && r.bottom > r.top).toSet().toList()
        ..sort((a, b) {
          var c = a.left.compareTo(b.left);
          if (c == 0) c = a.top.compareTo(b.top);
          if (c == 0) c = a.right.compareTo(b.right);
          if (c == 0) c = a.bottom.compareTo(b.bottom);
          return c;
        });
  return list;
}

/// Whether two states are the same set of rectangles per view.
bool sameState(SecureState a, SecureState b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null || other.length != entry.value.length) return false;
    for (var i = 0; i < other.length; i++) {
      if (other[i] != entry.value[i]) return false;
    }
  }
  return true;
}

/// Measures [box] in its view's logical pixels, or `null` when it contributes
/// nothing to what is on screen (see the library comment). Never throws.
MeasuredRegion? measureRegion(RenderSecureRegion box) {
  RenderView? view;
  try {
    if (!box.attached || !box.hasSize || !box.isOnScreen) return null;
    // The root of this box's tree is its view.
    RenderObject root = box;
    while (root.parent != null) {
      root = root.parent!;
    }
    if (root is! RenderView) return null;
    view = root;
    final size = box.size;
    if (size.width.isNaN || size.height.isNaN) return _wholeView(view);
    if (!(size.width > 0 && size.height > 0)) {
      return null; // zero or negative size: nothing to hide
    }
    final Rect rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & size,
    );
    return _rectFinite(rect)
        ? MeasuredRegion(view.flutterView.viewId, rect)
        : _wholeView(view);
  } catch (_) {
    return view == null ? null : _wholeView(view);
  }
}

MeasuredRegion? _wholeView(RenderView view) {
  try {
    final Size physical = view.flutterView.physicalSize;
    final double ratio = view.flutterView.devicePixelRatio;
    final Size logical = ratio > 0 && ratio.isFinite
        ? Size(physical.width / ratio, physical.height / ratio)
        : physical;
    final w = logical.width.isFinite ? logical.width : 1048576.0;
    final h = logical.height.isFinite ? logical.height : 1048576.0;
    return MeasuredRegion(
      view.flutterView.viewId,
      Rect.fromLTWH(0, 0, math.max(w.toDouble(), 1), math.max(h.toDouble(), 1)),
    );
  } catch (_) {
    return MeasuredRegion(
      view.flutterView.viewId,
      const Rect.fromLTWH(0, 0, 1048576, 1048576),
    );
  }
}

/// Tracks every [RenderSecureRegion], measures them once per frame and
/// publishes the set when it changed.
class SecureRegionRegistry {
  SecureRegionRegistry({
    required this.publish,
    int? epoch,
    this.retryDelay = const Duration(seconds: 1),
    this.maxRetries = 5,
  }) : epoch = epoch ?? DateTime.now().microsecondsSinceEpoch;

  /// The process-wide registry that widgets use unless given another.
  static SecureRegionRegistry get instance =>
      _instance ??= SecureRegionRegistry(publish: _publishToNative);
  static SecureRegionRegistry? _instance;

  static Future<bool> _publishToNative(SecureRectanglesMessage state) =>
      BugseeBridgeHostApi().setSecureRectangles(state);

  final SecureRectanglesPublisher publish;

  /// Identifies this isolate to native (see [SecureRectanglesMessage]).
  final int epoch;

  /// How long to wait before trying again after a failed publish; `null`
  /// leaves the retry to the next frame that happens.
  final Duration? retryDelay;
  final int maxRetries;

  final Set<RenderSecureRegion> _regions = <RenderSecureRegion>{};
  bool _scheduled = false;
  int _sequence = 0;
  int _failures = 0;
  Timer? _retry;

  /// What native is known to hold, or `null` when that is unknown (a publish
  /// failed): then the next measurement is sent even if it is empty.
  SecureState? _published = <int, List<Rect>>{};

  /// How many publishes were attempted. For tests.
  @visibleForTesting
  int get publishCount => _sequence;

  /// The regions currently registered. For tests.
  @visibleForTesting
  int get regionCount => _regions.length;

  void add(RenderSecureRegion region) {
    if (_regions.add(region)) _schedule();
  }

  void remove(RenderSecureRegion region) {
    if (_regions.remove(region)) _schedule();
  }

  void _schedule() {
    final binding = SchedulerBinding.instance;
    if (!_scheduled) {
      _scheduled = true;
      binding.addPostFrameCallback(_afterFrame);
    }
    // Registration happens in a frame (mount) almost always; this covers the
    // rest (and a retry), and is a no-op when a frame is already scheduled.
    binding.ensureVisualUpdate();
  }

  void _afterFrame(Duration _) {
    _scheduled = false;
    flush();
    // Scroll offsets and transforms can move a region with no layout or paint
    // of its own, so keep measuring on every frame while any region exists.
    // This schedules no frame; it only runs when one happens.
    if (_regions.isNotEmpty && !_scheduled) {
      _scheduled = true;
      SchedulerBinding.instance.addPostFrameCallback(_afterFrame);
    }
  }

  /// Measures now and publishes if the set changed. Normally called once per
  /// frame by the registry itself; public for tests.
  void flush() {
    final SecureState state = measure();
    final SecureState? published = _published;
    if (published != null && sameState(published, state)) return;
    _send(state);
  }

  /// The current state of every view, as it would be published.
  SecureState measure() {
    final byView = <int, List<Rect>>{};
    for (final region in _regions) {
      final m = measureRegion(region);
      if (m != null) (byView[m.viewId] ??= <Rect>[]).add(m.rect);
    }
    final result = <int, List<Rect>>{};
    final ids = byView.keys.toList()..sort();
    for (final id in ids) {
      final rects = canonicalRects(byView[id]!);
      if (rects.isNotEmpty) result[id] = rects;
    }
    return result;
  }

  void _send(SecureState state) {
    final sequence = ++_sequence;
    final message = SecureRectanglesMessage(
      epoch: epoch,
      sequence: sequence,
      views: [
        for (final entry in state.entries)
          SecureViewRectanglesMessage(
            viewId: entry.key,
            rectangles: [
              for (final r in entry.value) ...[
                r.left,
                r.top,
                r.right,
                r.bottom,
              ],
            ],
          ),
      ],
    );
    // Assume it lands: the next frame must not resend the same thing. A failure
    // below marks native's state unknown, which forces a resend.
    _published = state;
    Future<bool> sent;
    try {
      sent = publish(message);
    } catch (e) {
      sent = Future<bool>.error(e);
    }
    sent.then<void>(
      (_) {
        _failures = 0;
      },
      onError: (Object error, StackTrace stack) {
        // Only the newest attempt decides: an older one failing after a newer
        // one was sent says nothing about native's current state.
        if (sequence != _sequence) return;
        // Not reported to the app's error handlers: a missing native side
        // (desktop, a test) would fire this on every retry. The retry below
        // and `lastError` are the record.
        _published = null;
        _failures++;
        lastError = error;
        final delay = retryDelay;
        if (delay != null && _failures <= maxRetries) {
          _retry?.cancel();
          _retry = Timer(delay, _schedule);
        }
      },
    );
  }

  /// The error of the most recent failed publish, if any. For diagnostics.
  Object? lastError;

  /// Cancels any pending retry. For tests.
  @visibleForTesting
  void dispose() {
    _retry?.cancel();
    _retry = null;
  }
}

/// The render object behind [BugseeSecureRegion].
///
/// A repaint boundary on purpose: its layer is in the composited tree exactly
/// when the region is being painted this frame, which is how [isOnScreen] tells
/// a visible region from one that is offstage or scrolled out of its sliver.
class RenderSecureRegion extends RenderProxyBox {
  RenderSecureRegion({
    required bool enabled,
    required SecureRegionRegistry registry,
  }) : _enabled = enabled,
       _registry = registry;

  bool _enabled;
  SecureRegionRegistry _registry;

  @override
  bool get isRepaintBoundary => true;

  /// Whether this region is part of the composited frame.
  bool get isOnScreen {
    final l = layer;
    return l != null && l.attached;
  }

  bool get enabled => _enabled;
  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    if (!attached) return;
    value ? _registry.add(this) : _registry.remove(this);
  }

  SecureRegionRegistry get registry => _registry;
  set registry(SecureRegionRegistry value) {
    if (identical(value, _registry)) return;
    if (attached && _enabled) _registry.remove(this);
    _registry = value;
    if (attached && _enabled) _registry.add(this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    if (_enabled) _registry.add(this);
  }

  @override
  void detach() {
    _registry.remove(this);
    super.detach();
  }

  @override
  void dispose() {
    _registry.remove(this);
    super.dispose();
  }
}

/// Marks its child as a region the SDK must not record: redacted in the video
/// and the report screenshot, and taps on it are dropped from the report.
///
/// Internal for now (Phase 4 exposes it). See the library comment for how
/// transformed, clipped, scrolled and hidden regions are reported.
class BugseeSecureRegion extends SingleChildRenderObjectWidget {
  const BugseeSecureRegion({
    super.key,
    this.enabled = true,
    this.registry,
    super.child,
  });

  /// `false` removes the redaction (the child is shown as usual).
  final bool enabled;

  /// For tests; the process-wide registry by default.
  final SecureRegionRegistry? registry;

  @override
  RenderSecureRegion createRenderObject(BuildContext context) =>
      RenderSecureRegion(
        enabled: enabled,
        registry: registry ?? SecureRegionRegistry.instance,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSecureRegion renderObject,
  ) {
    renderObject
      ..registry = registry ?? SecureRegionRegistry.instance
      ..enabled = enabled;
  }
}
