import BugseeFlutterFeedbackWrapper
import Flutter

/// The Dart <-> native bridge of the feedback package. Registration of the add-on with the SDK is
/// not done here: the `BugseeFlutterFeedbackWrapper` Objective-C target registers it at image
/// load (`+load`), and `register(with:)` references it so the linker keeps that `+load` and the
/// add-on's Swift module out of a static link's dead stripping. This class only serves Dart once
/// Dart asks.
///
/// Internal: the public API is `lib/bugsee_flutter_feedback.dart`; this is its native end.
public class BugseeFlutterFeedbackPlugin: NSObject, FlutterPlugin, FeedbackHostApi {
  private let ops: BGSFlutterFeedbackOps
  /// Set when this plugin had to register the add-on itself (see `registeredBySafetyNet`).
  private static var safetyNetUsed = false

  init(messenger: FlutterBinaryMessenger) {
    let dart = FeedbackFlutterApi(binaryMessenger: messenger)
    // The ops deliver on the main thread, the platform thread. A failed send (`try?`) means Dart is not
    // listening (a hot restart in progress): nobody is owed the event.
    ops = BGSFlutterFeedbackOps(
      sdk: BGSFlutterRealFeedback(),
      received: { messages in
        Task { @MainActor in try? await dart.onMessagesReceived(messages: messages) }
      },
      sent: { message in
        Task { @MainActor in try? await dart.onMessageSent(message: message) }
      })
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Idempotent. Also references the wrapper target so the linker keeps its `+load`.
    BGSFlutterFeedbackRegistrar.ensureRegistered()
    // Says in the log which path registered it, and covers a failed `+load` registration.
    if BGSFlutterRealFeedback().registerIfMissing() {
      safetyNetUsed = true
    }

    let instance = BugseeFlutterFeedbackPlugin(messenger: registrar.messenger())
    FeedbackHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    // Keeps the instance alive and gets `detachFromEngine(for:)`.
    registrar.publish(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    FeedbackHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    ops.detach()
  }

  // MARK: FeedbackHostApi

  func attach() throws -> Bool {
    ops.attach()
  }

  func registeredBySafetyNet() throws -> Bool {
    BugseeFlutterFeedbackPlugin.safetyNetUsed
  }

  func show() throws {
    try check(ops.show())
  }

  func setGreeting(greeting: String?) throws {
    try check(ops.setGreeting(greeting))
  }

  func setListenerEnabled(enabled: Bool) throws {
    try check(ops.setListenerEnabled(enabled))
  }

  private func check(_ result: BGSFlutterFeedbackResult) throws {
    if let code = result.errorCode {
      throw PigeonError(code: code, message: result.errorMessage ?? code, details: nil)
    }
  }
}
