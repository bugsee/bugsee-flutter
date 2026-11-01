// swift-tools-version: 5.9
//
// Test-only package for the Objective-C wrapper target of bugsee_flutter_feedback. It is NOT part
// of the plugin: Flutter never sees it. It exists because the plugin's own package cannot host a
// test target: its Swift target imports Flutter, which only the Flutter tool can supply, so
// `xcodebuild test` on it fails to build. `Sources/BugseeFlutterFeedbackWrapper` is a symlink to the
// plugin's real sources, so the tests run against exactly the shipped code. (The same arrangement
// as ios/wrapper_tests of the core plugin.)
//
// Run (simulator, no Xcode UI):
//   cd packages/bugsee_flutter_feedback/ios/feedback_wrapper_tests && xcodebuild test \
//     -collect-test-diagnostics never -scheme bugsee_flutter_feedback_wrapper_tests \
//     -destination 'platform=iOS Simulator,name=<an installed iPhone>'
//
// The versions are literals because a manifest cannot read native-versions.json;
// test/feedback_package_drift_test.dart asserts they match it.

import PackageDescription

let package = Package(
    name: "bugsee_flutter_feedback_wrapper_tests",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "BugseeFlutterFeedbackWrapper", targets: ["BugseeFlutterFeedbackWrapper"])
    ],
    dependencies: [
        .package(url: "https://github.com/bugsee/spm", exact: "7.0.0"),
        .package(url: "https://github.com/bugsee/feedback-spm", exact: "7.0.0")
    ],
    targets: [
        .target(
            name: "BugseeFlutterFeedbackWrapper",
            dependencies: [
                .product(name: "Bugsee", package: "spm"),
                .product(name: "BugseeFeedback", package: "feedback-spm")
            ],
            path: "Sources/BugseeFlutterFeedbackWrapper"
        ),
        .testTarget(
            name: "BugseeFlutterFeedbackWrapperTests",
            dependencies: [
                "BugseeFlutterFeedbackWrapper",
                .product(name: "Bugsee", package: "spm"),
                .product(name: "BugseeFeedback", package: "feedback-spm")
            ],
            path: "Tests/BugseeFlutterFeedbackWrapperTests"
        )
    ]
)
