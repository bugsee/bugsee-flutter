// Definition of the internal Dart <-> native bridge. Generated outputs are
// committed; regenerate with `dart scripts/generate_pigeon.dart` (and
// `--check` verifies the committed files are current). Nothing here is public
// API: the generated Dart is not exported from package:bugsee_flutter.
//
// Run from this directory's package (pigeons/pubspec.yaml pins pigeon, which
// cannot be a dependency of the plugin itself: it needs a newer `meta` than
// Flutter 3.41.0 ships).
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: '../lib/src/bridge/messages.g.dart',
    dartOptions: DartOptions(),
    javaOut: '../android/src/main/java/com/bugsee/flutter/Messages.java',
    javaOptions: JavaOptions(
      package: 'com.bugsee.flutter',
      className: 'Messages',
    ),
    swiftOut: '../ios/bugsee_flutter/Sources/bugsee_flutter/Messages.g.swift',
    dartPackageName: 'bugsee_flutter',
  ),
)
/// One SDK lifecycle event, as the native side hands it to Dart.
///
/// The `com.bugsee.lifecycle.` prefix is already stripped (once, natively). A
/// name this version does not know is carried unchanged.
class LifecycleEventMessage {
  LifecycleEventMessage({required this.name, this.reportId, this.data});

  String name;

  /// Set only for the events that carry a report id; carried, not interpreted.
  String? reportId;

  /// String-to-string payload entries that crossed cleanly; null when none.
  Map<String, String>? data;
}

/// The wrapper identity the Dart runtime sends once it is up (workbook 2.4.2).
class WrapperIdentityMessage {
  WrapperIdentityMessage({
    required this.type,
    required this.version,
    this.build,
    required this.context,
  });

  String type;
  String version;
  String? build;
  Map<String, String> context;
}

/// The rectangles of one Flutter view, flat `[l, t, r, b, l, t, r, b, ...]`, in
/// the view's own LOGICAL pixels (Flutter logical pixels: iOS points, Android
/// dp), origin at the view's top-left, right/bottom exclusive. Native converts
/// them to the SDK's unit and places the view on the screen.
class SecureViewRectanglesMessage {
  SecureViewRectanglesMessage({
    required this.viewId,
    required this.devicePixelRatio,
    required this.rectangles,
  });

  /// `FlutterView.viewId`. Mobile engines have only the implicit view (0).
  int viewId;

  /// `FlutterView.devicePixelRatio` the rectangles were measured with. Native
  /// scales by THIS, not by what the display reports now: a density change is
  /// applied natively before Dart has laid out again, so rectangles measured at
  /// the old ratio must not be scaled by the new one. When the two differ,
  /// native covers the whole display until Dart republishes.
  double devicePixelRatio;
  List<double> rectangles;
}

/// The COMPLETE set of secure rectangles of this Dart isolate: a view that is
/// absent from [views] has none. Whole-state, not a delta, so a lost or late
/// message can never leave a rectangle behind.
///
/// Ordering: within one `epoch` native ignores a message whose `sequence` is
/// not newer than the newest it accepted. `epoch` is a random id of the Dart
/// isolate (never a clock: a clock can go backwards). A message with an epoch
/// native has not seen starts a new isolate (a hot restart; its counter restarts
/// at 1) and replaces the old one's state; a message of an epoch native has
/// already retired is a late straggler of a dead isolate and is ignored.
class SecureRectanglesMessage {
  SecureRectanglesMessage({
    required this.epoch,
    required this.sequence,
    required this.views,
  });

  int epoch;
  int sequence;
  List<SecureViewRectanglesMessage> views;
}

/// Dart calls native.
@HostApi()
abstract class BugseeBridgeHostApi {
  /// The Dart side is listening: flush what was buffered while it was not (in
  /// order) and deliver from now on.
  void attachLifecycle();

  /// Replaces the natively registered placeholder wrapper with the full
  /// identity. Never throws on malformed content: facts become "unknown".
  void setWrapperIdentity(WrapperIdentityMessage identity);

  /// Publishes the secure rectangles (see [SecureRectanglesMessage]). Never
  /// throws on content: an unusable value fails closed natively. Returns
  /// whether the message was applied (`false`: it was older than one already
  /// applied, which is not an error).
  bool setSecureRectangles(SecureRectanglesMessage state);
}

/// Native calls Dart. Always from the platform (main) thread.
@FlutterApi()
abstract class BugseeBridgeFlutterApi {
  void onLifecycleEvent(LifecycleEventMessage event);
}
