// swift-tools-version: 5.9
//
// Test-only package for the Objective-C wrapper target. It is NOT part of the
// plugin: Flutter never sees it. It exists because the plugin's own package
// cannot host a test target: its Swift target imports Flutter, which only the
// Flutter tool can supply, so `xcodebuild test` on it fails to build.
// `Sources/BugseeFlutterWrapper` is a symlink to the plugin's real sources, so the
// tests run against exactly the shipped code.
//
// Run (simulator, no Xcode UI):
//   cd ios/wrapper_tests && xcodebuild test -scheme bugsee_flutter_wrapper_tests \
//     -destination 'platform=iOS Simulator,name=<an installed iPhone>'
//
// The Bugsee version is a literal because a manifest cannot read
// native-versions.json; test/native_versions_test.dart asserts it matches.

import PackageDescription

let package = Package(
    name: "bugsee_flutter_wrapper_tests",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "BugseeFlutterWrapper", targets: ["BugseeFlutterWrapper"])
    ],
    dependencies: [
        .package(url: "https://github.com/bugsee/spm", exact: "7.0.0")
    ],
    targets: [
        .target(
            name: "BugseeFlutterWrapper",
            dependencies: [
                .product(name: "Bugsee", package: "spm")
            ],
            path: "Sources/BugseeFlutterWrapper"
        ),
        .testTarget(
            name: "BugseeFlutterWrapperTests",
            dependencies: [
                "BugseeFlutterWrapper",
                .product(name: "Bugsee", package: "spm")
            ],
            path: "Tests/BugseeFlutterWrapperTests"
        )
    ]
)
