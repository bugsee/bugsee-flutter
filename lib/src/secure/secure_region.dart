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
// * Hidden: a region is dropped ONLY on positive evidence that none of its
//   pixels are on screen: an ancestor that does not paint it (`paintsChild`:
//   Offstage, Visibility, zero Opacity), an IndexedStack showing another child,
//   or a clipping scroll viewport that its region (with what its descendants
//   paint) lies wholly outside of. Nothing else drops it. TickerMode is NOT
//   evidence: it only stops animations (reduce-motion, a paused tab), the
//   content is still painted. In particular a detached layer is
//   NOT evidence: SnapshotWidget (the Zoom page transition) paints a region into
//   a temporary layer and draws the cached image, so its pixels are on screen
//   while its own layer is not attached. A region that has never been laid out
//   is not reported (it has no geometry and has drawn nothing).
// * Overflow: what the region's descendants paint outside its box (a shifted
//   Transform, an OverflowBox) is included. What is drawn outside its subtree
//   (an Overlay magnifier, a tooltip) is not known to Flutter and not covered.
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
  const MeasuredRegion(this.viewId, this.ratio, this.rect);
  final int viewId;

  /// The view's device pixel ratio when it was measured.
  final double ratio;
  final Rect rect;

  @override
  bool operator ==(Object other) =>
      other is MeasuredRegion &&
      other.viewId == viewId &&
      other.ratio == ratio &&
      other.rect == rect;

  @override
  int get hashCode => Object.hash(viewId, ratio, rect);

  @override
  String toString() => 'MeasuredRegion(view $viewId @$ratio, $rect)';
}

/// What one view publishes: the ratio it was measured at and its canonical
/// rectangles.
@immutable
class ViewRects {
  const ViewRects(this.ratio, this.rects);
  final double ratio;
  final List<Rect> rects;
}

/// The rectangles of every view: view id to its ratio and rectangles.
typedef SecureState = Map<int, ViewRects>;

bool _rectFinite(Rect r) =>
    r.left.isFinite && r.top.isFinite && r.right.isFinite && r.bottom.isFinite;

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

/// Whether two states are the same set of rectangles per view, measured at the
/// same ratio (a ratio change must be republished even if no rectangle moved).
bool sameState(SecureState a, SecureState b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null ||
        other.ratio != entry.value.ratio ||
        other.rects.length != entry.value.rects.length) {
      return false;
    }
    for (var i = 0; i < other.rects.length; i++) {
      if (other.rects[i] != entry.value.rects[i]) return false;
    }
  }
  return true;
}

/// Descendants visited when looking for paint outside a region's box; more than
/// this and the region is reported as the whole view (fail closed).
const int _maxDescendants = 2000;

/// Whether [box] is PROVABLY not on screen. Only positive evidence counts; see
/// the library comment. [painted] is the box together with what its
/// descendants paint, in the view's logical pixels; without it only the
/// evidence that needs no geometry (ancestors that do not paint it) is used. Never throws (an exception
/// means "not provable").
bool provablyHidden(RenderSecureRegion box, Rect? painted) {
  try {
    RenderObject child = box;
    RenderObject? parent = box.parent;
    while (parent != null) {
      if (!parent.paintsChild(child)) return true;
      if (parent is RenderIndexedStack) {
        final visible = parent.index;
        if (visible == null) return true;
        RenderBox? shown = parent.firstChild;
        for (var i = 0; i < visible && shown != null; i++) {
          shown = (shown.parentData! as StackParentData).nextSibling;
        }
        if (!identical(shown, child)) return true;
      }
      if (painted != null &&
          parent is RenderViewportBase &&
          parent.clipBehavior != Clip.none) {
        // A viewport clips what lies outside it: a region wholly outside (with
        // everything it paints) is invisible (a child kept in the cache extent,
        // scrolled out of view).
        final Matrix4 toView = parent.getTransformTo(null);
        final Matrix4 fromView = Matrix4.tryInvert(toView) ?? Matrix4.zero();
        final Rect inViewport = MatrixUtils.transformRect(fromView, painted);
        final Rect port = Offset.zero & parent.size;
        if (Matrix4.tryInvert(toView) != null &&
            _rectFinite(inViewport) &&
            !inViewport.overlaps(port)) {
          return true;
        }
      }
      child = parent;
      parent = parent.parent;
    }
  } catch (_) {
    return false;
  }
  return false;
}

/// The box of [box] and of everything its descendants paint outside it, in the
/// view's logical pixels, or `null` when that is too much to follow. One
/// top-down pass: each child's transform is its parent's plus one
/// `applyPaintTransform`, not a walk to the root per node.
Rect? _paintedRect(RenderSecureRegion box) {
  final Matrix4 toView = box.getTransformTo(null);
  var rect = MatrixUtils.transformRect(toView, Offset.zero & box.size);
  var visited = 0;
  var tooMany = false;
  void visit(RenderObject node, Matrix4 nodeToView) {
    node.visitChildren((RenderObject child) {
      if (tooMany) return;
      // A child its parent does not paint has no meaningful geometry (a
      // zeroed transform would drag the rect to the view's origin).
      if (!node.paintsChild(child)) return;
      if (++visited > _maxDescendants) {
        tooMany = true;
        return;
      }
      final Matrix4 childToView = nodeToView.clone();
      node.applyPaintTransform(child, childToView);
      rect = rect.expandToInclude(
        MatrixUtils.transformRect(childToView, child.paintBounds),
      );
      visit(child, childToView);
    });
  }

  visit(box, toView);
  return tooMany ? null : rect;
}

/// Measures [box] in its view's logical pixels, or `null` when it contributes
/// nothing to what is on screen (see the library comment). Never throws.
MeasuredRegion? measureRegion(RenderSecureRegion box) {
  RenderView? view;
  try {
    if (!box.attached || !box.hasSize) return null;
    // Evidence that needs no geometry first: a hidden region is never measured, however
    // big its subtree or odd its transform.
    if (provablyHidden(box, null)) return null;
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
    final Rect? rect = _paintedRect(box);
    if (rect != null && _rectFinite(rect) && provablyHidden(box, rect)) {
      return null;
    }
    return rect != null && _rectFinite(rect)
        ? MeasuredRegion(
            view.flutterView.viewId,
            view.flutterView.devicePixelRatio,
            rect,
          )
        : _wholeView(view);
  } catch (_) {
    return view == null ? null : _wholeView(view);
  }
}

MeasuredRegion? _wholeView(RenderView view) {
  final int id = view.flutterView.viewId;
  final double ratio = view.flutterView.devicePixelRatio;
  try {
    final Size physical = view.flutterView.physicalSize;
    final Size logical = ratio > 0 && ratio.isFinite
        ? Size(physical.width / ratio, physical.height / ratio)
        : physical;
    final w = logical.width.isFinite ? logical.width : 1048576.0;
    final h = logical.height.isFinite ? logical.height : 1048576.0;
    return MeasuredRegion(
      id,
      ratio,
      Rect.fromLTWH(0, 0, math.max(w, 1), math.max(h, 1)),
    );
  } catch (_) {
    return MeasuredRegion(
      id,
      ratio,
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
  }) : epoch = epoch ?? _randomEpoch();

  /// A random id for this isolate, never a clock (a clock can go backwards
  /// before a hot restart, and native would then reject the new isolate).
  static int _randomEpoch() {
    final random = math.Random.secure();
    final int id = (random.nextInt(1 << 30) << 22) | random.nextInt(1 << 22);
    return id == 0 ? 1 : id;
  }

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
  SecureState? _published = <int, ViewRects>{};

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
    final ratios = <int, double>{};
    for (final region in _regions) {
      final m = measureRegion(region);
      if (m == null) continue;
      (byView[m.viewId] ??= <Rect>[]).add(m.rect);
      ratios[m.viewId] = m.ratio;
    }
    final result = <int, ViewRects>{};
    final ids = byView.keys.toList()..sort();
    for (final id in ids) {
      final rects = canonicalRects(byView[id]!);
      if (rects.isNotEmpty) result[id] = ViewRects(ratios[id]!, rects);
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
            devicePixelRatio: entry.value.ratio,
            rectangles: [
              for (final r in entry.value.rects) ...[
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
class RenderSecureRegion extends RenderProxyBox {
  RenderSecureRegion({
    required bool enabled,
    required SecureRegionRegistry registry,
  }) : _enabled = enabled,
       _registry = registry;

  bool _enabled;
  SecureRegionRegistry _registry;

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
