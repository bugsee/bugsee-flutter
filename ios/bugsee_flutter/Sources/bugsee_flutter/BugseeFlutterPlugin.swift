import Bugsee
import Flutter

public class BugseeFlutterPlugin: NSObject, FlutterPlugin {
  /// Held for the process lifetime; the SDK's own reference is not ours to rely on.
  private static var wrapper: FlutterWrapper?

  /// Flutter calls this while the engine's plugins are registered, during
  /// application launch and before any Dart runs, so before any
  /// `launchWithToken:`. Registration is a plain singleton write with no launch
  /// dependency (workbook 2.3). Idempotent: a second engine registers the same
  /// wrapper again, which the SDK treats as a no-op.
  public static func register(with registrar: FlutterPluginRegistrar) {
    registerWrapper()
  }

  static func registerWrapper() {
    if wrapper == nil {
      wrapper = FlutterWrapper.atProcessStart()
    }
    Bugsee.setWrapper(wrapper)
    NSLog("[BugseeFlutter] wrapper registered type=%@ version=%@", WrapperIdentity.type, WrapperIdentity.version)
  }
}
