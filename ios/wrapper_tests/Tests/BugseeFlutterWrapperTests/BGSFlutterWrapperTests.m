#import <XCTest/XCTest.h>

#import "BGSFlutterLifecycleHub.h"
#import "BGSFlutterSecureRectangleStore.h"
#import "BGSFlutterWrapper.h"

@import Bugsee;

@interface BGSFlutterWrapperTests : XCTestCase
@end

@implementation BGSFlutterWrapperTests

static NSData *Ints(int32_t a, int32_t b, int32_t c, int32_t d, int32_t e, int32_t f) {
  int32_t ints[6] = {a, b, c, d, e, f};
  return [NSData dataWithBytes:ints length:sizeof(ints)];
}

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
  NSData *set = Ints(7, 1, 10, 20, 30, 40);
  [[BGSFlutterSecureRectangleStore shared] publish:set forDisplay:0];
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
}

- (void)testSecureRectangleSnapshotsAreImmutableCopiesPerDisplay {
  BGSFlutterSecureRectangleStore *store = [BGSFlutterSecureRectangleStore new];
  NSMutableData *mine = [Ints(3, 0, 0, 0, 0, 0) mutableCopy];
  [store publish:mine forDisplay:0];
  [store publish:Ints(5, 1, 1, 1, 2, 2) forDisplay:1];
  int32_t changed = 99;
  [mine replaceBytesInRange:NSMakeRange(0, 4) withBytes:&changed];
  int32_t first = 0;
  [[store snapshotForDisplay:0] getBytes:&first length:4];
  XCTAssertEqual(first, 3, @"a later write by the caller must not reach the SDK's snapshot");
  int32_t other = 0;
  [[store snapshotForDisplay:1] getBytes:&other length:4];
  XCTAssertEqual(other, 5);
}

@end
