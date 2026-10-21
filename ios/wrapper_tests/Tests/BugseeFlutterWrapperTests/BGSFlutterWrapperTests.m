#import <XCTest/XCTest.h>

#import "BGSFlutterLifecycleHub.h"
#import "BGSFlutterSecureRectangleStore.h"
#import "BGSFlutterWrapper.h"

@import Bugsee;

/// A 3x phone: a Flutter logical pixel is a point, so the factor is 1.
@interface BGSWrapperTestScreen : NSObject <BGSFlutterSecureEnvironment>
@end
@implementation BGSWrapperTestScreen
- (double)nativePixelRatioForDisplay:(NSInteger)display {
  return 3.0;
}
- (double)unitsPerPhysicalPixelForDisplay:(NSInteger)display {
  return 1.0 / 3.0;
}
- (CGSize)displayBoundsInPointsForDisplay:(NSInteger)display {
  return CGSizeMake(402, 874);
}
@end

static void PublishOnDisplay(BGSFlutterSecureRectangleStore *store, NSInteger display) {
  [store setEnvironment:[[BGSWrapperTestScreen alloc] init]];
  [store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:display x:0 y:0] forOwner:1 viewId:0];
  double rect[] = {10, 20, 30, 40};
  [store publishForOwner:1 epoch:1 sequence:1 views:@{@0 : [[BGSFlutterSecureViewRects alloc] initWithRatio:3 rects:[NSData dataWithBytes:rect length:sizeof(rect)]]}];
}

static NSData *Buffer(int32_t version, int32_t l, int32_t t, int32_t r, int32_t b) {
  int32_t ints[6] = {version, 1, l, t, r, b};
  return [NSData dataWithBytes:ints length:sizeof(ints)];
}

@interface BGSFlutterWrapperTests : XCTestCase
@end

@implementation BGSFlutterWrapperTests

- (void)tearDown {
  [[BGSFlutterSecureRectangleStore shared] clearForTests];
  [BGSFlutterWrapperRegistrar setRegistrationHandlerForTests:nil];
}

- (void)testProcessStartIdentityIsTypeAndVersionOnly {
  BGSFlutterWrapper *w = [BGSFlutterWrapper wrapperAtProcessStart];
  XCTAssertEqualObjects(w.wrapperType, @"flutter");
  XCTAssertNil(w.wrapperBuild);
  XCTAssertEqual(w.context.count, 0u);
}

- (void)testMissingFactsAreUnknownAndContextDropsNonStrings {
  BGSFlutterWrapper *w = [BGSFlutterWrapper wrapperWithType:nil
                                                    version:@""
                                                      build:nil
                                                    context:@{@"flutter" : @"3.41.0", @"n" : @3}];
  XCTAssertEqualObjects(w.wrapperType, @"unknown");
  XCTAssertEqualObjects(w.wrapperVersion, @"unknown");
  XCTAssertEqualObjects(w.context, @{@"flutter" : @"3.41.0"});
}

/// Both the placeholder and a refined wrapper must feed the SAME process-wide hub.
- (void)testEveryWrapperFeedsTheSharedHub {
  BGSFlutterLifecycleHub *shared = [BGSFlutterLifecycleHub shared];
  NSMutableArray *registered = [NSMutableArray array];
  [BGSFlutterWrapperRegistrar setRegistrationHandlerForTests:^(id w) {
    [registered addObject:w];
  }];
  [registered addObject:[BGSFlutterWrapper wrapperAtProcessStart]];
  [BGSFlutterWrapperRegistrar replaceWithType:@"flutter"
                                      version:@"1"
                                        build:nil
                                      context:@{@"a" : @"b"}];
  XCTAssertEqual(registered.count, 2u);
  for (id w in registered) {
    // No receiver is attached in a unit test, so the event lands in the buffer (or, when
    // that is full, in the drop counter).
    NSUInteger before = shared.bufferedCount + shared.droppedCount;
    [(id<BugseeWrapper>)w onLifecycleEvent:@"com.bugsee.lifecycle.Launched" data:nil];
    XCTAssertEqual(shared.bufferedCount + shared.droppedCount, before + 1);
  }
}

- (void)testLifecycleEventsGoToTheHub {
  dispatch_queue_t q = dispatch_queue_create("t", DISPATCH_QUEUE_SERIAL);
  BGSFlutterLifecycleHub *hub = [[BGSFlutterLifecycleHub alloc] initWithDeliveryQueue:q];
  NSMutableArray *seen = [NSMutableArray array];
  [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [seen addObject:e.name];
  }];
  BGSFlutterWrapper *w = [BGSFlutterWrapper wrapperWithType:@"flutter"
                                                    version:@"1"
                                                      build:nil
                                                    context:nil
                                                        hub:hub
                                           secureRectangles:[BGSFlutterSecureRectangleStore new]];
  [(id<BugseeWrapper>)w onLifecycleEvent:@"com.bugsee.lifecycle.Launched" data:nil];
  [(id<BugseeWrapper>)w onLifecycleEvent:@"future-event" data:[NSObject new]];
  dispatch_sync(q, ^{
  });
  XCTAssertEqualObjects(seen, (@[ @"Launched", @"future-event" ]));
}

/// Workbook 5.4.2: the wrapper is replaced when Dart refines the identity; what
/// it serves must not live in it.
- (void)testReplacingTheWrapperKeepsTheSecureRectangleSet {
  PublishOnDisplay([BGSFlutterSecureRectangleStore shared], 0);
  NSData *set = Buffer(1, 10, 20, 30, 40);
  id<BugseeWrapper> placeholder = (id<BugseeWrapper>)[BGSFlutterWrapper wrapperAtProcessStart];
  XCTAssertEqualObjects([placeholder secureRectanglesForDisplay:0], set);

  NSMutableArray *registered = [NSMutableArray array];
  [BGSFlutterWrapperRegistrar setRegistrationHandlerForTests:^(id w) {
    [registered addObject:w];
  }];
  XCTAssertTrue([BGSFlutterWrapperRegistrar replaceWithType:@"flutter"
                                                    version:@"1.2.3"
                                                      build:@"dbg"
                                                    context:@{@"flutter" : @"3.41.0"}]);
  XCTAssertEqual(registered.count, 1u);
  BGSFlutterWrapper *refined = registered.firstObject;
  XCTAssertNotEqual((id)refined, (id)placeholder);
  XCTAssertEqualObjects(refined.wrapperVersion, @"1.2.3");
  XCTAssertEqualObjects(refined.wrapperBuild, @"dbg");
  XCTAssertEqualObjects(refined.context[@"flutter"], @"3.41.0");
  XCTAssertEqualObjects([(id<BugseeWrapper>)refined secureRectanglesForDisplay:0], set);
  // Other displays are unaffected: the empty set, version unknown (0).
  XCTAssertEqualObjects([(id<BugseeWrapper>)refined secureRectanglesForDisplay:1],
                        ([NSData dataWithBytes:(int32_t[]){0, 0} length:8]));
  // A change after the replacement reaches the SDK through the new wrapper, with a new version.
  double moved[] = {10, 20, 31, 40};
  [[BGSFlutterSecureRectangleStore shared] publishForOwner:1
                                                     epoch:1
                                                  sequence:2
                                                     views:@{@0 : [[BGSFlutterSecureViewRects alloc] initWithRatio:3 rects:[NSData dataWithBytes:moved length:sizeof(moved)]]}];
  // (The shared store has the grace window, so the old place is served after the new one.)
  NSData *changed = [(id<BugseeWrapper>)refined secureRectanglesForDisplay:0];
  int32_t head[6] = {2, 2, 10, 20, 31, 40};
  XCTAssertEqualObjects([changed subdataWithRange:NSMakeRange(0, sizeof(head))],
                        [NSData dataWithBytes:head length:sizeof(head)]);
}

@end
