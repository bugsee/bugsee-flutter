import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerCrashLab(engineBridge.pluginRegistry)
  }

  /// The crash lab of the device verification app (example/lib/crash_lab.dart): ways to take this
  /// process down from native code, which the Dart side cannot do itself. Example code only. Each
  /// one is raised from its own dispatch or thread: a throw inside the handler would not be the
  /// uncaught exception the SDK has to catch.
  private func registerCrashLab(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "VerifyCrashLab") else { return }
    let channel = FlutterMethodChannel(
      name: "verify/crashlab", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "objcMain":
        DispatchQueue.main.async {
          NSException(
            name: NSExceptionName("VerifyException"), reason: "verify-objc-main", userInfo: nil
          ).raise()
        }
        result(nil)
      case "objcThread":
        Thread.detachNewThread {
          NSException(
            name: NSExceptionName("VerifyException"), reason: "verify-objc-thread", userInfo: nil
          ).raise()
        }
        result(nil)
      case "swiftTrap":
        DispatchQueue.main.async { fatalError("verify-swift-trap") }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
