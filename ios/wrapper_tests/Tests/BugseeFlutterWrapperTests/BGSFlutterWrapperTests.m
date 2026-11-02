#import <XCTest/XCTest.h>

#import "BGSFlutterFakeReport.h"
#import "BGSFlutterLifecycleHub.h"
#import "BGSFlutterReportHandlerPipeline.h"
#import "BGSFlutterSecureRectangleStore.h"
#import "BGSFlutterViewHierarchyStore.h"
#import "BGSFlutterWrapper.h"

@import Bugsee.SPI;

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

/// A callback that counts its answers and records the last.
@interface BGSCountingCallback : NSObject <BGSDataRequestResultCallback>
@property(nonatomic) NSUInteger calls;
@property(nonatomic, copy, nullable) NSString *last;
@property(nonatomic) BOOL throws;
@end
@implementation BGSCountingCallback
- (void)onResult:(NSString *)result {
  self.calls++;
  self.last = result ?: @"<nil>";
  if (self.throws) {
    [NSException raise:NSInternalInconsistencyException format:@"callback failed"];
  }
}
@end

@interface BGSFlutterWrapperTests : XCTestCase
@end

@implementation BGSFlutterWrapperTests

- (void)tearDown {
  [[BGSFlutterSecureRectangleStore shared] clearForTests];
  [[BGSFlutterViewHierarchyStore shared] clearForTests];
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

#pragma mark - requestData (workbook 6.1, Part 6)

/// Every type is answered with nil when there is nothing to say, `vh` included, and never throws.
- (void)assertAnswersNilForEveryType:(id<BugseeWrapper>)wrapper {
  for (NSString *type in @[ @"vh", @"", @"something-new" ]) {
    BGSCountingCallback *callback = [[BGSCountingCallback alloc] init];
    [wrapper requestDataWithType:type callback:callback];
    XCTAssertEqual(callback.calls, 1u, @"%@", type);
    XCTAssertEqualObjects(callback.last, @"<nil>", @"%@", type);
  }
  // A throwing callback must not escape, and a missing one is not a crash.
  BGSCountingCallback *throwing = [[BGSCountingCallback alloc] init];
  throwing.throws = YES;
  XCTAssertNoThrow([wrapper requestDataWithType:@"vh" callback:throwing]);
  XCTAssertNoThrow([wrapper requestDataWithType:@"vh" callback:(id)nil]);
}

- (void)testRequestDataAnswersNilWhenThereIsNothingAndNeverThrows {
  [self assertAnswersNilForEveryType:(id<BugseeWrapper>)[BGSFlutterWrapper wrapperAtProcessStart]];
}

/// `vh` is answered from the cache, synchronously on the calling thread (the SDK's main thread: a
/// reply that waited for Dart would deadlock it), exactly once; every other type is nil.
- (void)testVhIsAnsweredFromTheCacheSynchronouslyOnTheCallingThread {
  BGSFlutterSecureRectangleStore *secure =
      [[BGSFlutterSecureRectangleStore alloc] initWithEnvironment:[[BGSWrapperTestScreen alloc] init]];
  BGSFlutterViewHierarchyStore *views = [[BGSFlutterViewHierarchyStore alloc]
      initWithPlacement:secure
                  clock:^NSTimeInterval {
                    return 5;
                  }];
  [secure setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  double bounds[] = {0, 0, 10, 20};
  XCTAssertTrue([views publishForOwner:1 epoch:1 sequence:1 viewId:0 ratio:3
                              segments:(@[ @"A", @"B", @"C" ])
                                bounds:[NSData dataWithBytes:bounds length:sizeof(bounds)]]);
  id<BugseeWrapper> wrapper = (id<BugseeWrapper>)[BGSFlutterWrapper wrapperWithType:@"flutter"
                                                                            version:@"1"
                                                                              build:nil
                                                                            context:nil
                                                                                hub:[BGSFlutterLifecycleHub shared]
                                                                   secureRectangles:secure
                                                                            reports:[BGSFlutterReportHandlerPipeline shared]
                                                                      viewHierarchy:views];
  BGSCountingCallback *callback = [[BGSCountingCallback alloc] init];
  [wrapper requestDataWithType:@"vh" callback:callback];
  XCTAssertEqual(callback.calls, 1u, @"answered before the call returned, exactly once");
  XCTAssertEqualObjects(callback.last, @"A0B[0,0,10,20]C");
  for (NSString *other in @[ @"", @"VH", @"vh ", @"something-new" ]) {
    BGSCountingCallback *reply = [[BGSCountingCallback alloc] init];
    [wrapper requestDataWithType:other callback:reply];
    XCTAssertEqual(reply.calls, 1u, @"%@", other);
    XCTAssertEqualObjects(reply.last, @"<nil>", @"%@", other);
  }
}

/// The wrapper is replaced when Dart refines the identity: the cache is not in it.
- (void)testTheReplacedWrapperServesTheSameCache {
  BGSFlutterSecureRectangleStore *secure = [BGSFlutterSecureRectangleStore shared];
  [secure setEnvironment:[[BGSWrapperTestScreen alloc] init]];
  [secure setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:77 viewId:0];
  double bounds[] = {0, 0, 10, 20};
  XCTAssertTrue([[BGSFlutterViewHierarchyStore shared] publishForOwner:77 epoch:1 sequence:1 viewId:0 ratio:3
                                                              segments:(@[ @"A", @"B", @"C" ])
                                                                bounds:[NSData dataWithBytes:bounds length:sizeof(bounds)]]);
  NSMutableArray *registered = [NSMutableArray array];
  [BGSFlutterWrapperRegistrar setRegistrationHandlerForTests:^(id w) {
    [registered addObject:w];
  }];
  XCTAssertTrue([BGSFlutterWrapperRegistrar replaceWithType:@"flutter" version:@"1.2.3" build:nil context:nil]);
  BGSCountingCallback *fromPlaceholder = [[BGSCountingCallback alloc] init];
  BGSCountingCallback *fromRefined = [[BGSCountingCallback alloc] init];
  [(id<BugseeWrapper>)[BGSFlutterWrapper wrapperAtProcessStart] requestDataWithType:@"vh" callback:fromPlaceholder];
  [(id<BugseeWrapper>)registered.firstObject requestDataWithType:@"vh" callback:fromRefined];
  // The age (the number after "A") depends on the clock: compare what does not.
  NSRegularExpression *age = [NSRegularExpression regularExpressionWithPattern:@"^A\\d+B" options:0 error:nil];
  NSString *(^withoutAge)(NSString *) = ^NSString *(NSString *s) {
    return [age stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"AB"];
  };
  XCTAssertEqualObjects(withoutAge(fromRefined.last), @"AB[0,0,10,20]C");
  XCTAssertEqualObjects(withoutAge(fromPlaceholder.last), withoutAge(fromRefined.last));
}

/// The wrapper is replaced at runtime when Dart refines the identity; the replacement answers too.
- (void)testTheReplacedWrapperAnswersRequestDataToo {
  NSMutableArray *registered = [NSMutableArray array];
  [BGSFlutterWrapperRegistrar setRegistrationHandlerForTests:^(id w) {
    [registered addObject:w];
  }];
  XCTAssertTrue([BGSFlutterWrapperRegistrar replaceWithType:@"flutter" version:@"1.2.3" build:nil context:nil]);
  XCTAssertEqual(registered.count, 1u);
  [self assertAnswersNilForEveryType:registered.firstObject];
}

#pragma mark - report handlers (workbook Part 7)

- (BGSFlutterReportHandlerPipeline *)pipelineCollecting:(NSMutableArray<BGSFlutterReportRequest *> *)requests
                                                  owner:(id *)owner
                                              deadlines:(NSMutableArray<dispatch_block_t> *)deadlines {
  BGSFlutterReportHandlerPipeline *pipeline = [[BGSFlutterReportHandlerPipeline alloc]
      initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
        @synchronized(deadlines) {
          [deadlines addObject:[task copy]];
        }
        return @"t";
      }
      cancel:^(id token) {
      }
      platformPost:^(dispatch_block_t task) {
        task();
      }
      log:^(NSString *line) {
      }
      // A clock that never advances: the delivery gap is deducted from the deadline, and a real
      // clock made the deadline 1999 ms on a slow runner. The tests assert the full budget.
      clock:^int64_t {
        return 0;
      }];
  *owner = [pipeline attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
    @synchronized(requests) {
      [requests addObject:request];
    }
  }];
  [pipeline setPhasesForOwner:*owner before:YES after:YES];
  return pipeline;
}

/// The SDK's callbacks reach the pipeline from a NON-main thread (iOS recovery), complete
/// exactly once, and a Dart handler that never answers does not stall them.
- (void)testReportHandlersGoThroughThePipelineFromANonMainThread {
  NSMutableArray<BGSFlutterReportRequest *> *requests = [NSMutableArray array];
  NSMutableArray<dispatch_block_t> *deadlines = [NSMutableArray array];
  id owner = nil;
  BGSFlutterReportHandlerPipeline *pipeline = [self pipelineCollecting:requests owner:&owner deadlines:deadlines];
  BGSFlutterWrapper *w = [BGSFlutterWrapper wrapperWithType:@"flutter"
                                                    version:@"1"
                                                      build:nil
                                                    context:nil
                                                        hub:[BGSFlutterLifecycleHub shared]
                                           secureRectangles:[BGSFlutterSecureRectangleStore new]
                                                    reports:pipeline];
  BGSFlutterFakeReport *report = [[BGSFlutterFakeReport alloc] init];
  __block NSUInteger completions = 0;
  NSObject *lock = [[NSObject alloc] init];
  XCTestExpectation *returned = [self expectationWithDescription:@"callbacks returned"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    XCTAssertFalse([NSThread isMainThread]);
    [(id<BugseeWrapper>)w onBeforeReportCreated:report isTerminating:NO completion:^{
      @synchronized(lock) { completions++; }
    }];
    [(id<BugseeWrapper>)w onAfterReportCreated:report isTerminating:NO completion:^{
      @synchronized(lock) { completions++; }
    }];
    [returned fulfill];
  });
  [self waitForExpectations:@[ returned ] timeout:60];
  XCTAssertEqual(requests.count, 2u, @"both phases reached the Dart end, off the main thread");
  XCTAssertFalse(requests[0].after);
  XCTAssertTrue(requests[1].after);
  // Off main, so the recovery budget (inside the SDK's 3 s cap).
  XCTAssertEqual(requests[0].deadlineMs, BGSFlutterReportRecoveryDeadlineMs);
  @synchronized(lock) {
    XCTAssertEqual(completions, 0u, @"nothing completed: the SDK waits for Dart or the deadline");
  }
  // Dart never answers: the deadlines complete both, once each, however late they come.
  for (dispatch_block_t deadline in [deadlines copy]) {
    deadline();
  }
  for (dispatch_block_t deadline in [deadlines copy]) {
    deadline();
  }
  XCTAssertEqual(completions, 2u);
  [pipeline detachOwner:owner];
  XCTAssertEqual(completions, 2u);
}

- (void)testTerminatingNeverReachesDartThroughTheWrapper {
  NSMutableArray<BGSFlutterReportRequest *> *requests = [NSMutableArray array];
  id owner = nil;
  BGSFlutterReportHandlerPipeline *pipeline = [self pipelineCollecting:requests owner:&owner deadlines:[NSMutableArray array]];
  BGSFlutterWrapper *w = [BGSFlutterWrapper wrapperWithType:@"flutter" version:@"1" build:nil context:nil
                                                        hub:[BGSFlutterLifecycleHub shared]
                                           secureRectangles:[BGSFlutterSecureRectangleStore new]
                                                    reports:pipeline];
  __block NSUInteger completions = 0;
  [(id<BugseeWrapper>)w onBeforeReportCreated:[[BGSFlutterFakeReport alloc] init] isTerminating:YES completion:^{ completions++; }];
  [(id<BugseeWrapper>)w onAfterReportCreated:[[BGSFlutterFakeReport alloc] init] isTerminating:YES completion:^{ completions++; }];
  XCTAssertEqual(completions, 2u);
  XCTAssertEqual(requests.count, 0u);
}

/// With no Dart handler registered (the default), the SDK is never left waiting.
- (void)testTheDefaultWrapperCompletesImmediatelyWhenNoDartHandlerIsRegistered {
  BGSFlutterWrapper *w = [BGSFlutterWrapper wrapperAtProcessStart];
  __block NSUInteger completions = 0;
  [(id<BugseeWrapper>)w onBeforeReportCreated:[[BGSFlutterFakeReport alloc] init] isTerminating:NO completion:^{ completions++; }];
  [(id<BugseeWrapper>)w onAfterReportCreated:[[BGSFlutterFakeReport alloc] init] isTerminating:NO completion:^{ completions++; }];
  XCTAssertEqual(completions, 2u);
}

@end
