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
      // Its created report, if any, goes with it; another engine's does not.
      files.resetOwner(owner)
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

  // MARK: Facade (Phase 4b; see BGSFlutterFacadeOps)
  //
  // Pigeon runs these handlers on the platform (main) thread, the thread the SDK's public API
  // is used from. The plugin keeps no state for them; an SDK exception is caught in Objective-C
  // (it would crash Swift) and comes back as a failure with the bridge's code.

  private let facadeSdk = BGSFlutterRealFacade()

  func setAttribute(name: String, value: Any) throws {
    _ = try unwrap(BGSFlutterFacadeOps.setAttribute(sdk: facadeSdk, name: name, value: value))
  }

  func getAttribute(name: String) throws -> Any? {
    try unwrap(BGSFlutterFacadeOps.getAttribute(sdk: facadeSdk, name: name))
  }

  func getAllAttributes() throws -> [String: Any] {
    (try unwrap(BGSFlutterFacadeOps.getAllAttributes(sdk: facadeSdk)) as? [String: Any]) ?? [:]
  }

  func clearAttribute(name: String) throws {
    _ = try unwrap(BGSFlutterFacadeOps.clearAttribute(sdk: facadeSdk, name: name))
  }

  func clearAllAttributes() throws {
    _ = try unwrap(BGSFlutterFacadeOps.clearAllAttributes(sdk: facadeSdk))
  }

  func setUserIdentifier(identifier: String?) throws {
    _ = try unwrap(BGSFlutterFacadeOps.setUserIdentifier(sdk: facadeSdk, identifier: identifier))
  }

  func getUserIdentifier() throws -> String? {
    try unwrap(BGSFlutterFacadeOps.getUserIdentifier(sdk: facadeSdk)) as? String
  }

  func trace(name: String, value: Any) throws {
    _ = try unwrap(BGSFlutterFacadeOps.trace(sdk: facadeSdk, name: name, value: value))
  }

  func event(name: String, params: [String: Any?]?) throws {
    // A null member must arrive as null (NSNull), not be dropped.
    let converted = params?.mapValues { $0 ?? NSNull() }
    _ = try unwrap(BGSFlutterFacadeOps.event(sdk: facadeSdk, name: name, params: converted))
  }

  func addBreadcrumb(breadcrumb: BreadcrumbMessage) throws -> Bool {
    let data = breadcrumb.data?.mapValues { $0 ?? NSNull() }
    let result = BGSFlutterFacadeOps.addBreadcrumb(
      sdk: facadeSdk, category: breadcrumb.category, level: breadcrumb.level,
      message: breadcrumb.message, type: breadcrumb.type, data: data)
    return (try unwrap(result) as? NSNumber)?.boolValue ?? false
  }

  func relayNotification(
    title: String, body: String?, severity: Int64?, fields: [String]?, urgent: Bool
  ) throws {
    _ = try unwrap(
      BGSFlutterFacadeOps.relayNotification(
        sdk: facadeSdk, title: title, body: body, severity: severity.map { NSNumber(value: $0) },
        fields: fields, urgent: urgent))
  }

  func log(message: String, level: Int64) throws {
    _ = try unwrap(BGSFlutterFacadeOps.log(sdk: facadeSdk, message: message, level: level))
  }

  func startBlackout() throws {
    _ = try unwrap(BGSFlutterFacadeOps.startBlackout(sdk: facadeSdk))
  }

  func endBlackout() throws {
    _ = try unwrap(BGSFlutterFacadeOps.endBlackout(sdk: facadeSdk))
  }

  func isBlackout() throws -> Bool {
    (try unwrap(BGSFlutterFacadeOps.isBlackout(sdk: facadeSdk)) as? NSNumber)?.boolValue ?? false
  }

  func showReportDialog(
    summary: String?, description: String?, severity: Int64?, labels: [String]?
  ) throws {
    _ = try unwrap(
      BGSFlutterFacadeOps.showReportDialog(
        sdk: facadeSdk, summary: summary, description: description,
        severity: severity.map { NSNumber(value: $0) }, labels: labels))
  }

  func upload(summary: String, description: String, severity: Int64?, labels: [String]?) throws {
    _ = try unwrap(
      BGSFlutterFacadeOps.upload(
        sdk: facadeSdk, summary: summary, description: description,
        severity: severity.map { NSNumber(value: $0) }, labels: labels))
  }

  // MARK: Network capture (Phase 5b; see BGSFlutterNetworkOps)

  private let networkSdk = BGSFlutterRealNetworkSdk()

  func addNetworkEvents(events: [NetworkEventMessage]) throws -> Int64 {
    // The ObjC operations take plain dictionaries (they cannot see this module's Pigeon types).
    let dictionaries: [[String: Any]] = events.map { event in
      var d: [String: Any] = [
        "id": event.id, "stage": event.stage, "mechanism": event.mechanism,
        "method": event.method, "url": event.url, "ageMs": event.ageMs, "size": event.size,
        "statusCode": event.statusCode,
      ]
      if let v = event.headers { d["headers"] = v }
      if let v = event.body { d["body"] = v }
      if let v = event.noBodyReason { d["noBodyReason"] = v }
      if let v = event.statusText { d["statusText"] = v }
      if let v = event.errorShortMessage { d["errorShortMessage"] = v }
      if let v = event.errorDescription { d["errorDescription"] = v }
      if let v = event.redirectedFromUrl { d["redirectedFromUrl"] = v }
      return d
    }
    return Int64(BGSFlutterNetworkOps.addEvents(sdk: networkSdk, events: dictionaries))
  }

  // MARK: Log capture (Phase 5d; see BGSFlutterLogOps)

  private let logSdk = BGSFlutterRealLogSdk()

  func addLogLines(lines: [LogLineMessage]) throws -> Int64 {
    // The ObjC operations take plain dictionaries (they cannot see this module's Pigeon types).
    let dictionaries: [[String: Any]] = lines.map { line in
      var d: [String: Any] = ["message": line.message, "level": line.level]
      if let v = line.tag { d["tag"] = v }
      return d
    }
    return Int64(BGSFlutterLogOps.addLines(sdk: logSdk, lines: dictionaries))
  }

  // MARK: Exceptions (Phase 5a; see BGSFlutterExceptionOps)

  private let exceptionSdk = BGSFlutterRealExceptionSdk()

  func logException(payload: String, handled: Bool, domain: String?) async throws -> Bool {
    // On the main queue, where the SDK's public API is used (it reads UIKit state); the generated
    // async handler would otherwise run on the cooperative pool.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
      DispatchQueue.main.async {
        let result = BGSFlutterExceptionOps.log(
          sdk: self.exceptionSdk, payload: payload, handled: handled, domain: domain)
        if let code = result.errorCode {
          continuation.resume(
            throwing: PigeonError(code: code, message: result.errorMessage ?? code, details: nil))
        } else {
          continuation.resume(returning: (result.value as? NSNumber)?.boolValue ?? false)
        }
      }
    }
  }

  // MARK: Report handlers

  func resetReportHandlers() throws {
    // A new Dart isolate does not know the old one's created report: release it now.
    files.resetOwner(reportOwner ?? self)
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
      attributes: s.attributes,
      attachments: s.attachments.map { a in
        ReportAttachmentMessage(
          name: a[0] as? String, mimeType: a[1] as? String, fileName: a[2] as? String)
      },
      screenshots: s.screenshots.map { shot in
        ReportScreenshotMessage(displayId: shot[0].int64Value, annotated: shot[1].boolValue)
      })
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

  // MARK: Attachments, screenshots and createReport (Phase 6; see BGSFlutterReportFileFlow)

  private let files = BGSFlutterReportFileFlow.shared()

  /// A flow operation as an async call. The flow replies on the main queue; a code is an error
  /// reply, a value is the failure code of a file operation (`nil`: done).
  private func fileReply(_ start: (@escaping BGSFlutterFlowReply) -> Void) async throws -> String? {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
      start { value, code, message in
        if let code = code {
          continuation.resume(throwing: PigeonError(code: code, message: message ?? code, details: nil))
        } else {
          continuation.resume(returning: value as? String)
        }
      }
    }
  }

  func reportAddAttachment(handle: String, path: String, name: String, mimeType: String?, move: Bool)
    async throws -> String?
  {
    try await fileReply { reply in
      files.handlerAddFile(handle, path: path, name: name, mimeType: mimeType, move: move, reply: reply)
    }
  }

  func reportAddAttachmentBytes(
    handle: String, data: FlutterStandardTypedData, name: String, mimeType: String?
  ) async throws -> String? {
    try await fileReply { reply in
      files.handlerAddData(handle, data: data.data, name: name, mimeType: mimeType, reply: reply)
    }
  }

  func reportClearAttachments(handle: String) async throws -> String? {
    try await fileReply { reply in files.handlerClearAttachments(handle, reply: reply) }
  }

  func reportSetScreenshot(handle: String, path: String, displayId: Int64, annotated: Bool)
    async throws -> String?
  {
    try await fileReply { reply in
      files.handlerSetScreenshot(
        handle, path: path, displayId: displayId, annotated: annotated, reply: reply)
    }
  }

  func reportRemoveScreenshot(handle: String, displayId: Int64) async throws -> String? {
    try await fileReply { reply in
      files.handlerRemoveScreenshot(handle, displayId: displayId, reply: reply)
    }
  }

  func createReport(ttlMs: Int64) async throws -> String? {
    try await fileReply { reply in files.create(forOwner: reportOwner ?? self, ttlMs: ttlMs, reply: reply) }
  }

  func createdReportRead(handle: String) throws -> CreatedReportSnapshotMessage? {
    guard let s = files.readCreated(handle) else { return nil }
    return CreatedReportSnapshotMessage(
      // iOS's created report has no id and no type of its own: empty id, and `bug` (the SDK
      // creates it for an upload, which is a bug report).
      reportId: "", type: "bug", summary: s.summary, reportDescription: s.reportDescription,
      severity: s.severity?.int64Value, labels: s.labels, attributes: s.attributes,
      attachmentNames: s.attachmentNames, screenshotDisplayIds: s.screenshotDisplayIds.map { $0.int64Value })
  }

  func createdReportApply(handle: String, patch: CreatedReportPatchMessage) throws -> Bool {
    let p = BGSFlutterCreatedReportPatch()
    p.setSummary = patch.setSummary
    p.summary = patch.summary
    p.setDescription = patch.setDescription
    p.reportDescription = patch.reportDescription
    p.severity = patch.severity.map { NSNumber(value: $0) }
    p.labels = patch.labels
    p.clearAttributes = patch.clearAttributes
    p.attributes = patch.attributes
    p.removeAttributes = patch.removeAttributes
    var message: NSString?
    guard files.apply(toCreated: handle, patch: p, message: &message) else { return false }
    if let message = message {
      throw PigeonError(code: "invalid-argument", message: message as String, details: nil)
    }
    return true
  }

  func createdReportAddAttachment(handle: String, path: String, name: String, mimeType: String?)
    async throws -> String?
  {
    try await fileReply { reply in
      files.createdAddFile(handle, path: path, name: name, mimeType: mimeType, reply: reply)
    }
  }

  func createdReportAddAttachmentBytes(
    handle: String, data: FlutterStandardTypedData, name: String, mimeType: String?
  ) async throws -> String? {
    try await fileReply { reply in
      files.createdAddData(handle, data: data.data, name: name, mimeType: mimeType, reply: reply)
    }
  }

  func createdReportClearAttachments(handle: String) async throws -> String? {
    try await fileReply { reply in files.createdClearAttachments(handle, reply: reply) }
  }

  func createdReportSetScreenshot(handle: String, path: String, annotated: Bool) async throws
    -> String?
  {
    try await fileReply { reply in
      files.createdSetScreenshot(handle, path: path, annotated: annotated, reply: reply)
    }
  }

  func createdReportUpload(handle: String) async throws -> Bool {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
      files.uploadCreated(handle) { value, code, message in
        if let code = code {
          continuation.resume(throwing: PigeonError(code: code, message: message ?? code, details: nil))
        } else {
          continuation.resume(returning: (value as? NSNumber)?.boolValue ?? false)
        }
      }
    }
  }

  func createdReportDiscard(handle: String) throws {
    files.discardCreated(handle)
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

/// A failed facade operation crosses as a PlatformException carrying the bridge's code.
private func unwrap(_ result: BGSFlutterFacadeResult) throws -> Any? {
  if let code = result.errorCode {
    throw PigeonError(code: code, message: result.errorMessage ?? code, details: nil)
  }
  return result.value
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
