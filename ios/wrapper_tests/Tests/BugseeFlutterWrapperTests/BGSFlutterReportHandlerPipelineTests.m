#import <XCTest/XCTest.h>
#import <sched.h>

#import "BGSFlutterFakeReport.h"
#import "BGSFlutterReportHandlerPipeline.h"

/// The one property everything here protects: the SDK's completion runs exactly once for every
/// dispatch, whichever of Dart, the deadline, a detach, a failure or an error gets there first
/// (workbook 7.1.2). Running it twice advances the SDK's chain twice; never running it stalls the
/// report until the SDK's own timeout.

@interface BGSManualTask : NSObject
@property(nonatomic, copy) dispatch_block_t block;
@property(nonatomic) int64_t delayMs;
@property(nonatomic) BOOL cancelled;
@end
@implementation BGSManualTask
@end

@interface BGSFlutterReportHandlerPipelineTests : XCTestCase
@end

@implementation BGSFlutterReportHandlerPipelineTests {
  BGSFlutterReportHandlerPipeline *_pipeline;
  NSMutableArray<BGSManualTask *> *_tasks;
  NSMutableArray<dispatch_block_t> *_platformQueue;
  NSMutableArray<NSString *> *_log;
  NSMutableArray<BGSFlutterReportRequest *> *_requests;
  NSMutableArray<dispatch_block_t> *_unreachable;
  BOOL _sinkThrows;
  BOOL _schedulerThrows;
  id _owner;
  BGSFlutterFakeReport *_report;
  NSUInteger _completions;
}

- (void)setUp {
  _tasks = [NSMutableArray array];
  _platformQueue = [NSMutableArray array];
  _log = [NSMutableArray array];
  _requests = [NSMutableArray array];
  _unreachable = [NSMutableArray array];
  _sinkThrows = NO;
  _schedulerThrows = NO;
  _completions = 0;
  _report = [[BGSFlutterFakeReport alloc] init];
  __weak typeof(self) weakSelf = self;
  _pipeline = [[BGSFlutterReportHandlerPipeline alloc]
      initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf->_schedulerThrows) {
          [NSException raise:NSInternalInconsistencyException format:@"scheduler is gone"];
        }
        BGSManualTask *t = [[BGSManualTask alloc] init];
        t.block = task;
        t.delayMs = delayMs;
        @synchronized(strongSelf->_tasks) {
          [strongSelf->_tasks addObject:t];
        }
        return t;
      }
      cancel:^(id token) {
        ((BGSManualTask *)token).cancelled = YES;
      }
      platformPost:^(dispatch_block_t task) {
        typeof(self) strongSelf = weakSelf;
        @synchronized(strongSelf->_platformQueue) {
          [strongSelf->_platformQueue addObject:[task copy]];
        }
      }
      log:^(NSString *line) {
        typeof(self) strongSelf = weakSelf;
        @synchronized(strongSelf->_log) {
          [strongSelf->_log addObject:line];
        }
      }];
  _owner = [_pipeline attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
    typeof(self) strongSelf = weakSelf;
    if (strongSelf->_sinkThrows) {
      [NSException raise:NSInternalInconsistencyException format:@"bridge is dead"];
    }
    [strongSelf->_requests addObject:request];
    [strongSelf->_unreachable addObject:[unreachable copy]];
  }];
  [_pipeline setPhasesForOwner:_owner before:YES after:YES];
}

- (void)drainPlatform {
  while (YES) {
    dispatch_block_t next = nil;
    @synchronized(_platformQueue) {
      if (_platformQueue.count == 0) {
        return;
      }
      next = _platformQueue.firstObject;
      [_platformQueue removeObjectAtIndex:0];
    }
    next();
  }
}

- (void)dispatch:(BGSFlutterReportPhase)phase terminating:(BOOL)terminating main:(BOOL)main {
  [_pipeline dispatchPhase:phase
                    report:_report
             isTerminating:terminating
              onMainThread:main
                completion:^{
                  @synchronized(self) {
                    self->_completions++;
                  }
                }];
}

- (BGSFlutterReportRequest *)delivered {
  [self drainPlatform];
  XCTAssertEqual(_requests.count, 1u);
  return _requests.firstObject;
}

- (void)fireDueEvenIfCancelled:(BOOL)evenIfCancelled {
  NSArray *copy;
  @synchronized(_tasks) {
    copy = [_tasks copy];
  }
  for (BGSManualTask *t in copy) {
    if (evenIfCancelled || !t.cancelled) {
      t.block();
    }
  }
}

#pragma mark - exactly once, on every path

- (void)testDartCompletingRunsTheCompletionOnce {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  XCTAssertEqual(_completions, 0u, @"the SDK is waiting for us; nothing has completed yet");
  BGSFlutterReportRequest *request = [self delivered];
  XCTAssertTrue([_pipeline completeHandle:request.handle]);
  XCTAssertEqual(_completions, 1u);
  XCTAssertFalse([_pipeline completeHandle:request.handle]);
  [self fireDueEvenIfCancelled:YES];
  [_pipeline detachOwner:_owner];
  XCTAssertEqual(_completions, 1u);
}

- (void)testTheDeadlineCompletesWhenDartNeverReplies {
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  [self delivered];
  XCTAssertEqual(_completions, 0u);
  [self fireDueEvenIfCancelled:NO];
  XCTAssertEqual(_completions, 1u);
  [self fireDueEvenIfCancelled:YES];
  XCTAssertEqual(_completions, 1u);
}

- (void)testALateReplyAfterTheDeadlineDoesNothing {
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  BGSFlutterReportRequest *request = [self delivered];
  [self fireDueEvenIfCancelled:NO];
  XCTAssertEqual(_completions, 1u);
  XCTAssertFalse([_pipeline completeHandle:request.handle]);
  XCTAssertEqual(_completions, 1u);
}

- (void)testAnUnreachableDartCompletesAtOnce {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [self delivered];
  _unreachable.firstObject();
  XCTAssertEqual(_completions, 1u);
  _unreachable.firstObject();
  [self fireDueEvenIfCancelled:YES];
  XCTAssertEqual(_completions, 1u);
}

- (void)testASinkThatThrowsCompletesAtOnce {
  _sinkThrows = YES;
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [self drainPlatform];
  XCTAssertEqual(_completions, 1u);
}

- (void)testASchedulerThatThrowsCompletesAtOnceAndLeavesNoLiveProxy {
  _schedulerThrows = YES;
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  XCTAssertEqual(_completions, 1u);
  XCTAssertNil([_pipeline reportForHandle:@"rh-1"]);
}

- (void)testDetachingTheEngineCompletesWhatWasHandedToIt {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [self delivered];
  [_pipeline detachOwner:_owner];
  XCTAssertEqual(_completions, 1u);
  [self fireDueEvenIfCancelled:YES];
  XCTAssertEqual(_completions, 1u);
}

- (void)testADetachBeforeTheRequestReachedDartSkipsDelivery {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [_pipeline detachOwner:_owner];
  [self drainPlatform];
  XCTAssertEqual(_completions, 1u);
  XCTAssertEqual(_requests.count, 0u, @"Dart is never asked about a handle that is already over");
}

- (void)testANullReportAndANullCompletionNeverThrow {
  __block NSUInteger n = 0;
  [_pipeline dispatchPhase:BGSFlutterReportPhaseBefore
                    report:nil
             isTerminating:NO
              onMainThread:YES
                completion:^{
                  n++;
                }];
  XCTAssertEqual(n, 1u);
  [_pipeline dispatchPhase:BGSFlutterReportPhaseBefore report:_report isTerminating:NO onMainThread:YES completion:nil];
  [_pipeline dispatchPhase:BGSFlutterReportPhaseAfter report:_report isTerminating:YES onMainThread:NO completion:nil];
}

- (void)testAThrowingSdkCompletionNeverEscapes {
  [_pipeline dispatchPhase:BGSFlutterReportPhaseBefore
                    report:_report
             isTerminating:YES
              onMainThread:YES
                completion:^{
                  [NSException raise:NSInternalInconsistencyException format:@"sdk fault"];
                }];
  [_pipeline dispatchPhase:BGSFlutterReportPhaseBefore
                    report:_report
             isTerminating:NO
              onMainThread:YES
                completion:^{
                  [NSException raise:NSInternalInconsistencyException format:@"sdk fault"];
                }];
  BGSFlutterReportRequest *request = [self delivered];
  [_pipeline completeHandle:request.handle];
}

#pragma mark - when Dart is not asked

- (void)testTerminatingNeverReachesDartNorTouchesTheReport {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:YES main:YES];
  [self dispatch:BGSFlutterReportPhaseAfter terminating:YES main:NO];
  XCTAssertEqual(_completions, 2u);
  XCTAssertEqual(_tasks.count, 0u);
  XCTAssertEqual(_platformQueue.count, 0u);
  XCTAssertEqual(_requests.count, 0u);
  XCTAssertEqual(_report.reads, 0u, @"not even the id was read on a dying process");
}

- (void)testNoRegisteredHandlerCompletesAtOnceWithoutWaiting {
  [_pipeline setPhasesForOwner:_owner before:NO after:NO];
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:NO];
  XCTAssertEqual(_completions, 2u);
  XCTAssertEqual(_tasks.count, 0u);
  XCTAssertEqual(_platformQueue.count, 0u);
}

- (void)testOnlyTheRegisteredPhaseReachesDart {
  [_pipeline setPhasesForOwner:_owner before:NO after:YES];
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  XCTAssertEqual(_completions, 1u);
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  XCTAssertEqual(_completions, 1u);
  XCTAssertTrue([self delivered].after);
}

- (void)testNoAttachedDartCompletesAtOnce {
  [_pipeline detachOwner:_owner];
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  XCTAssertEqual(_completions, 1u);
}

- (void)testAReportThatLooksLikeARecoveredCrashIsNotTreatedAsOne {
  // 7.2.3: type + isTerminating say nothing about recovery. A crash-typed report is delivered
  // like any other, with its type passed through verbatim.
  _report.fakeType = @"crash";
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:NO];
  XCTAssertEqualObjects([self delivered].type, @"crash");
  XCTAssertEqual(_completions, 0u);
}

#pragma mark - the deadline is inside the SDK's

- (void)testTheLiveDeadlineIsInsideTheSdksThirtySeconds {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  XCTAssertEqual(_tasks.count, 1u);
  XCTAssertEqual(_tasks.firstObject.delayMs, 20000);
  XCTAssertLessThan(_tasks.firstObject.delayMs, BGSFlutterReportSdkLiveHandlerTimeoutMs);
  XCTAssertLessThanOrEqual([self delivered].deadlineMs, 20000);
}

- (void)testTheRecoveryDeadlineIsInsideTheSdksBoundedCap {
  // Off the main thread: the SDK waits 3 s for the handler to return and does not wait for the
  // completion; a late completion re-persists the report. Ours is inside the cap.
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:NO];
  XCTAssertEqual(_tasks.firstObject.delayMs, 2000);
  XCTAssertLessThan(_tasks.firstObject.delayMs, BGSFlutterReportSdkBoundedCapMs);
  XCTAssertEqual(BGSFlutterReportDeadlineMs(YES), BGSFlutterReportLiveDeadlineMs);
  XCTAssertEqual(BGSFlutterReportDeadlineMs(NO), BGSFlutterReportRecoveryDeadlineMs);
}

- (void)testALateCompletionAfterTheRecoveryCapStillRunsTheCompletionOnce {
  // The SDK re-persists the report when a late completion arrives. Ours must run it exactly
  // once however late: here the deadline came first and Dart's reply after.
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:NO];
  BGSFlutterReportRequest *request = [self delivered];
  [self fireDueEvenIfCancelled:NO];
  XCTAssertEqual(_completions, 1u);
  XCTAssertFalse([_pipeline completeHandle:request.handle]);
  XCTAssertEqual(_completions, 1u);
  XCTAssertNil([_pipeline reportForHandle:request.handle]);
}

#pragma mark - the window is measured, and what is observable of the SDK's wait is deducted

- (BGSFlutterReportHandlerPipeline *)pipelineWithClock:(int64_t *)clock owner:(id *)owner {
  __weak typeof(self) weakSelf = self;
  BGSFlutterReportHandlerPipeline *p = [[BGSFlutterReportHandlerPipeline alloc]
      initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
        typeof(self) strongSelf = weakSelf;
        BGSManualTask *t = [[BGSManualTask alloc] init];
        t.block = task;
        t.delayMs = delayMs;
        @synchronized(strongSelf->_tasks) {
          [strongSelf->_tasks addObject:t];
        }
        return t;
      }
      cancel:^(id token) {
        ((BGSManualTask *)token).cancelled = YES;
      }
      platformPost:^(dispatch_block_t task) {
        typeof(self) strongSelf = weakSelf;
        @synchronized(strongSelf->_platformQueue) {
          [strongSelf->_platformQueue addObject:[task copy]];
        }
      }
      log:^(NSString *line) {
        typeof(self) strongSelf = weakSelf;
        @synchronized(strongSelf->_log) {
          [strongSelf->_log addObject:line];
        }
      }
      clock:^int64_t {
        return *clock;
      }];
  *owner = [p attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
    typeof(self) strongSelf = weakSelf;
    [strongSelf->_requests addObject:request];
  }];
  [p setPhasesForOwner:*owner before:YES after:YES];
  return p;
}

- (void)testDartIsToldWhatIsLeftOfTheWindowNotTheWholeOfIt {
  int64_t clock = 0;
  id owner = nil;
  BGSFlutterReportHandlerPipeline *p = [self pipelineWithClock:&clock owner:&owner];
  [p dispatchPhase:BGSFlutterReportPhaseBefore report:_report isTerminating:NO onMainThread:YES completion:^{ self->_completions++; }];
  clock = 7000;  // main was busy for 7 s
  [self drainPlatform];
  XCTAssertEqual(_requests.count, 1u);
  XCTAssertEqual(_requests.firstObject.deadlineMs, 13000);
  XCTAssertTrue([[_log componentsJoinedByString:@"\n"] containsString:@"delivery gap=7000"], @"the gap is logged");
}

- (void)testAWindowThatIsAlreadyOverIsNotOfferedToDart {
  int64_t clock = 0;
  id owner = nil;
  BGSFlutterReportHandlerPipeline *p = [self pipelineWithClock:&clock owner:&owner];
  [p dispatchPhase:BGSFlutterReportPhaseBefore report:_report isTerminating:NO onMainThread:YES completion:^{ self->_completions++; }];
  clock = 20000;
  [self drainPlatform];
  XCTAssertEqual(_completions, 1u, @"completed, not delivered");
  XCTAssertEqual(_requests.count, 0u);
  XCTAssertNil([p reportForHandle:@"rh-1"]);
  XCTAssertTrue([[_log componentsJoinedByString:@"\n"] containsString:@"completed by=expired"]);
}

- (void)testTheBudgetHelpers {
  XCTAssertEqual(BGSFlutterReportMarginMs(30000), 10000);
  XCTAssertEqual(BGSFlutterReportMarginMs(120000), 10000);
  XCTAssertEqual(BGSFlutterReportMarginMs(3000), 1000);
  XCTAssertEqual(BGSFlutterReportLiveDeadlineMs, BGSFlutterReportSdkLiveHandlerTimeoutMs - BGSFlutterReportMarginMs(BGSFlutterReportSdkLiveHandlerTimeoutMs));
  XCTAssertEqual(BGSFlutterReportRecoveryDeadlineMs, BGSFlutterReportSdkBoundedCapMs - BGSFlutterReportMarginMs(BGSFlutterReportSdkBoundedCapMs));
  XCTAssertEqual(BGSFlutterReportRemainingMs(20000, 5000), 15000);
  XCTAssertEqual(BGSFlutterReportRemainingMs(20000, 99000), 0);
  XCTAssertEqual(BGSFlutterReportRemainingMs(20000, -5), 20000);
}

#pragma mark - hot restart

- (void)testANewIsolateCompletesWhatWasHandedToThePreviousOneAndForgetsItsPhases {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [self delivered];
  XCTAssertEqual(_completions, 0u);
  [_pipeline resetOwner:_owner];
  XCTAssertEqual(_completions, 1u, @"completed now, not at its deadline");
  [self fireDueEvenIfCancelled:YES];
  XCTAssertEqual(_completions, 1u);
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  XCTAssertEqual(_completions, 2u, @"no phase is registered until the new isolate says so");
  XCTAssertTrue([[_log componentsJoinedByString:@"\n"] containsString:@"completed by=reset"]);
}

- (void)testResettingOneEngineLeavesTheOthersHandlesAlone {
  id owner2 = [_pipeline attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
  }];
  [_pipeline setPhasesForOwner:owner2 before:YES after:YES];
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [self drainPlatform];
  [_pipeline resetOwner:_owner];
  XCTAssertEqual(_completions, 0u);
  [_pipeline resetOwner:owner2];
  XCTAssertEqual(_completions, 1u);
}

#pragma mark - check-and-apply is one step

/// An edit reported as applied must have landed BEFORE the completion ran. The report is slow to
/// apply (the window the old check-then-apply race lived in) while the deadline fires on another
/// thread, many times over. The summary is `nonatomic, copy`, so the old race was also a data race.
- (void)testAnEditReportedAppliedNeverLandsAfterTheCompletion {
  NSUInteger applied = 0, refused = 0;
  for (NSUInteger i = 0; i < 1500; i++) {
    __block dispatch_block_t deadline = nil;
    __block BGSFlutterReportRequest *request = nil;
    NSObject *lock = [[NSObject alloc] init];
    __block NSUInteger completed = 0;
    __block NSUInteger landedAfter = 0;
    BGSFlutterFakeReport *report = [[BGSFlutterFakeReport alloc] init];
    report.beforeSetSummary = ^{
      CFAbsoluteTime until = CFAbsoluteTimeGetCurrent() + 0.00003;
      while (CFAbsoluteTimeGetCurrent() < until) {
        sched_yield();
      }
    };
    report.onSummarySet = ^{
      @synchronized(lock) {
        if (completed > 0) {
          landedAfter++;
        }
      }
    };
    BGSFlutterReportHandlerPipeline *p = [[BGSFlutterReportHandlerPipeline alloc]
        initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
          deadline = [task copy];
          return @"t";
        }
        cancel:^(id token) {
        }
        platformPost:^(dispatch_block_t task) {
          task();
        }
        log:^(NSString *line) {
        }];
    id owner = [p attachSink:^(BGSFlutterReportRequest *r, dispatch_block_t u) {
      request = r;
    }];
    [p setPhasesForOwner:owner before:YES after:YES];
    [p dispatchPhase:BGSFlutterReportPhaseBefore
              report:report
       isTerminating:NO
        onMainThread:YES
          completion:^{
            @synchronized(lock) {
              completed++;
            }
          }];
    __block BGSFlutterReportEditResult result = BGSFlutterReportEditNotLive;
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_semaphore_t go = dispatch_semaphore_create(0);
    dispatch_group_async(group, q, ^{
      dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER);
      result = [p editHandle:request.handle
                        edit:^BOOL(id r, NSError **e) {
                          ((id<BGSReportContract>)r).summary = @"x";
                          return YES;
                        }
                       error:NULL];
    });
    dispatch_group_async(group, q, ^{
      dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER);
      deadline();
    });
    dispatch_semaphore_signal(go);
    dispatch_semaphore_signal(go);
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    if (result == BGSFlutterReportEditApplied) {
      applied++;
    } else {
      refused++;
    }
    XCTAssertEqual(landedAfter, 0u, @"round %lu", (unsigned long)i);
    XCTAssertEqual(completed, 1u);
  }
  XCTAssertTrue(applied > 0 && refused > 0, @"the race was exercised both ways: applied=%lu refused=%lu",
                (unsigned long)applied, (unsigned long)refused);
}

#pragma mark - the proxy is live only until the completion runs (7.3.4)

- (void)testAMutationBeforeCompletionAppliesAndAfterItIsIgnored {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  BGSFlutterReportRequest *request = [self delivered];
  NSError *error = nil;
  XCTAssertEqual([_pipeline editHandle:request.handle
                                  edit:^BOOL(id report, NSError **e) {
                                    ((id<BGSReportContract>)report).summary = @"early";
                                    return YES;
                                  }
                                 error:&error],
                 BGSFlutterReportEditApplied);
  XCTAssertEqualObjects(_report.fakeSummary, @"early");

  [_pipeline completeHandle:request.handle];
  XCTAssertEqual([_pipeline editHandle:request.handle
                                  edit:^BOOL(id report, NSError **e) {
                                    ((id<BGSReportContract>)report).summary = @"late";
                                    return YES;
                                  }
                                 error:&error],
                 BGSFlutterReportEditNotLive);
  XCTAssertEqualObjects(_report.fakeSummary, @"early");
  XCTAssertNil([_pipeline reportForHandle:request.handle]);
}

- (void)testAMutationAfterTheDeadlineIsIgnoredToo {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  BGSFlutterReportRequest *request = [self delivered];
  [self fireDueEvenIfCancelled:NO];
  XCTAssertEqual([_pipeline editHandle:request.handle
                                  edit:^BOOL(id report, NSError **e) {
                                    ((id<BGSReportContract>)report).summary = @"late";
                                    return YES;
                                  }
                                 error:NULL],
                 BGSFlutterReportEditNotLive);
  XCTAssertNil(_report.fakeSummary);
}

- (void)testAnUnknownHandleIsRefusedNotAnError {
  XCTAssertEqual([_pipeline editHandle:@"rh-999" edit:^BOOL(id r, NSError **e) { return YES; } error:NULL],
                 BGSFlutterReportEditNotLive);
  XCTAssertEqual([_pipeline editHandle:nil edit:^BOOL(id r, NSError **e) { return YES; } error:NULL],
                 BGSFlutterReportEditNotLive);
}

#pragma mark - identity of a delivery

- (void)testADeliveryIdIsStableForOneReportAndPhaseAndTheHandleIsNot {
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [self drainPlatform];
  XCTAssertEqual(_requests.count, 3u);
  XCTAssertEqualObjects(_requests[0].deliveryId, @"after:report-1");
  XCTAssertEqualObjects(_requests[0].deliveryId, _requests[1].deliveryId);
  XCTAssertNotEqualObjects(_requests[0].handle, _requests[1].handle);
  XCTAssertEqualObjects(_requests[2].deliveryId, @"before:report-1");
  XCTAssertTrue(_requests[0].after);
  XCTAssertFalse(_requests[2].after);
}

- (void)testAnUnreadableIdIsNeverShared {
  _report.fakeReportId = @"";
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  [self drainPlatform];
  XCTAssertNotEqualObjects(_requests[0].deliveryId, _requests[1].deliveryId);
}

#pragma mark - several engines

- (void)testTheMostRecentEngineWithAHandlerGetsTheDeliveryAndDetachingOneLeavesTheOther {
  NSMutableArray *second = [NSMutableArray array];
  id owner2 = [_pipeline attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
    [second addObject:request];
  }];
  [_pipeline setPhasesForOwner:owner2 before:YES after:NO];
  [self dispatch:BGSFlutterReportPhaseBefore terminating:NO main:YES];
  [self drainPlatform];
  XCTAssertEqual(second.count, 1u);
  XCTAssertEqual(_requests.count, 0u);
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  [self drainPlatform];
  XCTAssertEqual(_requests.count, 1u, @"the second engine has no after handler; the first does");
  [_pipeline detachOwner:_owner];
  XCTAssertEqual(_completions, 1u, @"only the first engine's handle was completed by its detach");
  [_pipeline detachOwner:owner2];
  XCTAssertEqual(_completions, 2u);
}

#pragma mark - threads: the deadlock this design exists to avoid

/// The live path calls the handler ON THE MAIN THREAD, and Dart's reply is delivered by the main
/// thread. A dispatch that waited for the reply would block the very thread that must deliver it.
/// Here the dispatch runs on main (XCTest's own thread) with the real main-queue hop: it must
/// return before the completion has run, and the reply, queued on main behind it, must then
/// complete it. A blocking implementation never comes back from the dispatch.
- (void)testDispatchingOnTheMainThreadNeverWaitsForDart {
  XCTAssertTrue([NSThread isMainThread]);
  __block NSUInteger completions = 0;
  BGSFlutterReportHandlerPipeline *pipeline = [[BGSFlutterReportHandlerPipeline alloc]
      initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
        return @"timer";
      }
      cancel:^(id token) {
      }
      platformPost:^(dispatch_block_t task) {
        dispatch_async(dispatch_get_main_queue(), task);
      }
      log:^(NSString *line) {
      }];
  XCTestExpectation *completed = [self expectationWithDescription:@"completed by Dart's reply"];
  id owner = [pipeline attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
    // "Dart": answers on the main queue, as the real reply is delivered there.
    dispatch_async(dispatch_get_main_queue(), ^{
      [pipeline completeHandle:request.handle];
    });
  }];
  [pipeline setPhasesForOwner:owner before:YES after:YES];

  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  [pipeline dispatchPhase:BGSFlutterReportPhaseBefore
                   report:_report
            isTerminating:NO
             onMainThread:[NSThread isMainThread]
               completion:^{
                 completions++;
                 [completed fulfill];
               }];
  // A wait that gave up after a timeout would still "return", so time it.
  XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 0.5, @"dispatch returned at once");
  XCTAssertEqual(completions, 0u, @"dispatch returned before the completion ran");
  [self waitForExpectations:@[ completed ] timeout:5];
  XCTAssertEqual(completions, 1u);
}

/// A recovery dispatch comes from a GCD worker while the main thread is busy: it must come back
/// without needing main, and the deadline still ends it.
- (void)testABlockedMainThreadDoesNotBlockARecoveryCaller {
  __block NSUInteger completions = 0;
  NSObject *lock = [[NSObject alloc] init];
  NSMutableArray<dispatch_block_t> *deadlines = [NSMutableArray array];
  BGSFlutterReportHandlerPipeline *pipeline = [[BGSFlutterReportHandlerPipeline alloc]
      initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
        @synchronized(lock) {
          [deadlines addObject:[task copy]];
        }
        return @"timer";
      }
      cancel:^(id token) {
      }
      platformPost:^(dispatch_block_t task) {
        dispatch_async(dispatch_get_main_queue(), task);  // main is blocked below
      }
      log:^(NSString *line) {
      }];
  id owner = [pipeline attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
  }];
  [pipeline setPhasesForOwner:owner before:YES after:YES];

  dispatch_semaphore_t returned = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
    [pipeline dispatchPhase:BGSFlutterReportPhaseAfter
                     report:self->_report
              isTerminating:NO
               onMainThread:NO
                 completion:^{
                   @synchronized(lock) {
                     completions++;
                   }
                 }];
    dispatch_semaphore_signal(returned);
  });
  // Main is held here, NOT servicing its queue (a semaphore, not a run loop), until the worker
  // has come back: the worker's dispatch must not have needed main.
  XCTAssertEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0,
                 @"the worker's dispatch returned while main was blocked");
  @synchronized(lock) {
    XCTAssertEqual(completions, 0u);
    XCTAssertEqual(deadlines.count, 1u);
    deadlines.firstObject();
    XCTAssertEqual(completions, 1u);
  }
}

#pragma mark - concurrency

- (void)testEveryRaceForTheCompletionRunsItOnce {
  for (NSUInteger round = 0; round < 200; round++) {
    __block NSUInteger ran = 0;
    NSObject *lock = [[NSObject alloc] init];
    __block dispatch_block_t deadline = nil;
    __block BGSFlutterReportRequest *request = nil;
    __block dispatch_block_t unreachable = nil;
    BGSFlutterReportHandlerPipeline *pipeline = [[BGSFlutterReportHandlerPipeline alloc]
        initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
          deadline = [task copy];
          return @"t";
        }
        cancel:^(id token) {
        }
        platformPost:^(dispatch_block_t task) {
          task();
        }
        log:^(NSString *line) {
        }];
    id owner = [pipeline attachSink:^(BGSFlutterReportRequest *r, dispatch_block_t u) {
      request = r;
      unreachable = [u copy];
    }];
    [pipeline setPhasesForOwner:owner before:YES after:YES];
    [pipeline dispatchPhase:BGSFlutterReportPhaseBefore
                     report:_report
              isTerminating:NO
               onMainThread:YES
                 completion:^{
                   @synchronized(lock) {
                     ran++;
                   }
                 }];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_async(group, q, ^{ [pipeline completeHandle:request.handle]; });
    dispatch_group_async(group, q, ^{ deadline(); });
    dispatch_group_async(group, q, ^{ [pipeline detachOwner:owner]; });
    dispatch_group_async(group, q, ^{ unreachable(); });
    XCTAssertEqual(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0);
    XCTAssertEqual(ran, 1u, @"round %lu", (unsigned long)round);
  }
}

#pragma mark - the outcome is logged

- (void)testEveryOutcomeIsOneLogLine {
  [self dispatch:BGSFlutterReportPhaseBefore terminating:YES main:YES];
  XCTAssertEqual(_log.count, 1u);
  XCTAssertTrue([_log[0] containsString:@"completed by=terminating"]);
  [self dispatch:BGSFlutterReportPhaseAfter terminating:NO main:YES];
  BGSFlutterReportRequest *request = [self delivered];
  [_pipeline completeHandle:request.handle];
  XCTAssertTrue([_log.lastObject containsString:@"completed by=dart"]);
}

@end
