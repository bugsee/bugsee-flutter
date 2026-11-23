#import "BGSFlutterSecurePlacementTracker.h"

#import <QuartzCore/QuartzCore.h>

#include <math.h>

/// The only display the SDK polls on iOS (`BGSDefaultDisplayId`).
static const NSInteger kDefaultDisplay = 0;
/// The implicit view: the only one a mobile engine has.
static const int64_t kImplicitViewId = 0;
/// The fastest an off-main pull asks the main thread for a refresh.
static const CFTimeInterval kMinPullRefreshInterval = 0.1;

#pragma mark - Environment

@implementation BGSFlutterUIKitEnvironment {
  NSObject *_lock;
  __weak UIScreen *_screen;
}

- (instancetype)init {
  if ((self = [super init])) {
    _lock = [[NSObject alloc] init];
  }
  return self;
}

- (void)updateWithScreen:(UIScreen *)screen {
  @synchronized(_lock) {
    _screen = screen;
  }
}

- (UIScreen *)currentScreen {
  UIScreen *screen;
  @synchronized(_lock) {
    screen = _screen;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return screen ?: [UIScreen mainScreen];
#pragma clang diagnostic pop
}

- (double)nativePixelRatioForDisplay:(NSInteger)display {
  // Read per call: the screen's scale can change (display zoom, an external display).
  return [self currentScreen].scale;
}

- (double)unitsPerPhysicalPixelForDisplay:(NSInteger)display {
  // The SDK takes points. A Flutter logical pixel is physical / ratio, a point is
  // physical / scale: with ratio == scale (the store checks) a logical pixel is one point, and
  // the screen's scale is divided out, never multiplied in.
  double scale = [self currentScreen].scale;
  return scale > 0 ? 1.0 / scale : NAN;
}

- (CGSize)displayBoundsInPointsForDisplay:(NSInteger)display {
  return [self currentScreen].bounds.size;
}

@end

#pragma mark - Tracker

/// Whether the view's corners map to the screen by a positive scale and a translation only (no
/// rotation, skew or flip): `o` is its origin on screen, `px` its top-right and `py` its
/// bottom-left, `size` its bounds. On success the scale is returned in `sx`/`sy`: a Flutter view
/// shrunk by a transform of its own or an ancestor's (a page-sheet presentation) must scale its
/// rectangles too, or they land on the wrong pixels.
static BOOL BGSPureScale(CGPoint o, CGPoint px, CGPoint py, CGSize size, double *sx, double *sy) {
  if (!(size.width > 0) || !(size.height > 0)) return NO;
  double ax = (px.x - o.x) / size.width, ay = (px.y - o.y) / size.width;
  double bx = (py.x - o.x) / size.height, by = (py.y - o.y) / size.height;
  const double tolerance = 1e-4;
  if (!isfinite(ax) || !isfinite(ay) || !isfinite(bx) || !isfinite(by)) return NO;
  if (fabs(ay) > tolerance || fabs(bx) > tolerance) return NO;
  if (!(ax > 0) || !(by > 0)) return NO;
  *sx = ax;
  *sy = by;
  return YES;
}


static NSHashTable<BGSFlutterSecurePlacementTracker *> *BGSTrackers(void) {
  static NSHashTable *trackers;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    trackers = [NSHashTable weakObjectsHashTable];
  });
  return trackers;
}

@implementation BGSFlutterSecurePlacementTracker {
  int64_t _owner;
  BGSFlutterSecureRectangleStore *_store;
  BGSFlutterUIKitEnvironment *_environment;
  UIView *_Nullable (^_viewProvider)(void);
  BOOL _detached;
}

- (instancetype)initWithOwner:(int64_t)owner
                        store:(BGSFlutterSecureRectangleStore *)store
                  environment:(BGSFlutterUIKitEnvironment *)environment
                 viewProvider:(UIView *_Nullable (^)(void))viewProvider {
  if ((self = [super init])) {
    _owner = owner;
    _store = store;
    _environment = environment;
    _viewProvider = [viewProvider copy];
    @synchronized(BGSTrackers()) {
      [BGSTrackers() addObject:self];
    }
    // The pull asks every live tracker for a refresh.
    [store setPullHook:^{
      [BGSFlutterSecurePlacementTracker refreshAllFromPull];
    }];
  }
  return self;
}

- (void)refresh {
  if (_detached) return;
  @try {
    UIView *view = _viewProvider();
    if (view == nil) {
      [self place:[BGSFlutterSecurePlacement unknown]];
      return;
    }
    UIWindow *window = view.window;
    if (window == nil) {
      [self place:[BGSFlutterSecurePlacement absent]];
      return;
    }
    UIScreen *screen = window.screen;
    id<UICoordinateSpace> space = screen.coordinateSpace;
    CGRect bounds = view.bounds;
    CGPoint o = [view convertPoint:CGPointZero toCoordinateSpace:space];
    CGPoint px = [view convertPoint:CGPointMake(CGRectGetMaxX(bounds), 0) toCoordinateSpace:space];
    CGPoint py = [view convertPoint:CGPointMake(0, CGRectGetMaxY(bounds)) toCoordinateSpace:space];
    [_environment updateWithScreen:screen];
    double sx = 0, sy = 0;
    if (!BGSPureScale(o, px, py, bounds.size, &sx, &sy)) {
      // Rotated, skewed, flipped or degenerate: not a scale and a translation.
      [self place:[BGSFlutterSecurePlacement unknown]];
      return;
    }
    [self place:[BGSFlutterSecurePlacement knownOnDisplay:kDefaultDisplay
                                                         x:o.x
                                                         y:o.y
                                                    scaleX:sx
                                                    scaleY:sy]];
  } @catch (id exception) {
    [self place:[BGSFlutterSecurePlacement unknown]];
  }
}

- (void)place:(BGSFlutterSecurePlacement *)placement {
  [_store setPlacement:placement forOwner:_owner viewId:kImplicitViewId];
}

- (void)detach {
  _detached = YES;
  @synchronized(BGSTrackers()) {
    [BGSTrackers() removeObject:self];
  }
}

+ (void)refreshAllFromPull {
  @try {
    static _Atomic(CFTimeInterval) lastAsk = 0;
    if ([NSThread isMainThread]) {
      // The SDK pulls on the main thread today: read the view now, so the answer is exact.
      [self refreshAllNow];
      return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval last = lastAsk;
    if (last != 0 && now - last < kMinPullRefreshInterval) return;
    lastAsk = now;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self refreshAllNow];
    });
  } @catch (id exception) {
    // The pull is answered regardless.
  }
}

+ (void)refreshAllNow {
  NSArray<BGSFlutterSecurePlacementTracker *> *all;
  @synchronized(BGSTrackers()) {
    all = BGSTrackers().allObjects;
  }
  for (BGSFlutterSecurePlacementTracker *tracker in all) {
    [tracker refresh];
  }
}

@end
