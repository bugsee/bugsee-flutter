#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Builds the buffer the 7.x iOS SDK pulls through `-[BGSBugseeWrapper secureRectanglesForDisplay:]`:
/// packed `int32_t` `[version, count, left, top, right, bottom, ...]` in the SCREEN's points,
/// origin top-left, edges rounded outward, `right` and `bottom` exclusive (`BGSContracts.h`).
///
/// It takes the payload exactly as the Dart side sends it (`lib/src/ui.dart`, `_addElementBounds`):
/// FIVE ints per secure widget, `[id, x, y, width, height, ...]`. The id is the element's
/// `hashCode` and is not used. `x, y, width, height` are `localToGlobal` values relative to the
/// Flutter view, in its logical pixels, which on iOS are points: `_updateDevicePixelRatio` forces
/// the ratio to 1 there. This is the same payload, in the same units, that the 6.x SDK reads in
/// `+[Bugsee setInternalSecureRectangles:]` with a 20-byte stride.
///
/// The 7.x SDK composes every window of the app at its place on the screen (iPad Stage Manager and
/// Split View, iPhone Duo side by side), so each rectangle is moved by where the Flutter view starts
/// on the screen (`BGSFlutterViewOriginOnScreen`). Unmoved, a Flutter view away from the screen's
/// origin would be recorded in the clear, with the black that far up and left of it.
///
/// The version is always 0 (`BGSSecureRectanglesVersionUnknown`), so the SDK compares the
/// rectangles itself. The buffer depends on the origin as well as on the Dart payload, and a window
/// moved without being resized (a Stage Manager drag) renders no Flutter frame, so Dart publishes
/// nothing new; a version derived from Dart's publishes would then be stale, which the contract
/// calls a privacy defect.
///
/// Not wired yet: the plugin still talks to the 6.x SDK. Call this from the wrapper's
/// `secureRectanglesForDisplay:` once the plugin moves to 7.x. It allocates on every call; that is
/// cheap at the SDK's capture rate, and caching by payload and origin is left to the wiring.
///
/// Note for that move: Dart rounds `x, y, width, height` to whole points with `round()`, so an
/// edge can sit up to half a point inside the widget. Rounding outward on the Dart side (floor the
/// left and top, ceil the right and bottom) would close that.
///
/// @param elements `[id, x, y, width, height, ...]` as described above; may be NULL only when
///        `intCount` is 0. A trailing group of fewer than five ints is ignored, and so is a
///        rectangle without width or height.
/// @param intCount Number of ints in `elements`.
/// @param origin Where the Flutter view starts on the screen, in points.
/// @return The packed buffer, immutable. With no rectangle left its count is 0, which the SDK reads
///         as "no secure rectangles". nil when `elements` is NULL but `intCount` is not 0: that
///         input is malformed, and nil must NOT be returned to the SDK, which reads nil as "no
///         secure rectangles" too; keep serving the last good buffer instead.
FOUNDATION_EXPORT NSData *_Nullable BGSFlutterSecureRectanglesBuffer(const int32_t *_Nullable elements,
                                                                     NSUInteger intCount,
                                                                     CGPoint origin);

NS_ASSUME_NONNULL_END
