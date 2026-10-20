import Flutter
import UIKit
import XCTest

@testable import bugsee_flutter

// Phase 1 skeleton: the plugin has no method channel yet (Phases 2-3), so the
// only check is a compile-time one: the plugin must still conform to FlutterPlugin.
// There is deliberately no runtime assertion.
class RunnerTests: XCTestCase {

  func testPluginCompilesAsFlutterPlugin() {
    let _: FlutterPlugin = BugseeFlutterPlugin()
  }

}
