import BugseeFlutterWrapper
import Flutter

/// The Dart <-> native bridge. Registration of the wrapper is not done here: the
/// `BugseeFlutterWrapper` Objective-C target registers it at image load
/// (`+load`), before `main`. Registering here would be too late for a host that
/// launches Bugsee natively in `didFinishLaunchingWithOptions`: with
/// `FlutterImplicitEngineDelegate` plugins register only when the engine is
/// created, after that method. This class only serves Dart once Dart asks.
///
/// Internal: no public API yet (Phase 4).
public class BugseeFlutterPlugin: NSObject, FlutterPlugin, BugseeBridgeHostApi {
  private let messenger: FlutterBinaryMessenger
  private var sinkToken: Any?
  private var pump: AsyncStream<LifecycleEventMessage>.Continuation?

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Idempotent. Also references the wrapper target so the linker keeps its
    // `+load` out of the static archive.
    BGSFlutterWrapperRegistrar.ensureRegistered()

    let instance = BugseeFlutterPlugin(messenger: registrar.messenger())
    BugseeBridgeHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    // Keeps the instance alive and gets `detachFromEngine(for:)`.
    registrar.publish(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    BugseeBridgeHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    stopForwarding()
  }

  func attachLifecycle() throws {
    stopForwarding()
    let dart = BugseeBridgeFlutterApi(binaryMessenger: messenger)
    // Pigeon's Swift Flutter API is `async`. One consumer awaits each send before
    // the next, so events reach Dart strictly in the order the hub delivered them
    // (separate `Task`s per event would not promise that).
    var continuation: AsyncStream<LifecycleEventMessage>.Continuation!
    let stream = AsyncStream<LifecycleEventMessage> { continuation = $0 }
    pump = continuation
    Task { @MainActor in
      for await message in stream {
        do {
          try await dart.onLifecycleEvent(event: message)
        } catch {
          // Dart not listening (hot restart, teardown): nothing to do; the
          // status is also kept Dart-side.
        }
      }
    }
    // The hub invokes the sink on the main queue, in order.
    sinkToken = BGSFlutterLifecycleHub.shared().attachSink { event in
      continuation.yield(
        LifecycleEventMessage(name: event.name, reportId: event.reportId, data: event.data))
    }
  }

  private func stopForwarding() {
    if let token = sinkToken {
      BGSFlutterLifecycleHub.shared().detach(token)
      sinkToken = nil
    }
    pump?.finish()
    pump = nil
  }

  func setWrapperIdentity(identity: WrapperIdentityMessage) throws {
    _ = BGSFlutterWrapperRegistrar.replace(
      withType: identity.type,
      version: identity.version,
      build: identity.build,
      context: identity.context
    )
  }
}
