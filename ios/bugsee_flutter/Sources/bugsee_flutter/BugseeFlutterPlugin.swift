import BugseeFlutterWrapper
import Flutter

/// Deliberately thin. The wrapper and its registration live in the
/// `BugseeFlutterWrapper` Objective-C target, which registers at image load
/// (`+load`), before `main`. Registering here would be too late for a host that
/// launches Bugsee natively in `didFinishLaunchingWithOptions`: with
/// `FlutterImplicitEngineDelegate` plugins register only when the engine is
/// created, after that method.
public class BugseeFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // Idempotent. Also references the wrapper target so the linker keeps its
    // `+load` out of the static archive.
    BGSFlutterWrapperRegistrar.ensureRegistered()
  }
}
