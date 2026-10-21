// The managed view hierarchy (`vh`): the Dart half. Internal; see doc/view-hierarchy.md.
//
// Source tree: the ELEMENT tree, walked together with the RENDER tree it owns. Elements give a
// name for every widget (including the app's own composites: `LoginScreen`), render objects give
// exact geometry and tell what is painted. The semantics tree is NOT used: it exists only for
// accessibility, carries the user-visible text (labels, hints, values) and is built lazily, so
// reading it would be both the privacy risk and a cost.
//
// WHAT IS NEVER READ (privacy, enforced by construction and by test/view_hierarchy_privacy_test.dart):
// no `Text`/`RichText`/`EditableText` content, no `TextEditingController`, no semantics label, hint
// or value, no tooltip message, no `Key` or `ValueKey` (they carry arbitrary app strings), no
// `Hero` tag, no image bytes, and never `toString()` of a widget or element (a widget's
// `toString` may print its text). The only strings that reach the payload are `runtimeType` names
// (type names: developer-chosen, never user data) and the fixed vocabulary below. A node is
// therefore described by: its type, its box, whether it is clickable, an opacity, a content kind
// (`image`, `surface`) and whether it is secure.
//
// A `BugseeSecureView` subtree is REDACTED WHOLE: the region's own node is emitted (class
// `BugseeSecureView`, its box exactly as the secure rectangle measures it, `secure: true`) and
// nothing below it. The widgets under it, even their type names, are not in the payload.
//
// What is in: only what is on stage and painted. An element under `Offstage`, a route the
// `Overlay` keeps off stage, a child its render parent does not paint (`Visibility`, zero
// `Opacity`, an `IndexedStack`'s other children), and a node wholly outside the screen or outside
// the clip an ancestor applies (a scrolled-out list item) are not emitted. Subitems are in PAINT
// ORDER (back to front), which is also the viewer's tie-break for z order. The soft keyboard is a
// native window, not part of Flutter's tree; the native hierarchy carries it.
//
// Geometry: boxes are in the Flutter view's LOGICAL pixels with the view's top-left as origin
// (the same space the secure rectangles are measured in). Native converts them to the SDK's unit
// and places the view on the screen (physical pixels on Android, points on iOS), through the same
// code as the secure rectangles; this file never produces a screen coordinate. The payload is
// therefore a TEMPLATE: JSON text cut at every place a number belongs, plus the logical numbers
// (see [HierarchySnapshot]).
//
// Caps: [HierarchyLimits]. Over a cap the walk stops adding nodes, marks what it cut with
// `truncated`, and the answer is still valid; any error fails closed (`null`, nothing sent).
import 'dart:convert' show jsonEncode;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../secure/secure_region.dart';

/// Hard limits of one snapshot. A tree beyond them is cut and marked `truncated`.
@immutable
class HierarchyLimits {
  const HierarchyLimits({
    this.maxNodes = 2000,
    this.maxDepth = 256,
    this.maxBytes = 256 * 1024,
    this.budget = const Duration(milliseconds: 12),
  });

  /// Most nodes emitted.
  final int maxNodes;

  /// Deepest element level visited (counted in elements, not emitted nodes).
  final int maxDepth;

  /// Most UTF-8 bytes of the JSON template (an estimate while walking, exact at the end: a
  /// template over it is dropped).
  final int maxBytes;

  /// How long the walk may run; past it the rest of the tree is cut. One walk is synchronous on
  /// the UI isolate, so this bounds the jank it can cause.
  final Duration budget;
}

/// One snapshot of one Flutter view: a JSON template plus the numbers that fill it in.
///
/// `segments` has `bounds.length / 4 + 2` entries. Native writes `segments[0]`, the age of the
/// snapshot in milliseconds, `segments[1]`, then for node `k` (0-based, in document order) the
/// box `[x,y,w,h]` converted from `bounds[4k..4k+3]` (logical `left, top, right, bottom` in the
/// view), then `segments[k + 2]`. It is never parsed natively, and never altered except for
/// those insertions.
@immutable
class HierarchySnapshot {
  const HierarchySnapshot({
    required this.viewId,
    required this.devicePixelRatio,
    required this.segments,
    required this.bounds,
    required this.nodeCount,
    required this.truncated,
  });

  final int viewId;

  /// The view's device pixel ratio the boxes were measured at.
  final double devicePixelRatio;
  final List<String> segments;
  final List<double> bounds;
  final int nodeCount;
  final bool truncated;

  /// The same payload (what native would serve), whatever the walk's cost or time.
  bool sameContent(HierarchySnapshot other) {
    if (viewId != other.viewId ||
        devicePixelRatio != other.devicePixelRatio ||
        segments.length != other.segments.length ||
        bounds.length != other.bounds.length) {
      return false;
    }
    for (var i = 0; i < segments.length; i++) {
      if (segments[i] != other.segments[i]) return false;
    }
    for (var i = 0; i < bounds.length; i++) {
      if (bounds[i] != other.bounds[i]) return false;
    }
    return true;
  }

  /// The payload with every box taken as it is and the age as given, for tests and tools: the
  /// logical-pixel view of what native would serve.
  String render({int ageMs = 0}) {
    final out = StringBuffer(segments[0])..write(ageMs);
    for (var i = 1; i < segments.length; i++) {
      out.write(segments[i]);
      if (i - 1 < bounds.length ~/ 4) {
        final k = (i - 1) * 4;
        final l = bounds[k], t = bounds[k + 1];
        out.write('[$l,$t,${bounds[k + 2] - l},${bounds[k + 3] - t}]');
      }
    }
    return out.toString();
  }
}

/// The node type that stands for a `BugseeSecureView` (the widget the app wrote).
const String secureNodeClassName = 'BugseeSecureView';

/// The root node's type: the Flutter view itself.
const String viewNodeClassName = 'FlutterView';

class _ObfuscationProbe {}

/// Whether type names are minified (`--obfuscate`): then `class_name`s are not readable, and the
/// root says so.
bool get typeNamesAreObfuscated =>
    _ObfuscationProbe().runtimeType.toString() != '_ObfuscationProbe';

/// A type's name without generic arguments and bounded in length.
String _typeName(Object object) {
  final String s = object.runtimeType.toString();
  final int generic = s.indexOf('<');
  final String bare = generic < 0 ? s : s.substring(0, generic);
  return bare.length > 80 ? bare.substring(0, 80) : bare;
}

class _Node {
  _Node(this.className);
  final String className;
  String? baseClassName;
  Rect? rect;
  final List<_Node> children = <_Node>[];
  bool secure = false;
  bool clickable = false;
  bool truncated = false;
  double? alpha;
  String? contentKind;
}

class _Context {
  const _Context(this.parent, this.toView, this.clip);

  /// The nearest ancestor render object, or `null` at the view.
  final RenderObject? parent;

  /// [parent]'s transform to the view (logical pixels).
  final Matrix4 toView;

  /// What is still visible after every clip on the way down, in the view's logical pixels.
  final Rect clip;
}

bool _finite(Rect r) =>
    r.left.isFinite && r.top.isFinite && r.right.isFinite && r.bottom.isFinite;

/// Whether [rect] (which has an area) shares an area with [clip]: a box that only touches the edge
/// of the visible region shows no pixel of it.
bool _touches(Rect rect, Rect clip) =>
    clip.left < clip.right &&
    clip.top < clip.bottom &&
    rect.left < clip.right &&
    rect.right > clip.left &&
    rect.top < clip.bottom &&
    rect.bottom > clip.top;

/// Builds the snapshot of the implicit view (or [viewId]), or `null` when there is nothing to
/// describe or anything went wrong (fail closed: no partial answer on an error). Never throws.
///
/// [root] is the element tree's root (`WidgetsBinding.rootElement` by default). [clock] is a
/// monotonic clock the budget is read from (a test supplies its own).
HierarchySnapshot? buildViewHierarchy({
  Element? root,
  int viewId = 0,
  HierarchyLimits limits = const HierarchyLimits(),
  Duration Function()? clock,
  @visibleForTesting bool? obfuscated,
}) {
  try {
    final Element? top = root ?? WidgetsBinding.instance.rootElement;
    if (top == null) return null;
    final Element? viewElement = _findView(top, viewId);
    if (viewElement == null) return null;
    final Duration Function() now = clock ?? _stopwatchClock();
    final walker = _Walker(limits, now, obfuscated ?? typeNamesAreObfuscated);
    return walker.run(viewElement as RenderObjectElement);
  } catch (_) {
    return null;
  }
}

Duration Function() _stopwatchClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

Element? _findView(Element start, int viewId) {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is RenderObjectElement) {
      final RenderObject ro = e.renderObject;
      if (ro is RenderView) {
        if (ro.flutterView.viewId == viewId) found = e;
        return; // a view's own tree is not searched for another view
      }
    }
    e.visitChildren(visit);
  }

  visit(start);
  return found;
}

class _Walker {
  _Walker(this.limits, this.now, this.obfuscated) : _start = now();

  final bool obfuscated;

  final HierarchyLimits limits;
  final Duration Function() now;
  final Duration _start;
  int _nodes = 0;
  int _bytes = 0;
  int _steps = 0;
  bool _truncated = false;
  bool _stopped = false;

  HierarchySnapshot? run(RenderObjectElement viewElement) {
    final RenderView view = viewElement.renderObject as RenderView;
    final Size size = view.size;
    if (!(size.width > 0 && size.height > 0) ||
        !size.width.isFinite ||
        !size.height.isFinite) {
      return null;
    }
    final Rect screen = Offset.zero & size;
    final rootNode = _Node(viewNodeClassName)..rect = screen;
    _nodes = 1;
    _children(
      viewElement,
      _Context(view, Matrix4.identity(), screen),
      rootNode,
      1,
    );
    final writer = _Writer(obfuscated: obfuscated);
    writer.writeRoot(
      rootNode,
      view.flutterView.devicePixelRatio,
      _truncated || rootNode.truncated,
    );
    final String template = writer.finish();
    // The estimate while walking is generous; an over-size template is dropped, not trimmed.
    // Numbers are not in the template yet: each box adds about 24 bytes.
    if (template.length + 24 * writer.nodeCount > limits.maxBytes) return null;
    return HierarchySnapshot(
      viewId: view.flutterView.viewId,
      devicePixelRatio: view.flutterView.devicePixelRatio,
      segments: writer.segments,
      bounds: writer.bounds,
      nodeCount: writer.nodeCount,
      truncated: _truncated || rootNode.truncated,
    );
  }

  /// Whether a cap says to stop adding nodes; flags [parent] (and the snapshot) when it does.
  bool _capped(_Node parent, int depth) {
    if (_stopped) {
      parent.truncated = true;
      return true;
    }
    if ((++_steps & 31) == 0 && now() - _start > limits.budget) {
      _stopped = true;
    }
    if (_stopped ||
        _nodes >= limits.maxNodes ||
        _bytes >= limits.maxBytes ~/ 2 ||
        depth > limits.maxDepth) {
      _truncated = true;
      parent.truncated = true;
      return true;
    }
    return false;
  }

  void _children(Element e, _Context ctx, _Node into, int depth) {
    e.debugVisitOnstageChildren((Element child) {
      _visit(child, ctx, into, depth);
    });
  }

  void _visit(Element e, _Context ctx, _Node into, int depth) {
    // A provider of data: no box of its own, no name worth a node.
    if (e is InheritedElement) {
      _children(e, ctx, into, depth + 1);
      return;
    }
    if (_capped(into, depth)) return;
    if (e is RenderObjectElement) {
      _visitRender(e, ctx, into, depth);
      return;
    }
    // A composite (StatelessWidget, StatefulWidget, ...): named, no geometry of its own; its box
    // is its painted children's, and it is absent when none of them is painted.
    final node = _Node(_typeName(e.widget));
    _reserve(node); // before its children, so the caps see it
    _children(e, ctx, node, depth + 1);
    Rect? box;
    for (final _Node c in node.children) {
      final Rect? r = c.rect;
      if (r != null) box = box == null ? r : box.expandToInclude(r);
    }
    if (box == null) {
      // Nothing of it is painted: no node, and its slot is given back. What a cap cut below it
      // is still said, by the node above.
      if (node.truncated) into.truncated = true;
      _nodes--;
      _bytes -= _estimate(node);
      return;
    }
    node.rect = box;
    into.children.add(node);
  }

  int _estimate(_Node node) =>
      150 + node.className.length * 2 + (node.baseClassName?.length ?? 0);

  void _reserve(_Node node) {
    _nodes++;
    _bytes += _estimate(node);
  }

  void _visitRender(
    RenderObjectElement e,
    _Context ctx,
    _Node into,
    int depth,
  ) {
    final RenderObject ro = e.renderObject;
    if (!ro.attached) return;
    final Rect local;
    if (ro is RenderView) {
      return; // another view's tree is its own snapshot
    } else if (ro is RenderBox) {
      if (!ro.hasSize) return; // never laid out: nothing painted yet
      local = Offset.zero & ro.size;
    } else {
      local = ro.paintBounds;
    }
    final Matrix4 toView;
    Rect clip = ctx.clip;
    final RenderObject? parent = ctx.parent;
    if (parent != null && identical(ro.parent, parent)) {
      if (!parent.paintsChild(ro)) return; // not painted: not on screen
      toView = ctx.toView.clone();
      // The view's own transform is the device pixel ratio: boxes stay in LOGICAL pixels (the
      // space `getTransformTo(null)` and the secure rectangles use), which native converts.
      if (parent is! RenderView) parent.applyPaintTransform(ro, toView);
      final Rect? applied = parent.describeApproximatePaintClip(ro);
      if (applied != null) {
        clip = clip.intersect(MatrixUtils.transformRect(ctx.toView, applied));
      }
    } else {
      toView = ro.getTransformTo(null);
    }
    final Rect box = MatrixUtils.transformRect(toView, local);
    if (!_finite(box) || box.isEmpty || !_touches(box, clip)) return;

    final node = _Node(_typeName(e.widget))
      ..baseClassName = _typeName(ro)
      ..rect = box;
    if (ro is RenderSecureRegion && ro.enabled) {
      // Redacted whole: this node, and nothing below it. Its box is the one the secure
      // rectangle measures (what the video masks), so the two describe the same area.
      final MeasuredRegion? region = measureRegion(ro);
      if (region == null) return; // provably not on screen
      // A fixed type name and nothing the widget tree said (not even the widget's own name).
      final secure = _Node(secureNodeClassName)
        ..rect = region.rect
        ..secure = true;
      _reserve(secure);
      into.children.add(secure);
      return;
    }
    // Whether something can be tapped here, as the widgets declare it: a `GestureDetector`'s
    // semantics handler, or a `Semantics` annotation with a tap or long-press action (Material
    // buttons, `InkWell`, text fields). Only whether a callback EXISTS is read, never a label.
    if (ro is RenderSemanticsGestureHandler) {
      node.clickable = ro.onTap != null || ro.onLongPress != null;
    } else if (ro is RenderSemanticsAnnotations) {
      final SemanticsProperties p = ro.properties;
      node.clickable = p.onTap != null || p.onLongPress != null;
    } else if (ro is RenderOpacity) {
      node.alpha = ro.opacity;
    } else if (ro is RenderAnimatedOpacity) {
      node.alpha = ro.opacity.value;
    } else if (ro is RenderImage) {
      node.contentKind = 'image';
    } else if (ro is RenderAndroidView ||
        ro is RenderUiKitView ||
        ro is PlatformViewRenderBox) {
      node.contentKind = 'surface';
    }
    _reserve(node);
    _children(e, _Context(ro, toView, clip), node, depth + 1);
    into.children.add(node);
  }
}

/// Serialises the node tree into a template: JSON text cut at the age and at every box.
class _Writer {
  _Writer({required this.obfuscated});

  final bool obfuscated;
  final StringBuffer _text = StringBuffer();
  final List<String> segments = <String>[];
  final List<double> bounds = <double>[];
  int nodeCount = 0;

  void _cut() {
    segments.add(_text.toString());
    _text.clear();
  }

  String finish() {
    _cut();
    return segments.join();
  }

  void writeRoot(_Node root, double ratio, bool truncated) {
    _node(root, isRoot: true, ratio: ratio, truncated: truncated);
  }

  void _node(
    _Node n, {
    bool isRoot = false,
    double ratio = 1,
    bool truncated = false,
  }) {
    final int id = nodeCount++;
    _text
      ..write('{"id":"')
      ..write(id)
      ..write('","class_name":')
      ..write(jsonEncode(n.className));
    final String? base = n.baseClassName;
    if (base != null) _text.write(',"base_class_name":${jsonEncode(base)}');
    final options = <String>[];
    if (isRoot) {
      // The age is native's: it knows when the snapshot arrived.
      _text.write(',"options":{"age_ms":');
      _cut();
      _text.write(',"device_pixel_ratio":$ratio');
      if (obfuscated) _text.write(',"obfuscated":true');
      if (truncated) _text.write(',"truncated":true');
      _text.write('}');
    } else {
      if (n.secure) options.add('"secure":true');
      if (n.clickable) options.add('"clickable":true');
      final double? alpha = n.alpha;
      if (alpha != null && alpha.isFinite) options.add('"alpha":$alpha');
      final String? kind = n.contentKind;
      if (kind != null) options.add('"content_kind":"$kind"');
      if (options.isNotEmpty) {
        _text.write(',"options":{${options.join(',')}}');
      }
    }
    _text.write(',"bounds":');
    _cut();
    final Rect r = n.rect!;
    bounds.addAll(<double>[r.left, r.top, r.right, r.bottom]);
    if (n.truncated && !isRoot) _text.write(',"truncated":true');
    if (n.children.isNotEmpty) {
      _text.write(',"subitems":[');
      var first = true;
      for (final _Node c in n.children) {
        if (!first) _text.write(',');
        first = false;
        _node(c);
      }
      _text.write(']');
    }
    _text.write('}');
  }
}
