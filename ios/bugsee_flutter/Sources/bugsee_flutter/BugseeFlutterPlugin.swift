import BugseeFlutterWrapper
import Flutter

/// The Dart <-> native bridge. Registration of the wrapper is not done here: the
/// `BugseeFlutterWrapper` Objective-C target registers it at image load
/// (`+load`), before `main`. Registering here would be too late for a host that
/// launches Bugsee natively in `didFinishLaunchingWithOptions`: with
/// `FlutterImplicitEngineDelegate` plugins register only when the engine is
/// created, after that method. This class only serves Dart once Dart asks.
///
/// Internal: the public API is `lib/bugsee_flutter.dart`; this is its native end.
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

  // Report handlers (workbook Part 7). One owner token per engine identifies its Dart isolate
  // in the process-wide pipeline.
  private var reportOwner: Any?

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
    // No phase is registered until Dart says so (`setReportHandlerPhases`).
    let dart = BugseeBridgeFlutterApi(binaryMessenger: messenger)
    reportOwner = BGSFlutterReportHandlerPipeline.shared().attachSink { request, unreachable in
      // On the main queue (the pipeline posts it there). Never waits for the reply: the SDK's
      // completion runs when Dart completes the handle, when the deadline passes, or when this
      // call fails (Dart not listening).
      let message = ReportHandlerRequestMessage(
        handle: request.handle, deliveryId: request.deliveryId, after: request.after,
        reportId: request.reportId, type: request.type, deadlineMs: request.deadlineMs)
      Task { @MainActor in
        do {
          try await dart.onReportHandlerRequest(request: message)
        } catch {
          // No Dart handler (hot restart, teardown): answer for it, now.
          unreachable()
        }
      }
    }
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
    // Completes what was handed to this engine's Dart: nothing else knows those handles.
    if let owner = reportOwner {
      BGSFlutterReportHandlerPipeline.shared().detachOwner(owner)
      reportOwner = nil
    }
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
    var views: [NSNumber: BGSFlutterSecureViewRects] = [:]
    for view in state.views {
      views[NSNumber(value: view.viewId)] = BGSFlutterSecureViewRects(
        ratio: view.devicePixelRatio,
        rects: view.rectangles.withUnsafeBufferPointer { Data(buffer: $0) })
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

  // MARK: Launch, stop, status (workbook Part 8; see BGSFlutterLaunchOps)

  func launch(token: String, options: [String: Any]) async throws -> LaunchOutcomeMessage {
    try await withCheckedThrowingContinuation { continuation in
      // The SDK is launched on the main thread; a Pigeon handler may arrive on another.
      DispatchQueue.main.async {
        BGSFlutterLaunchOps.launch(with: BGSFlutterRealBugsee(), token: token, options: options) {
          outcome, reason, error in
          if let outcome = outcome {
            continuation.resume(returning: LaunchOutcomeMessage(outcome: outcome, reason: reason))
          } else {
            continuation.resume(throwing: launchError(error))
          }
        }
      }
    }
  }

  func stop() async throws {
    // Synchronously, before the hop to the main queue: see `beginStop`.
    BGSFlutterLaunchOps.beginStop()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.main.async {
        BGSFlutterLaunchOps.stop(with: BGSFlutterRealBugsee()) { error in
          if let error = error {
            continuation.resume(throwing: launchError(error))
          } else {
            continuation.resume()
          }
        }
      }
    }
  }

  func status() throws -> String {
    BGSFlutterRealBugsee().statusName()
  }

  func launchOptions(hostOnly: Bool) throws -> [String: Any] {
    BGSFlutterLaunchOps.reportedOptions(
      fromSdk: BGSFlutterRealBugsee().launchOptionsHostOnly(hostOnly))
  }

  // MARK: Report handlers

  func resetReportHandlers() throws {
    if let owner = reportOwner {
      BGSFlutterReportHandlerPipeline.shared().resetOwner(owner)
    }
  }

  func setReportHandlerPhases(before: Bool, after: Bool) throws {
    if let owner = reportOwner {
      BGSFlutterReportHandlerPipeline.shared().setPhasesForOwner(owner, before: before, after: after)
    }
  }

  func completeReportHandler(handle: String) throws {
    _ = BGSFlutterReportHandlerPipeline.shared().completeHandle(handle)
  }

  func reportRead(handle: String) throws -> ReportSnapshotMessage? {
    guard let report = BGSFlutterReportHandlerPipeline.shared().report(forHandle: handle) else {
      return nil
    }
    let s = BGSFlutterReportOps.readReport(report)
    return ReportSnapshotMessage(
      id: s.reportId, type: s.type, summary: s.summary, reportDescription: s.reportDescription,
      email: s.email, severity: s.severity?.int64Value, labels: s.labels,
      attributes: s.attributes)
  }

  func reportSetSummary(handle: String, value: String?) throws -> Bool {
    try edit(handle) { report, _ in
      BGSFlutterReportOps.setSummary(value, onReport: report)
      return true
    }
  }

  func reportSetDescription(handle: String, value: String?) throws -> Bool {
    try edit(handle) { report, _ in
      BGSFlutterReportOps.setDescription(value, onReport: report)
      return true
    }
  }

  func reportSetEmail(handle: String, value: String?) throws -> Bool {
    try edit(handle) { report, _ in
      BGSFlutterReportOps.setEmail(value, onReport: report)
      return true
    }
  }

  func reportSetSeverity(handle: String, severity: Int64) throws -> Bool {
    try edit(handle) { report, error in
      attempt(error) { try BGSFlutterReportOps.setSeverity(severity, onReport: report) }
    }
  }

  func reportReplaceLabels(handle: String, labels: [String]) throws -> Bool {
    try edit(handle) { report, error in
      attempt(error) { try BGSFlutterReportOps.replaceLabels(labels, onReport: report) }
    }
  }

  func reportAddLabels(handle: String, labels: [String]) throws -> Bool {
    try edit(handle) { report, error in
      attempt(error) { try BGSFlutterReportOps.addLabels(labels, onReport: report) }
    }
  }

  func reportClearLabels(handle: String) throws -> Bool {
    try edit(handle) { report, _ in
      BGSFlutterReportOps.clearLabels(onReport: report)
      return true
    }
  }

  func reportSetAttribute(handle: String, name: String, value: Any) throws -> Bool {
    try edit(handle) { report, error in
      attempt(error) { try BGSFlutterReportOps.setAttribute(value, name: name, onReport: report) }
    }
  }

  func reportRemoveAttribute(handle: String, name: String) throws -> Bool {
    try edit(handle) { report, _ in
      BGSFlutterReportOps.removeAttribute(name, onReport: report)
      return true
    }
  }

  func reportClearAttributes(handle: String) throws -> Bool {
    try edit(handle) { report, _ in
      BGSFlutterReportOps.clearAttributes(onReport: report)
      return true
    }
  }

  /// false: the handle is not live, nothing changed. An unusable argument is an error reply.
  private func edit(_ handle: String, _ change: @escaping (Any, NSErrorPointer) -> Bool) throws
    -> Bool
  {
    var error: NSError?
    switch BGSFlutterReportHandlerPipeline.shared().editHandle(handle, edit: change, error: &error) {
    case .applied: return true
    case .notLive: return false
    case .refused:
      throw PigeonError(
        code: "invalid-argument", message: error?.localizedDescription ?? "invalid argument",
        details: nil)
    @unknown default: return false
    }
  }
}

/// A launch or stop that threw crosses as a PlatformException `launch-failed` (never the token or
/// the options: the message is the exception's name and reason).
private func launchError(_ error: Error?) -> PigeonError {
  PigeonError(
    code: BGSFlutterLaunchOps.errorCode,
    message: error?.localizedDescription ?? "the Bugsee SDK threw", details: nil)
}

/// The ObjC operations throw (`NSError **`); the pipeline's edit block reports through a pointer.
private func attempt(_ error: NSErrorPointer, _ body: () throws -> Void) -> Bool {
  do {
    try body()
    return true
  } catch let thrown as NSError {
    error?.pointee = thrown
    return false
  }
}
