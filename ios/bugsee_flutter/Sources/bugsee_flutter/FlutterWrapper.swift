import Bugsee
import Foundation

/// The Flutter wrapper registered with the SDK.
///
/// Identity is real (workbook Part 3). Everything else is a deliberately inert
/// stub until Phase 3 gives it behaviour: data requests are answered with nil,
/// lifecycle events are dropped, no secure rectangles are contributed, and
/// report handlers complete immediately. None of it throws.
final class FlutterWrapper: NSObject, BugseeWrapper {
  static let unknown = "unknown"

  let wrapperType: String
  let wrapperVersion: String
  let wrapperBuild: String?
  let context: [String: String]?

  /// The identity knowable before Dart exists: type and version only.
  static func atProcessStart() -> FlutterWrapper {
    return FlutterWrapper(
      type: WrapperIdentity.type, version: WrapperIdentity.version, build: nil, context: nil)
  }

  /// A missing or empty type/version becomes "unknown" (an empty version reads
  /// as "this wrapper has no version"); context entries that are not
  /// string-to-string are dropped, not stringified.
  init(type: Any?, version: Any?, build: Any?, context: Any?) {
    func stringOr(_ value: Any?, _ fallback: String) -> String {
      if let s = value as? String, !s.isEmpty { return s }
      return fallback
    }
    wrapperType = stringOr(type, FlutterWrapper.unknown)
    wrapperVersion = stringOr(version, FlutterWrapper.unknown)
    wrapperBuild = build as? String
    var cleaned: [String: String] = [:]
    if let raw = context as? [AnyHashable: Any] {
      for (key, value) in raw {
        if let k = key as? String, let v = value as? String { cleaned[k] = v }
      }
    }
    self.context = cleaned
    super.init()
  }

  func requestData(withType dataType: String, callback: BGSDataRequestResultCallback) {
    callback.onResult(nil)
  }

  func onLifecycleEvent(_ eventType: String, data: Any?) {}

  func secureRectangles(forDisplay display: Int) -> Data? {
    // [version, count] as int32: no rectangles, constant valid version.
    var ints: [Int32] = [1, 0]
    return Data(bytes: &ints, count: ints.count * MemoryLayout<Int32>.size)
  }

  func on(
    beforeReportCreated report: BGSReportContract, isTerminating: Bool,
    completion: @escaping () -> Void
  ) {
    completion()
  }

  func on(
    afterReportCreated report: BGSReportContract, isTerminating: Bool,
    completion: @escaping () -> Void
  ) {
    completion()
  }
}
