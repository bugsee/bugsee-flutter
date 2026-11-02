// swift-tools-version: 5.9
//
// iOS is delivered through Swift Package Manager only (Bugsee publishes no pod), like the core
// plugin. The versions below are literals because a manifest cannot read native-versions.json;
// test/feedback_package_drift_test.dart (repository root) asserts they match it, and match the
// core plugin's pin of the same `bugsee/spm` package. The feedback add-on pins the core SDK
// exactly itself, so the two exact pins here are one version or resolution fails loudly.

import PackageDescription

let package = Package(
    name: "bugsee_flutter_feedback",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "bugsee-flutter-feedback", targets: ["bugsee_flutter_feedback"])
    ],
    dependencies: [
        .package(url: "https://github.com/bugsee/spm", exact: "7.0.0"),
        .package(url: "https://github.com/bugsee/feedback-spm", exact: "7.0.0")
    ],
    targets: [
        // Objective-C so `+load` can register the add-on at image load, before the SDK can be
        // launched, and so the add-on is REFERENCED by this plugin (see BGSFlutterFeedbackRegistrar:
        // the add-on's own `+load`-only registration shim can be dead-stripped from a static link).
        .target(
            name: "BugseeFlutterFeedbackWrapper",
            dependencies: [
                .product(name: "Bugsee", package: "spm"),
                .product(name: "BugseeFeedback", package: "feedback-spm")
            ],
            path: "Sources/bugsee_flutter_feedback_wrapper"
        ),
        .target(
            name: "bugsee_flutter_feedback",
            dependencies: [
                "BugseeFlutterFeedbackWrapper"
            ]
        )
    ]
)
