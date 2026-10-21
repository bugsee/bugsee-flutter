#import <XCTest/XCTest.h>

#import "BGSFlutterSecurePlacementTracker.h"
#import "BGSFlutterSecureRectangleStore.h"

/// Where the Flutter view sits on the screen, read off real UIKit views.
@interface BGSFlutterSecurePlacementTrackerTests : XCTestCase
@end

@implementation BGSFlutterSecurePlacementTrackerTests {
  BGSFlutterSecureRectangleStore *_store;
  BGSFlutterUIKitEnvironment *_environment;
  UIWindow *_window;
  UIView *_flutterView;
  BGSFlutterSecurePlacementTracker *_tracker;
  BOOL _viewAvailable;
}

- (void)setUp {
  _environment = [[BGSFlutterUIKitEnvironment alloc] init];
  _store = [[BGSFlutterSecureRectangleStore alloc] initWithEnvironment:_environment];
  CGRect screen = [UIScreen mainScreen].bounds;
  _window = [[UIWindow alloc] initWithFrame:screen];
  _flutterView = [[UIView alloc] initWithFrame:CGRectMake(0, 66, screen.size.width, screen.size.height - 66)];
  [_window addSubview:_flutterView];
  _viewAvailable = YES;
  __weak typeof(self) weakSelf = self;
  _tracker = [[BGSFlutterSecurePlacementTracker alloc]
      initWithOwner:1
              store:_store
        environment:_environment
       viewProvider:^UIView *_Nullable {
         typeof(self) strongSelf = weakSelf;
         return strongSelf != nil && strongSelf->_viewAvailable ? strongSelf->_flutterView : nil;
       }];
}

- (void)tearDown {
  [_tracker detach];
}

static NSArray<NSNumber *> *Ints(NSData *buffer) {
  NSMutableArray *out = [NSMutableArray array];
  const int32_t *p = buffer.bytes;
  for (NSUInteger i = 0; i < buffer.length / 4; i++) [out addObject:@(p[i])];
  return out;
}

- (void)publishRect {
  double v[] = {10, 10, 20, 20};
  [_store publishForOwner:1 epoch:1 sequence:1 views:@{@0 : [NSData dataWithBytes:v length:sizeof(v)]}];
}

- (void)testTheViewsOffsetFromTheScreenOriginIsAdded {
  [self publishRect];
  [_tracker refresh];
  XCTAssertNotEqual([UIScreen mainScreen].scale, 1.0, @"a 1x screen would make this check vacuous");
  NSArray *s = Ints([_store snapshotForDisplay:0]);
  XCTAssertEqualObjects([s subarrayWithRange:NSMakeRange(1, s.count - 1)], (@[ @1, @10, @76, @20, @86 ]));
}

- (void)testAWindowThatIsNotAtTheScreenOriginIsAccountedFor {
  _window.frame = CGRectOffset(_window.frame, 20, 30);
  [self publishRect];
  [_tracker refresh];
  NSArray *s = Ints([_store snapshotForDisplay:0]);
  XCTAssertEqualObjects([s subarrayWithRange:NSMakeRange(1, s.count - 1)], (@[ @1, @30, @106, @40, @116 ]));
}

- (void)testMovingTheViewMovesTheRectanglesAtTheNextPull {
  [self publishRect];
  [_tracker refresh];
  int32_t before = [Ints([_store snapshotForDisplay:0]) .firstObject intValue];
  _flutterView.frame = CGRectOffset(_flutterView.frame, 0, 100);
  // The SDK's pull (on the main thread, as today) re-reads the position first.
  NSArray *s = Ints([_store pullForDisplay:0]);
  XCTAssertEqualObjects([s subarrayWithRange:NSMakeRange(1, s.count - 1)], (@[ @1, @10, @176, @20, @186 ]));
  XCTAssertNotEqual(before, [s.firstObject intValue]);
}

- (void)testNoViewControllerYetCoversTheWholeScreen {
  _viewAvailable = NO;
  [self publishRect];
  [_tracker refresh];
  CGSize bounds = [UIScreen mainScreen].bounds.size;
  NSArray *s = Ints([_store snapshotForDisplay:0]);
  XCTAssertEqualObjects([s subarrayWithRange:NSMakeRange(1, s.count - 1)], (@[ @1, @0, @0, @(ceil(bounds.width)), @(ceil(bounds.height)) ]));
}

- (void)testAViewInNoWindowServesNothing {
  [_flutterView removeFromSuperview];
  [self publishRect];
  [_tracker refresh];
  XCTAssertEqual([Ints([_store snapshotForDisplay:0])[1] intValue], 0);
}

- (void)testBeforeTheFirstReadTheRectangleCoversTheWholeScreen {
  [self publishRect];  // the tracker has not read the view yet
  XCTAssertEqual([Ints([_store snapshotForDisplay:0])[1] intValue], 1);
  CGSize bounds = [UIScreen mainScreen].bounds.size;
  XCTAssertEqualObjects([Ints([_store snapshotForDisplay:0]) subarrayWithRange:NSMakeRange(2, 4)],
                        (@[ @0, @0, @(ceil(bounds.width)), @(ceil(bounds.height)) ]));
}

@end
