#import "BGSFlutterViewOrigin.h"

/// Whether the 7.x SDK composes the app's windows on the screen: iOS, and not an iPhone or iPad
/// app running on a Mac (`+[BGSTrackerApplication capturesAppScreen]`).
static BOOL BGSFlutterSdkComposesScreen(void) {
#if TARGET_OS_MACCATALYST
    return NO;
#else
    if (@available(iOS 14.0, *)) {
        return !NSProcessInfo.processInfo.isiOSAppOnMac;
    }
    return YES;
#endif
}

BOOL BGSFlutterViewOriginOnScreen(UIView *view, CGPoint *origin) {
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    if (window == nil) {
        return NO;
    }

    if (@available(iOS 13.0, *)) {
        UIScreen *screen = window.windowScene.screen;
        CGPoint result;
        if (screen != nil && BGSFlutterSdkComposesScreen()) {
            id<UICoordinateSpace> fixedSpace = screen.fixedCoordinateSpace;
            CGRect inFixedSpace = [view convertRect:view.bounds toCoordinateSpace:fixedSpace];
            result = [fixedSpace convertRect:inFixedSpace toCoordinateSpace:screen.coordinateSpace].origin;
        } else {
            CGRect inWindow = view == window ? view.bounds : [window convertRect:view.bounds fromView:view];
            result = CGPointMake(window.frame.origin.x + inWindow.origin.x,
                                 window.frame.origin.y + inWindow.origin.y);
        }
        if (origin != NULL) {
            *origin = result;
        }
        return YES;
    }
    return NO;
}
