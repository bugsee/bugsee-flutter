#import <XCTest/XCTest.h>

#import "BGSFlutterLifecycleHub.h"

static NSString *const P = @"com.bugsee.lifecycle.";

@interface BGSFlutterLifecycleHubTests : XCTestCase
@end

@implementation BGSFlutterLifecycleHubTests {
  dispatch_queue_t _fakeMain;
}

static void *kQueueKey = &kQueueKey;

- (void)setUp {
  _fakeMain = dispatch_queue_create("fake-main", DISPATCH_QUEUE_SERIAL);
  dispatch_queue_set_specific(_fakeMain, kQueueKey, kQueueKey, NULL);
}

- (BGSFlutterLifecycleHub *)hub {
  return [[BGSFlutterLifecycleHub alloc] initWithDeliveryQueue:_fakeMain];
}

/// Waits until everything queued on the fake main queue has run.
- (void)drain {
  dispatch_sync(_fakeMain, ^{
  });
}

- (NSMutableArray<BGSFlutterLifecycleEvent *> *)attachCollector:(BGSFlutterLifecycleHub *)hub {
  NSMutableArray *seen = [NSMutableArray array];
  [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    @synchronized(seen) {
      [seen addObject:e];
    }
  }];
  [self drain];
  return seen;
}

- (void)testStripsThePrefixExactlyOnce {
  XCTAssertEqualObjects([BGSFlutterLifecycleHub eventForRawName:[P stringByAppendingString:@"Launched"]
                                                           data:nil]
                            .name,
                        @"Launched");
  NSString *twice = [NSString stringWithFormat:@"%@%@Launched", P, P];
  XCTAssertEqualObjects([BGSFlutterLifecycleHub eventForRawName:twice data:nil].name,
                        ([NSString stringWithFormat:@"%@Launched", P]));
}

- (void)testPrefixConstantIsTheSdksOne {
  XCTAssertEqualObjects([BGSFlutterLifecycleHub prefix], @"com.bugsee.lifecycle.");
}

- (void)testUnknownNamesAreForwardedUnchanged {
  BGSFlutterLifecycleHub *hub = [self hub];
  NSMutableArray *seen = [self attachCollector:hub];
  [hub dispatchRawName:[P stringByAppendingString:@"SomethingNewer"] data:nil];
  [hub dispatchRawName:@"no.prefix.at.all" data:nil];
  [hub dispatchRawName:@"" data:nil];
  [hub dispatchRawName:P data:nil];  // the bare prefix: nothing to strip down to
  [self drain];
  NSArray *names = [seen valueForKey:@"name"];
  XCTAssertEqualObjects(names, (@[ @"SomethingNewer", @"no.prefix.at.all", @"", P ]));
}

- (void)testEveryRealSdkNameIsForwarded {
  // From BGSContracts.h (BGSLifecycleEvent*), iOS origin/nextgen. Launching and
  // Stopping have no BugseeLifecycleEventType: the SDK sends them to the wrapper
  // only. The two feedback names exist on Android; iOS does not emit them yet.
  NSArray *names = @[
    @"Launching", @"Launched", @"Stopping", @"Stopped", @"BlackoutEnded", @"BlackoutStarted",
    @"RelaunchedAfterCrash", @"BeforeReportShown", @"AfterReportShown", @"BeforeReportUploaded",
    @"AfterReportUploaded", @"BeforeReportAssembled", @"AfterReportAssembled",
    @"ReportAssemblyFailed", @"ReportUploadFailedWithFutureRetry", @"ReportUploadFailed",
    @"BeforeFeedbackShown", @"AfterFeedbackShown"
  ];
  BGSFlutterLifecycleHub *hub = [self hub];
  NSMutableArray *seen = [self attachCollector:hub];
  for (NSString *n in names) {
    [hub dispatchRawName:[P stringByAppendingString:n] data:nil];
  }
  [self drain];
  XCTAssertEqualObjects([seen valueForKey:@"name"], names);
}

- (void)testOnlyTheReportEventsCarryAReportId {
  for (NSString *n in @[
         @"BeforeReportAssembled", @"AfterReportAssembled", @"ReportAssemblyFailed",
         @"BeforeReportUploaded", @"AfterReportUploaded", @"ReportUploadFailed",
         @"ReportUploadFailedWithFutureRetry"
       ]) {
    XCTAssertEqualObjects([BGSFlutterLifecycleHub eventForRawName:[P stringByAppendingString:n]
                                                             data:@"r-1"]
                              .reportId,
                          @"r-1", @"%@", n);
  }
  // The same payload on any other event is not a report id.
  for (NSString *n in @[ @"Launched", @"BeforeReportShown", @"Whatever" ]) {
    XCTAssertNil([BGSFlutterLifecycleHub eventForRawName:[P stringByAppendingString:n] data:@"r-1"]
                     .reportId,
                 @"%@", n);
  }
  XCTAssertNil([BGSFlutterLifecycleHub eventForRawName:[P stringByAppendingString:@"AfterReportUploaded"]
                                                  data:nil]
                   .reportId);
  // Carried as is, never interpreted.
  XCTAssertEqualObjects([BGSFlutterLifecycleHub eventForRawName:[P stringByAppendingString:@"AfterReportUploaded"]
                                                           data:@""]
                            .reportId,
                        @"");
}

- (void)testDataKeepsOnlyStringToStringEntries {
  NSDictionary *raw = @{@"a" : @"1", @"n" : @2, @3 : @"x"};
  BGSFlutterLifecycleEvent *e = [BGSFlutterLifecycleHub eventForRawName:@"Future" data:raw];
  XCTAssertEqualObjects(e.data, @{@"a" : @"1"});
  XCTAssertNil([BGSFlutterLifecycleHub eventForRawName:@"Future" data:@{@"n" : @1}].data);
  XCTAssertNil([BGSFlutterLifecycleHub eventForRawName:@"Future" data:[NSObject new]].data);
  XCTAssertNil([BGSFlutterLifecycleHub eventForRawName:@"Future" data:nil].data);
}

- (void)testEventsBeforeAttachAreBufferedAndFlushedInOrder {
  BGSFlutterLifecycleHub *hub = [self hub];
  [hub dispatchRawName:[P stringByAppendingString:@"Launching"] data:nil];
  [hub dispatchRawName:[P stringByAppendingString:@"Launched"] data:nil];
  XCTAssertEqual(hub.bufferedCount, 2u);
  NSMutableArray *seen = [self attachCollector:hub];
  XCTAssertEqual(hub.bufferedCount, 0u);
  [hub dispatchRawName:[P stringByAppendingString:@"Stopping"] data:nil];
  [self drain];
  XCTAssertEqualObjects([seen valueForKey:@"name"], (@[ @"Launching", @"Launched", @"Stopping" ]));
}

- (void)testBufferIsBoundedAndDropsTheOldest {
  XCTAssertEqual([BGSFlutterLifecycleHub bufferCapacity], 64u);
  BGSFlutterLifecycleHub *hub = [self hub];
  NSUInteger cap = [BGSFlutterLifecycleHub bufferCapacity];
  for (NSUInteger i = 0; i < cap + 5; i++) {
    [hub dispatchRawName:[NSString stringWithFormat:@"%@E%lu", P, (unsigned long)i] data:nil];
  }
  XCTAssertEqual(hub.bufferedCount, cap);
  XCTAssertEqual(hub.droppedCount, 5u);
  NSMutableArray *seen = [self attachCollector:hub];
  XCTAssertEqual(seen.count, cap);
  XCTAssertEqualObjects([seen.firstObject name], @"E5", @"the oldest were dropped");
  XCTAssertEqualObjects([seen.lastObject name],
                        ([NSString stringWithFormat:@"E%lu", (unsigned long)(cap + 4)]));
}

- (void)testDetachedHubBuffersAgainAndAStaleDetachIsIgnored {
  BGSFlutterLifecycleHub *hub = [self hub];
  NSMutableArray *first = [NSMutableArray array];
  NSMutableArray *second = [NSMutableArray array];
  id a = [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [first addObject:e];
  }];
  id b = [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [second addObject:e];
  }];
  [hub detach:a];  // the first engine goes away: must not silence b
  [hub dispatchRawName:[P stringByAppendingString:@"Launched"] data:nil];
  [self drain];
  XCTAssertEqual(first.count, 0u);
  XCTAssertEqual(second.count, 1u);
  [hub detach:b];
  [hub dispatchRawName:[P stringByAppendingString:@"Stopped"] data:nil];
  [self drain];
  XCTAssertEqual(second.count, 1u);
  XCTAssertEqual(hub.bufferedCount, 1u);
}

/// Workbook 4.4: events arrive off the main thread; the sink must be on the delivery queue.
- (void)testDeliveryHopsToTheDeliveryQueue {
  BGSFlutterLifecycleHub *hub = [self hub];
  __block BOOL onDeliveryQueue = NO;
  __block BOOL sawEvent = NO;
  [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    onDeliveryQueue = dispatch_get_specific(kQueueKey) == kQueueKey;
    sawEvent = [e.name isEqualToString:@"Launched"];
  }];
  [self drain];
  dispatch_queue_t sdk = dispatch_queue_create("sdk-worker", DISPATCH_QUEUE_SERIAL);
  __block BOOL dispatchedOffDeliveryQueue = NO;
  dispatch_sync(sdk, ^{
    dispatchedOffDeliveryQueue = dispatch_get_specific(kQueueKey) == NULL;
    [hub dispatchRawName:[P stringByAppendingString:@"Launched"] data:nil];
  });
  [self drain];
  XCTAssertTrue(dispatchedOffDeliveryQueue);
  XCTAssertTrue(sawEvent);
  XCTAssertTrue(onDeliveryQueue);
}

- (void)testFlushAndLiveEventsStayInOrderAcrossTheHop {
  BGSFlutterLifecycleHub *hub = [self hub];
  [hub dispatchRawName:[P stringByAppendingString:@"A"] data:nil];
  [hub dispatchRawName:[P stringByAppendingString:@"B"] data:nil];
  NSMutableArray *seen = [self attachCollector:hub];
  [hub dispatchRawName:[P stringByAppendingString:@"C"] data:nil];
  [self drain];
  XCTAssertEqualObjects([seen valueForKey:@"name"], (@[ @"A", @"B", @"C" ]));
}

- (void)testASinkThatThrowsDoesNotBreakTheNextEvent {
  BGSFlutterLifecycleHub *hub = [self hub];
  NSMutableArray *seen = [NSMutableArray array];
  [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [seen addObject:e.name];
    @throw [NSException exceptionWithName:@"Dead" reason:@"engine" userInfo:nil];
  }];
  [hub dispatchRawName:[P stringByAppendingString:@"A"] data:nil];
  [hub dispatchRawName:[P stringByAppendingString:@"B"] data:nil];
  [self drain];
  XCTAssertEqualObjects(seen, (@[ @"A", @"B" ]));
}

- (void)testDispatchNeverThrowsOnNil {
  BGSFlutterLifecycleHub *hub = [self hub];
  [hub dispatchRawName:nil data:nil];
  XCTAssertEqual(hub.bufferedCount, 0u);
}

@end
