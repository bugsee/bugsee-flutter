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
  // Events the hub handed to the sink that have not been sent to Dart yet. Touched on
  // the main thread only (the hub's delivery queue, and the main-actor pump).
  private var pending: [BGSFlutterLifecycleEvent] = []
  private var pumpTask: Task<Void, Never>?
  private var wake: AsyncStream<Void>.Continuation?

  // Secure rectangles. One owner id per engine identifies its Dart isolate in the
  // process-wide store.
  private static let ownerLock = NSLock()
  private static var lastOwner: Int64 = 0
  private static func newOwner() -> Int64 {
    ownerLock.lock()
    defer { ownerLock.unlock() }
    lastOwner += 1
    return lastOwner
  }
  private static let environment = BGSFlutterUIKitEnvironment()
  private let owner: Int64
  private var tracker: BGSFlutterSecurePlacementTracker?

  init(messenger: FlutterBinaryMessenger, registrar: FlutterPluginRegistrar) {
    self.messenger = messenger
    self.owner = BugseeFlutterPlugin.newOwner()
    super.init()
    let store = BGSFlutterSecureRectangleStore.shared()
    store.setEnvironment(BugseeFlutterPlugin.environment)
    // The registrar is weak: it retains this instance (published below).
    tracker = BGSFlutterSecurePlacementTracker(
      owner: owner, store: store, environment: BugseeFlutterPlugin.environment,
      viewProvider: { [weak registrar] in registrar?.viewController?.view })
    tracker?.refresh()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Idempotent. Also references the wrapper target so the linker keeps its
    // `+load` out of the static archive.
    BGSFlutterWrapperRegistrar.ensureRegistered()

    let instance = BugseeFlutterPlugin(messenger: registrar.messenger(), registrar: registrar)
    BugseeBridgeHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    // Keeps the instance alive and gets `detachFromEngine(for:)`.
    registrar.publish(instance)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    BugseeBridgeHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    stopForwarding()
    tracker?.detach()
    tracker = nil
    // The engine's UI is gone; there is nothing left of it to hide.
    BGSFlutterSecureRectangleStore.shared().dropOwner(owner)
  }

  func attachLifecycle() throws {
    stopForwarding()
    let dart = BugseeBridgeFlutterApi(binaryMessenger: messenger)
    // Pigeon's Swift Flutter API is `async`. One consumer awaits each send before the
    // next, so events reach Dart strictly in the order the hub delivered them
    // (separate `Task`s per event would not promise that). The queue is `pending`, not
    // the stream: the stream only wakes the consumer, so a teardown can take back
    // exactly what was not sent (see `stopForwarding`).
    var signal: AsyncStream<Void>.Continuation!
    let wakeups = AsyncStream<Void> { signal = $0 }
    wake = signal
    pumpTask = Task { @MainActor [weak self] in
      for await _ in wakeups {
        while !Task.isCancelled, let self = self, !self.pending.isEmpty {
          let event = self.pending.removeFirst()
          do {
            try await dart.onLifecycleEvent(
              event: LifecycleEventMessage(
                name: event.name, reportId: event.reportId, data: event.data))
          } catch {
            // Dart not listening (hot restart, teardown): the event is dropped; see
            // the delivery limit in PLAN.md. The status is also kept Dart-side.
          }
        }
      }
    }
    // The hub invokes the sink on the main queue, in order.
    sinkToken = BGSFlutterLifecycleHub.shared().attachSink { [weak self] event in
      self?.pending.append(event)
      self?.wake?.yield()
    }
  }

  /// Stops the pump and gives back what it had not sent: the hub puts those events at the
  /// front of its buffer (when no other engine is attached), so a restarted or new
  /// receiver gets them first and in order rather than losing them or racing an old pump.
  private func stopForwarding() {
    pumpTask?.cancel()
    pumpTask = nil
    wake?.finish()
    wake = nil
    let unsent = pending
    pending = []
    if let token = sinkToken {
      BGSFlutterLifecycleHub.shared().detach(token, undelivered: unsent)
      sinkToken = nil
    }
  }

  func setWrapperIdentity(identity: WrapperIdentityMessage) throws {
    _ = BGSFlutterWrapperRegistrar.replace(
      withType: identity.type,
      version: identity.version,
      build: identity.build,
      context: identity.context
    )
  }

  func setSecureRectangles(state: SecureRectanglesMessage) throws -> Bool {
    var views: [NSNumber: Data] = [:]
    for view in state.views {
      views[NSNumber(value: view.viewId)] = view.rectangles.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    let applied = BGSFlutterSecureRectangleStore.shared().publish(
      forOwner: owner, epoch: state.epoch, sequence: state.sequence, views: views)
    if applied {
      // Dart just measured, so look at where the view is now rather than trusting what an
      // earlier read saw.
      tracker?.refresh()
    }
    return applied
  }
}
