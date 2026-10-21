// swift-tools-version: 5.9
//
// iOS is delivered through Swift Package Manager only: Bugsee stopped publishing
// CocoaPods in September 2026, so there is no podspec. The Bugsee version below
// is a literal because a manifest cannot read native-versions.json; the drift
// guard in test/native_versions_test.dart asserts it matches.

import PackageDescription

let package = Package(
    name: "bugsee_flutter",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "bugsee-flutter", targets: ["bugsee_flutter"])
    ],
    dependencies: [
        .package(url: "https://github.com/bugsee/spm", exact: "7.0.0-beta7")
    ],
    targets: [
        // Objective-C so `+load` can register the wrapper at image load, before
        // any Flutter engine exists. Imports the SDK's ObjC module directly.
        .target(
            name: "BugseeFlutterWrapper",
            dependencies: [
                .product(name: "Bugsee", package: "spm")
            ],
            path: "Sources/bugsee_flutter_wrapper"
        ),
        .target(
            name: "bugsee_flutter",
            dependencies: [
                "BugseeFlutterWrapper"
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
