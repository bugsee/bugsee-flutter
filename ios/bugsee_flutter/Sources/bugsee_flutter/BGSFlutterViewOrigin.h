#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Where `view`'s own coordinate space starts in the frame the 7.x iOS SDK records, in points:
/// what to add to a rectangle measured in the view to put it where the SDK draws it, as its
/// secure-rectangle contract wants (`BGSFlutterSecureRectanglesBuffer`).
///
/// On iOS the SDK records every window of the app at its place on the screen, so this is the
/// view's place on its screen, through the screen's fixed (portrait) space as the SDK places
/// windows (`+[BGSTrackerApplication screenRectForRect:inView:]`). Converted straight to
/// `screen.coordinateSpace`, a scene that shares its screen (iPad tiling, iPhone Duo side by side)
/// reads {0, 0}. Mac Catalyst and an iPhone or iPad app running on a Mac record the key window's
/// scene alone, where the SDK moves a rect in the window by the window's `frame.origin`
/// (`+[BGSTrackerApplication captureRectForRect:inView:]`); so does a window on no screen.
///
/// Not wired yet; see `BGSFlutterSecureRectanglesBuffer`. Reads UIKit: main thread only.
///
/// @return NO, leaving `origin` untouched, when `view` is in no window, or on iOS before 13,
///         which has no window scenes (the 7.x SDK needs iOS 15).
FOUNDATION_EXPORT BOOL BGSFlutterViewOriginOnScreen(UIView *view, CGPoint *_Nullable origin);

NS_ASSUME_NONNULL_END
