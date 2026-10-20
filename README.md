# bugsee_flutter

> **Status: Phase 1 foundation of the 7.x rewrite. This is not a usable SDK yet.**
> The Bugsee launch API and SDK behaviour are not implemented in this revision.
> Existing users should stay on the latest published release until the migration
> guide is available.

## iOS: Swift Package Manager

The iOS side is distributed through Swift Package Manager only (Bugsee publishes
no CocoaPods pod, and this plugin has no podspec). On Flutter versions where
SwiftPM is not enabled by default, run this once before `flutter pub get`:

```
flutter config --enable-swift-package-manager
```

See [PLAN.md](PLAN.md) for the implementation plan.
