import Flutter
import UIKit
import XCTest

@testable import bugsee_flutter

// Phase 1 skeleton: the plugin has no method channel yet (Phases 2-3), so the
// only thing to assert is that it still conforms to FlutterPlugin.
class RunnerTests: XCTestCase {

  func testPluginConformsToFlutterPlugin() {
    let plugin: FlutterPlugin = BugseeFlutterPlugin()
    XCTAssertNotNil(plugin)
  }

}
