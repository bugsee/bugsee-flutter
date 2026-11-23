#import <UIKit/UIKit.h>

#import "BGSFlutterSecureRectangleStore.h"

NS_ASSUME_NONNULL_BEGIN

/// What `BGSFlutterSecureRectangleStore` reads off an iPhone or iPad, at every pull.
///
/// The factor from Flutter logical pixels to the SDK's unit is exactly 1: Flutter's iOS
/// embedder defines a logical pixel as `physical / UIScreen.scale`, and a UIKit point is
/// `physical / UIScreen.scale` too, on every screen and in every display mode. The SDK takes
/// points, so nothing is multiplied by the screen's scale (that would be the Android rule,
/// physical pixels, and would redact 3x too much on a 3x phone). It is still a method that is
/// asked at every pull, and the screen's size is read from the live `UIScreen` each time.
@interface BGSFlutterUIKitEnvironment : NSObject <BGSFlutterSecureEnvironment>
/// Called by the tracker (main thread) with the screen the Flutter view is on.
- (void)updateWithScreen:(nullable UIScreen *)screen;
@end

/// Keeps `BGSFlutterSecureRectangleStore`'s idea of where this engine's Flutter view sits
/// on the screen current. Dart measures in the view's own logical pixels; the SDK wants
/// points in the screen's coordinate space, so the view's position in
/// `UIScreen.coordinateSpace` is added (a window need not sit at the screen's origin on
/// iPad: Split View, Stage Manager).
///
/// Reports, and why:
///  - no view controller yet (a headless engine, or a transition): Unknown, served as the
///    whole display, because the regions might be anywhere;
///  - a view that is in no window: Absent, nothing of Flutter can be drawn;
///  - otherwise the view's display (0, the only one the SDK polls) and position.
///
/// Re-read on every publish from Dart and on every SDK pull: synchronously when that is on
/// the main thread (where the SDK pulls today), else by a throttled hop to it. All view
/// access is on the main thread.
@interface BGSFlutterSecurePlacementTracker : NSObject

/// `viewProvider` returns the engine's Flutter view, or nil. Main thread only.
- (instancetype)initWithOwner:(int64_t)owner
                        store:(BGSFlutterSecureRectangleStore *)store
                  environment:(BGSFlutterUIKitEnvironment *)environment
                 viewProvider:(UIView *_Nullable (^)(void))viewProvider;

/// Reads the view now. Main thread only. Never throws.
- (void)refresh;

/// Stops tracking (engine detached).
- (void)detach;

/// The SDK's pull asks every tracker to refresh. Any thread; never blocks, never throws.
+ (void)refreshAllFromPull;

@end

NS_ASSUME_NONNULL_END
