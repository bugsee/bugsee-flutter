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

/// Dart calls native.
@HostApi()
abstract class BugseeBridgeHostApi {
  /// The Dart side is listening: flush what was buffered while it was not (in
  /// order) and deliver from now on.
  void attachLifecycle();

  /// Replaces the natively registered placeholder wrapper with the full
  /// identity. Never throws on malformed content: facts become "unknown".
  void setWrapperIdentity(WrapperIdentityMessage identity);
}

/// Native calls Dart. Always from the platform (main) thread.
@FlutterApi()
abstract class BugseeBridgeFlutterApi {
  void onLifecycleEvent(LifecycleEventMessage event);
}
