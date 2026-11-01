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
  // From BugseeSPI.h (BGSLifecycleEvent*; BGSContracts.h until beta7), iOS origin/release. Launching and
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

- (NSMutableArray<NSString *> *)attachNames:(BGSFlutterLifecycleHub *)hub token:(id *)token {
  NSMutableArray *names = [NSMutableArray array];
  id t = [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [names addObject:e.name];
  }];
  if (token) {
    *token = t;
  }
  [self drain];
  return names;
}

- (void)raw:(BGSFlutterLifecycleHub *)hub name:(NSString *)n {
  [hub dispatchRawName:[P stringByAppendingString:n] data:nil];
}

- (void)testDetachedHubBuffersAgain {
  BGSFlutterLifecycleHub *hub = [self hub];
  id token;
  NSMutableArray *seen = [self attachNames:hub token:&token];
  [hub detach:token];
  [self raw:hub name:@"Stopped"];
  [self drain];
  XCTAssertEqual(seen.count, 0u);
  XCTAssertEqual(hub.bufferedCount, 1u);
}

/// A background engine must not take events from the UI engine.
- (void)testEveryAttachedReceiverGetsEveryEventAndDetachRemovesOnlyItsOwn {
  BGSFlutterLifecycleHub *hub = [self hub];
  id uiToken, bgToken;
  NSMutableArray *ui = [self attachNames:hub token:&uiToken];
  NSMutableArray *bg = [self attachNames:hub token:&bgToken];
  [self raw:hub name:@"A"];
  [self drain];
  XCTAssertEqualObjects(ui, @[ @"A" ]);
  XCTAssertEqualObjects(bg, @[ @"A" ]);
  [hub detach:bgToken];
  [self raw:hub name:@"B"];
  [self drain];
  XCTAssertEqualObjects(ui, (@[ @"A", @"B" ]));
  XCTAssertEqualObjects(bg, @[ @"A" ]);
  XCTAssertEqual(hub.bufferedCount, 0u);
  [hub detach:bgToken];  // detaching twice is harmless
  [hub detach:uiToken];
  [self raw:hub name:@"C"];
  XCTAssertEqual(hub.bufferedCount, 1u);
}

- (void)testASecondReceiverThatAttachesLateGetsTheBufferOnlyOnce {
  BGSFlutterLifecycleHub *hub = [self hub];
  [self raw:hub name:@"A"];
  NSMutableArray *first = [self attachNames:hub token:NULL];
  NSMutableArray *second = [self attachNames:hub token:NULL];
  XCTAssertEqualObjects(first, @[ @"A" ]);
  XCTAssertEqual(second.count, 0u, @"the buffer went to the first receiver only");
}

/// A restarted engine learns the status even though the hub already flushed it.
- (void)testTheLatestStatusIsReplayedFirstToEveryNewReceiver {
  BGSFlutterLifecycleHub *hub = [self hub];
  [self raw:hub name:@"Launching"];
  [self raw:hub name:@"Launched"];
  id token;
  [self attachNames:hub token:&token];
  [hub detach:token];
  [self raw:hub name:@"BlackoutStarted"];  // buffered, not a status
  NSMutableArray *again = [self attachNames:hub token:NULL];
  XCTAssertEqualObjects(again, (@[ @"Launched", @"BlackoutStarted" ]));
  [self raw:hub name:@"Stopping"];
  [self raw:hub name:@"Stopped"];
  NSMutableArray *joined = [self attachNames:hub token:NULL];
  XCTAssertEqualObjects(joined, @[ @"Stopped" ]);
}

- (void)testOnlyTheFourTransitionsAreReplayedAsStatus {
  for (NSString *n in @[ @"BlackoutStarted", @"RelaunchedAfterCrash", @"Whatever" ]) {
    BGSFlutterLifecycleHub *hub = [self hub];
    [self raw:hub name:n];
    id token;
    [self attachNames:hub token:&token];
    [hub detach:token];
    XCTAssertEqual([self attachNames:hub token:NULL].count, 0u, @"%@", n);
  }
}

/// Re-attach with an event in flight: posted to the old receiver, which went away
/// before the queue ran it. The new receiver gets it, once, before later events.
- (void)testAnEventInFlightWhenTheReceiverIsReplacedReachesTheNewOneInOrder {
  BGSFlutterLifecycleHub *hub = [self hub];
  dispatch_suspend(_fakeMain);
  NSMutableArray *oldSeen = [NSMutableArray array];
  id oldToken = [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [oldSeen addObject:e.name];
  }];
  [self raw:hub name:@"E1"];
  [hub detach:oldToken];
  NSMutableArray *newSeen = [NSMutableArray array];
  [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [newSeen addObject:e.name];
  }];
  [self raw:hub name:@"E2"];
  dispatch_resume(_fakeMain);
  [self drain];
  XCTAssertEqual(oldSeen.count, 0u);
  XCTAssertEqualObjects(newSeen, (@[ @"E1", @"E2" ]));
}

/// Detaching with several events in flight keeps their order, ahead of newer ones.
- (void)testEventsInFlightAtDetachGoBackToTheFrontInOrder {
  BGSFlutterLifecycleHub *hub = [self hub];
  dispatch_suspend(_fakeMain);
  id token = [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
  }];
  [self raw:hub name:@"E1"];
  [self raw:hub name:@"E2"];
  [hub detach:token];
  [self raw:hub name:@"E3"];
  dispatch_resume(_fakeMain);
  [self drain];
  NSMutableArray *seen = [self attachNames:hub token:NULL];
  XCTAssertEqualObjects(seen, (@[ @"E1", @"E2", @"E3" ]));
}

/// The in-flight copies belong to the detached receiver, not to the others.
- (void)testDetachingOneOfTwoReceiversDropsOnlyItsOwnInFlightEvents {
  BGSFlutterLifecycleHub *hub = [self hub];
  dispatch_suspend(_fakeMain);
  NSMutableArray *a = [NSMutableArray array];
  NSMutableArray *b = [NSMutableArray array];
  id ta = [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [a addObject:e.name];
  }];
  [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
    [b addObject:e.name];
  }];
  [self raw:hub name:@"E1"];
  [hub detach:ta];
  dispatch_resume(_fakeMain);
  [self drain];
  XCTAssertEqual(a.count, 0u);
  XCTAssertEqualObjects(b, @[ @"E1" ]);
  XCTAssertEqual(hub.bufferedCount, 0u, @"nothing is duplicated into the buffer");
}

/// A queueing sink (the Swift pump) hands back what it took but never sent: that goes to
/// the front, ahead of what was still waiting for the sink, so order is kept.
- (void)testUndeliveredEventsHandedBackAtDetachGoFirstInOrder {
  BGSFlutterLifecycleHub *hub = [self hub];
  dispatch_suspend(_fakeMain);
  id token = [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
  }];
  [self raw:hub name:@"E3"];  // still waiting for the sink
  BGSFlutterLifecycleEvent *e1 = [BGSFlutterLifecycleHub eventForRawName:[P stringByAppendingString:@"E1"] data:nil];
  BGSFlutterLifecycleEvent *e2 = [BGSFlutterLifecycleHub eventForRawName:[P stringByAppendingString:@"E2"] data:nil];
  [hub detach:token undelivered:@[ e1, e2 ]];
  dispatch_resume(_fakeMain);
  [self drain];
  NSMutableArray *seen = [self attachNames:hub token:NULL];
  XCTAssertEqualObjects(seen, (@[ @"E1", @"E2", @"E3" ]));
}

/// With another receiver still attached, handed-back events are not buffered (it has its own copy).
- (void)testUndeliveredEventsAreNotBufferedWhileAnotherReceiverRemains {
  BGSFlutterLifecycleHub *hub = [self hub];
  id a = [self attachToken:hub];
  [self attachNames:hub token:NULL];
  BGSFlutterLifecycleEvent *e1 = [BGSFlutterLifecycleHub eventForRawName:[P stringByAppendingString:@"E1"] data:nil];
  [hub detach:a undelivered:@[ e1 ]];
  XCTAssertEqual(hub.bufferedCount, 0u);
}

- (id)attachToken:(BGSFlutterLifecycleHub *)hub {
  return [hub attachSink:^(BGSFlutterLifecycleEvent *e) {
  }];
}

- (void)testDropsAreCountedEvenWhenNotLogged {
  XCTAssertEqual([BGSFlutterLifecycleHub dropLogEvery], 100u);
  BGSFlutterLifecycleHub *hub = [self hub];
  for (NSUInteger i = 0; i < [BGSFlutterLifecycleHub bufferCapacity] + 250; i++) {
    [self raw:hub name:[NSString stringWithFormat:@"E%lu", (unsigned long)i]];
  }
  XCTAssertEqual(hub.droppedCount, 250u);
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
