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

- (double)pointsPerLogicalPixelForDisplay:(NSInteger)display {
  // A Flutter logical pixel is a UIKit point (see the header). Not `UIScreen.scale`.
  return 1.0;
}

- (CGSize)displayBoundsInPointsForDisplay:(NSInteger)display {
  return [self currentScreen].bounds.size;
}

@end

#pragma mark - Tracker

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
    CGPoint origin = [view convertPoint:CGPointZero toCoordinateSpace:screen.coordinateSpace];
    [_environment updateWithScreen:screen];
    [self place:[BGSFlutterSecurePlacement knownOnDisplay:kDefaultDisplay x:origin.x y:origin.y]];
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
