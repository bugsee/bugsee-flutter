#import <XCTest/XCTest.h>

@import Bugsee;

#import "BGSFlutterFakeReport.h"
#import "BGSFlutterReportFileFlow.h"

/// The file operations and the createReport flow with the threads made explicit: the worker and the
/// platform thread are queues the test drains, so what runs where, and in what order, is asserted.
@interface BGSFlowQueue : NSObject
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *tasks;
@property(nonatomic) BOOL accept;
@end
@implementation BGSFlowQueue
- (instancetype)init {
  self = [super init];
  if (self) {
    _tasks = [NSMutableArray array];
    _accept = YES;
  }
  return self;
}
- (BOOL)execute:(dispatch_block_t)task {
  if (_accept) {
    [_tasks addObject:[task copy]];
  }
  return _accept;
}
- (NSUInteger)drain {
  NSUInteger n = 0;
  while (_tasks.count > 0) {
    dispatch_block_t next = _tasks.firstObject;
    [_tasks removeObjectAtIndex:0];
    next();
    n++;
  }
  return n;
}
@end

@interface BGSFlowSdk : NSObject <BGSFlutterCreatedReportSdk>
@property(nonatomic, copy) void (^createCompletion)(id);
@property(nonatomic, strong) NSMutableArray *uploaded;
/// How many attachments the report held at the moment the SDK was handed it.
@property(nonatomic, strong) NSMutableArray<NSNumber *> *countsAtUpload;
@property(nonatomic, copy) dispatch_block_t uploadDone;
@property(nonatomic) BOOL throwOnCreate;
@property(nonatomic) BOOL throwOnUpload;
@end
@implementation BGSFlowSdk
- (instancetype)init {
  self = [super init];
  if (self) {
    _uploaded = [NSMutableArray array];
    _countsAtUpload = [NSMutableArray array];
  }
  return self;
}
- (void)createReportWithCompletion:(void (^)(id))completion {
  if (_throwOnCreate) {
    [NSException raise:NSInternalInconsistencyException format:@"sdk is gone"];
  }
  _createCompletion = [completion copy];
}
- (void)uploadReport:(id)report completion:(void (^)(void))completion {
  if (_throwOnUpload) {
    [NSException raise:NSInternalInconsistencyException format:@"sdk is gone"];
  }
  [_uploaded addObject:report];
  [_countsAtUpload addObject:@([(BugseeExtendedReport *)report attachments].count)];
  _uploadDone = [completion copy];
}
@end

@interface BGSFlowTask : NSObject
@property(nonatomic, copy) dispatch_block_t block;
@property(nonatomic) BOOL cancelled;
@end
@implementation BGSFlowTask
@end

/// A report whose SDK raises.
@interface BGSRaisingReport : BGSFlutterFakeReport
@end
@implementation BGSRaisingReport
- (void)clearAttachments {
  [NSException raise:NSInternalInconsistencyException format:@"the SDK raised, with /secret/path in it"];
}
@end

@interface BGSFlutterReportFileFlowTests : XCTestCase
@end

@implementation BGSFlutterReportFileFlowTests {
  BGSFlowQueue *_worker;
  BGSFlowQueue *_createdWorker;
  BGSFlowQueue *_main;
  BGSFlowSdk *_sdk;
  NSMutableArray<BGSFlowTask *> *_createdTimers;
  NSMutableArray<BGSFlowTask *> *_pipelineTimers;
  NSMutableArray<BGSFlowTask *> *_uploadTimers;
  int64_t _clockMs;
  id _engine;
  BGSFlutterReportHandlerPipeline *_pipeline;
  BGSFlutterReportFileFlow *_flow;
  BGSFlutterFakeReport *_handlerReport;
  NSUInteger _completions;
  NSString *_dir;
  NSString *_file;
  id _owner;
  NSString *_handleId;
}

- (void)setUp {
  _worker = [[BGSFlowQueue alloc] init];
  _createdWorker = [[BGSFlowQueue alloc] init];
  _main = [[BGSFlowQueue alloc] init];
  _sdk = [[BGSFlowSdk alloc] init];
  _createdTimers = [NSMutableArray array];
  _pipelineTimers = [NSMutableArray array];
  _uploadTimers = [NSMutableArray array];
  _clockMs = 0;
  _engine = [NSObject new];
  _completions = 0;
  _handlerReport = [[BGSFlutterFakeReport alloc] init];
  _dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  [NSFileManager.defaultManager createDirectoryAtPath:[_dir stringByAppendingPathComponent:@"storage"] withIntermediateDirectories:YES attributes:nil error:NULL];
  _handlerReport.storagePath = [_dir stringByAppendingPathComponent:@"storage"];
  _file = [_dir stringByAppendingPathComponent:@"a.txt"];
  [@"abc" writeToFile:_file atomically:YES encoding:NSUTF8StringEncoding error:NULL];

  __weak typeof(self) weak = self;
  _pipeline = [[BGSFlutterReportHandlerPipeline alloc]
      initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
        BGSFlowTask *t = [[BGSFlowTask alloc] init];
        t.block = task;
        [[weak pipelineTimersForTest] addObject:t];
        return t;
      }
      cancel:^(id token) {
        ((BGSFlowTask *)token).cancelled = YES;
      }
      platformPost:^(dispatch_block_t task) {
        task();
      }
      log:^(NSString *line) {
      }
      clock:^int64_t {
        return [weak clockForTest];
      }];
  BGSFlutterCreatedReports *created = [[BGSFlutterCreatedReports alloc]
      initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
        BGSFlowTask *t = [[BGSFlowTask alloc] init];
        t.block = task;
        [[weak createdTimersForTest] addObject:t];
        return t;
      }
      cancel:^(id token) {
        ((BGSFlowTask *)token).cancelled = YES;
      }
      clock:^int64_t {
        return 0;
      }];
  _flow = [[BGSFlutterReportFileFlow alloc] initWithPipeline:_pipeline
                                                     created:created
                                                      worker:^BOOL(dispatch_block_t task) {
                                                        return [weak workerForTest:task];
                                                      }
                                               createdWorker:^BOOL(dispatch_block_t task) {
                                                 return [weak createdWorkerForTest:task];
                                               }
                                                        main:^(dispatch_block_t task) {
                                                          [weak mainForTest:task];
                                                        }
                                                         sdk:_sdk
                                                   scheduler:^id(dispatch_block_t task, int64_t delayMs) {
                                                     BGSFlowTask *t = [[BGSFlowTask alloc] init];
                                                     t.block = task;
                                                     [[weak uploadTimersForTest] addObject:t];
                                                     return t;
                                                   }
                                                      cancel:^(id token) {
                                                        BGSFlowTask *t = token;
                                                        t.cancelled = YES;
                                                        [[weak uploadTimersForTest] removeObject:t];
                                                      }
                                             createTimeoutMs:45000
                                             uploadTimeoutMs:45000];
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtPath:_dir error:NULL];
}

- (NSMutableArray<BGSFlowTask *> *)pipelineTimersForTest {
  return _pipelineTimers;
}
- (int64_t)clockForTest {
  return _clockMs;
}
- (NSMutableArray<BGSFlowTask *> *)uploadTimersForTest {
  return _uploadTimers;
}
- (NSMutableArray<BGSFlowTask *> *)createdTimersForTest {
  return _createdTimers;
}
- (BOOL)createdWorkerForTest:(dispatch_block_t)task {
  return [_createdWorker execute:task];
}
- (BOOL)workerForTest:(dispatch_block_t)task {
  return [_worker execute:task];
}
- (void)mainForTest:(dispatch_block_t)task {
  [_main execute:task];
}

/// Delivers a report to the pipeline with a registered Dart end and returns the live handle.
- (NSString *)liveHandle {
  __block NSString *handle = nil;
  _owner = [_pipeline attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
    handle = request.handle;
  }];
  [_pipeline setPhasesForOwner:_owner before:YES after:YES];
  [_pipeline dispatchPhase:BGSFlutterReportPhaseBefore
                    report:_handlerReport
             isTerminating:NO
              onMainThread:YES
                completion:^{
                  self->_completions++;
                }];
  _handleId = handle;
  return handle;
}

/// Runs every queue until all are empty (a worker task posts to main, a main task may queue more).
- (void)drainAll {
  while (_worker.tasks.count + _createdWorker.tasks.count + _main.tasks.count > 0) {
    [_worker drain];
    [_createdWorker drain];
    [_main drain];
  }
}

/// Collects replies as `value|code`.
- (BGSFlutterFlowReply)collector:(NSMutableArray *)into {
  return ^(id value, NSString *code, NSString *message) {
    [into addObject:code != nil ? [@"error:" stringByAppendingString:code] : (value ?: @"ok")];
  };
}

#pragma mark - A handler's report

- (void)testAHandlersFileOperationRunsOnTheWorkerAndRepliesOnTheMainThread {
  NSString *handle = [self liveHandle];
  NSMutableArray *got = [NSMutableArray array];
  [_flow handlerAddFile:handle path:_file name:@"a" mimeType:nil move:NO reply:[self collector:got]];
  XCTAssertEqual(_handlerReport.adds.count, 0u, @"nothing ran on the calling (platform) thread");
  XCTAssertEqual(_worker.tasks.count, 1u);
  [_worker drain];
  XCTAssertEqual(_handlerReport.adds.count, 1u);
  XCTAssertEqual(got.count, 0u, @"the reply is queued for the platform thread");
  [_main drain];
  XCTAssertEqualObjects(got, @[ @"ok" ]);
}

- (void)testAHandleThatIsNotLiveAnswersNotLiveAndTouchesNothing {
  NSMutableArray *got = [NSMutableArray array];
  [_flow handlerAddFile:@"rh-nope" path:_file name:@"a" mimeType:nil move:YES reply:[self collector:got]];
  XCTAssertEqual(_worker.tasks.count, 0u);
  [_main drain];
  XCTAssertEqualObjects(got, @[ BGSFlutterFileNotLive ]);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:_file]);
}

- (void)testARefusalIsACodeAndABadArgumentAnErrorReply {
  NSString *handle = [self liveHandle];
  NSMutableArray *got = [NSMutableArray array];
  [_flow handlerAddFile:handle path:@"/no/such/file" name:@"a" mimeType:nil move:NO reply:[self collector:got]];
  [_flow handlerAddFile:handle path:@"relative" name:@"a" mimeType:nil move:NO reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqualObjects(got, (@[ BGSFlutterFileNotFound, @"error:invalid-argument" ]));
}

- (void)testAFullQueueAnswersBusyAndReleasesTheClaim {
  NSString *handle = [self liveHandle];
  _worker.accept = NO;
  NSMutableArray *got = [NSMutableArray array];
  [_flow handlerAddFile:handle path:_file name:@"a" mimeType:nil move:YES reply:[self collector:got]];
  [_main drain];
  XCTAssertEqualObjects(got, @[ BGSFlutterFileBusy ]);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:_file], @"a refused move did not consume the file");
  // The claim ended: the handle completes at once instead of waiting for it.
  XCTAssertTrue([_pipeline completeHandle:handle]);
  XCTAssertEqual(_completions, 1u);
}

- (void)testTheSdksCompletionWaitsForAFileOperationThatStartedWhileTheHandleWasLive {
  NSString *handle = [self liveHandle];
  NSMutableArray *got = [NSMutableArray array];
  [_flow handlerAddFile:handle path:_file name:@"a" mimeType:nil move:NO reply:[self collector:got]];
  // The handler returns (Dart completes the handle) BEFORE the worker got to the copy.
  XCTAssertTrue([_pipeline completeHandle:handle]);
  XCTAssertEqual(_completions, 0u, @"the completion waits for the claim");
  XCTAssertNil([_pipeline reportForHandle:handle], @"and the handle is no longer live for new edits");
  NSMutableArray *late = [NSMutableArray array];
  [_flow handlerAddFile:handle path:_file name:@"late" mimeType:nil move:NO reply:[self collector:late]];
  [_main drain];
  XCTAssertEqualObjects(late, @[ BGSFlutterFileNotLive ]);

  [_worker drain];
  XCTAssertEqual(_handlerReport.adds.count, 1u, @"the copy landed before the completion");
  XCTAssertEqualObjects(_handlerReport.adds.firstObject[@"name"], @"a");
  XCTAssertEqual(_completions, 1u, @"the last claim released the completion");
  [_main drain];
  XCTAssertEqualObjects(got, @[ @"ok" ]);
}

- (void)testTheDeadlineAlsoWaitsForTheClaimAndRunsTheCompletionOnce {
  NSString *handle = [self liveHandle];
  [_flow handlerAddFile:handle path:_file name:@"a" mimeType:nil move:NO reply:[self collector:[NSMutableArray array]]];
  for (BGSFlowTask *timer in [_pipelineTimers copy]) {
    timer.block();
  }
  XCTAssertEqual(_completions, 0u);
  [_worker drain];
  XCTAssertEqual(_completions, 1u);
  XCTAssertFalse([_pipeline completeHandle:handle], @"a second complete is a no-op");
  XCTAssertEqual(_completions, 1u);
}

- (void)testTwoOperationsOnOneHandleCompleteAfterTheLastOne {
  NSString *handle = [self liveHandle];
  [_flow handlerAddFile:handle path:_file name:@"1" mimeType:nil move:NO reply:[self collector:[NSMutableArray array]]];
  [_flow handlerAddData:handle data:[NSData dataWithBytes:"x" length:1] name:@"2" mimeType:nil reply:[self collector:[NSMutableArray array]]];
  [_pipeline completeHandle:handle];
  dispatch_block_t first = _worker.tasks.firstObject;
  [_worker.tasks removeObjectAtIndex:0];
  first();
  XCTAssertEqual(_completions, 0u, @"one claim is still held");
  [_worker drain];
  XCTAssertEqual(_completions, 1u);
  XCTAssertEqual(_handlerReport.adds.count, 2u);
}

- (void)testAnExceptionFromTheSdkIsAnErrorReplyNotACrashAndTheClaimEnds {
  BGSRaisingReport *raising = [[BGSRaisingReport alloc] init];
  __block NSString *handle = nil;
  id owner = [_pipeline attachSink:^(BGSFlutterReportRequest *request, dispatch_block_t unreachable) {
    handle = request.handle;
  }];
  [_pipeline setPhasesForOwner:owner before:YES after:YES];
  [_pipeline dispatchPhase:BGSFlutterReportPhaseBefore
                    report:raising
             isTerminating:NO
              onMainThread:YES
                completion:^{
                  self->_completions++;
                }];
  NSMutableArray *got = [NSMutableArray array];
  [_flow handlerClearAttachments:handle reply:[self collector:got]];
  [_pipeline completeHandle:handle];
  XCTAssertEqual(_completions, 0u);
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"error:sdk-error" ], @"an NSException must not escape into Swift");
  XCTAssertEqual(_completions, 1u, @"and the claim ended, so the completion ran");
}

#pragma mark - createReport

- (BugseeExtendedReport *)newCreated {
  return [BugseeExtendedReport new];
}

- (NSString *)createWith:(NSMutableArray *)got report:(id)report {
  [_flow createForOwner:_engine ttlMs:600000 reply:[self collector:got]];
  XCTAssertNotNil(_sdk.createCompletion, @"the SDK was asked");
  _sdk.createCompletion(report);
  [self drainAll];
  return got.lastObject;
}

- (void)testCreateMintsAHandleAndReadsTheReport {
  NSMutableArray *got = [NSMutableArray array];
  BugseeExtendedReport *report = [self newCreated];
  [report setSummary:@"s"];
  NSString *handle = [self createWith:got report:report];
  XCTAssertEqualObjects(handle, @"cr-1");
  XCTAssertEqualObjects([_flow readCreated:handle].summary, @"s");
  XCTAssertNil([_flow readCreated:@"cr-9"]);
}

- (void)testASecondCreateWhileOneIsOutstandingIsBusyOnTheCallingThread {
  [self createWith:[NSMutableArray array] report:[self newCreated]];
  NSMutableArray *second = [NSMutableArray array];
  [_flow createForOwner:_engine ttlMs:1000 reply:^(id value, NSString *code, NSString *message) {
    [second addObject:code];
  }];
  XCTAssertEqualObjects(second, @[ BGSFlutterCreateBusy ], @"answered inline, no hop");
}

- (void)testWhenTheSdkMakesNoReportTheAnswerIsNilAndTheSlotFree {
  NSMutableArray *got = [NSMutableArray array];
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:got]];
  _sdk.createCompletion(nil);
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"ok" ]);
  _sdk.createCompletion = nil;
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:[NSMutableArray array]]];
  XCTAssertNotNil(_sdk.createCompletion, @"not busy");
}

- (void)testAnSdkThatThrowsFreesTheSlotAndIsAnErrorReply {
  _sdk.throwOnCreate = YES;
  NSMutableArray *got = [NSMutableArray array];
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"error:sdk-error" ]);
  _sdk.throwOnCreate = NO;
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:[NSMutableArray array]]];
  XCTAssertNotNil(_sdk.createCompletion, @"the slot is free");
}

- (void)testAnSdkThatNeverAnswersTimesOutAndItsLateReportIsNotPublished {
  NSMutableArray *got = [NSMutableArray array];
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:got]];
  void (^late)(id) = _sdk.createCompletion;
  _createdTimers.firstObject.block();
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"error:create-timeout" ]);
  late([self newCreated]);
  [self drainAll];
  XCTAssertEqual(got.count, 1u, @"no second reply");
  _sdk.createCompletion = nil;
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:[NSMutableArray array]]];
  XCTAssertNotNil(_sdk.createCompletion, @"the slot is not held by it");
}

- (void)testCreatedFileOperationsRunOnMainInOrderAndTheSourceStays {
  BugseeExtendedReport *report = [self newCreated];
  NSString *handle = [self createWith:[NSMutableArray array] report:report];
  NSMutableArray *got = [NSMutableArray array];
  [_flow createdAddFile:handle path:_file name:@"a" mimeType:@"text/plain" reply:[self collector:got]];
  [_flow createdAddData:handle data:[NSData dataWithBytes:"\1" length:1] name:@"b" mimeType:nil reply:[self collector:got]];
  XCTAssertEqual(report.attachments.count, 0u, @"queued, not run inline");
  [self drainAll];
  XCTAssertEqualObjects(got, (@[ @"ok", @"ok" ]));
  XCTAssertEqualObjects(report.attachments[0].name, @"a");
  XCTAssertEqualObjects(report.attachments[1].name, @"b");
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:_file]);
}

- (void)testACreatedOperationOnADeadHandleIsNotLive {
  NSMutableArray *got = [NSMutableArray array];
  [_flow createdAddFile:@"cr-77" path:_file name:@"a" mimeType:nil reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqualObjects(got, @[ BGSFlutterFileNotLive ]);
}

- (void)testAnOperationQueuedBeforeAnUploadStillLandsAndOneCalledAfterIsNotLive {
  BugseeExtendedReport *report = [self newCreated];
  NSString *handle = [self createWith:[NSMutableArray array] report:report];
  NSMutableArray *add = [NSMutableArray array];
  NSMutableArray *up = [NSMutableArray array];
  NSMutableArray *after = [NSMutableArray array];
  [_flow createdAddData:handle data:[NSData dataWithBytes:"\1" length:1] name:@"a" mimeType:nil reply:[self collector:add]];
  [_flow uploadCreated:handle reply:[self collector:up]];
  [_flow createdAddData:handle data:[NSData dataWithBytes:"\1" length:1] name:@"after" mimeType:nil reply:[self collector:after]];
  XCTAssertEqual(_sdk.uploaded.count, 0u);
  [self drainAll];  // the add, then the upload's hop, then the late reply
  XCTAssertEqual(report.attachments.count, 1u, @"the add landed first");
  XCTAssertEqual(_sdk.uploaded.count, 1u, @"then the SDK was handed the report");
  XCTAssertEqualObjects(after, @[ BGSFlutterFileNotLive ]);
  _sdk.uploadDone();
  [self drainAll];
  XCTAssertEqualObjects(add, @[ @"ok" ]);
  XCTAssertEqualObjects(up, @[ @YES ]);
}

- (void)testUploadFreesTheSlotAtOnceAndASecondUploadIsNo {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  NSMutableArray *first = [NSMutableArray array];
  NSMutableArray *second = [NSMutableArray array];
  [_flow uploadCreated:handle reply:[self collector:first]];
  [_flow uploadCreated:handle reply:[self collector:second]];
  [self drainAll];
  XCTAssertEqualObjects(second, @[ @"error:not-live" ], @"not 'the SDK declined': the report is gone");
  XCTAssertEqual(_sdk.uploaded.count, 1u);
  _sdk.uploadDone();
  [self drainAll];
  XCTAssertEqualObjects(first, @[ @YES ]);
  _sdk.createCompletion = nil;
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:[NSMutableArray array]]];
  XCTAssertNotNil(_sdk.createCompletion, @"not busy");
}

- (void)testAnSdkThatThrowsOnUploadIsAnErrorReplyAndTheReportIsGone {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  _sdk.throwOnUpload = YES;
  NSMutableArray *got = [NSMutableArray array];
  [_flow uploadCreated:handle reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"error:sdk-error" ]);
  XCTAssertNil([_flow readCreated:handle]);
}

- (void)testDiscardReleasesOnceAndLaterCallsAreNotLive {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  [_flow discardCreated:handle];
  [_flow discardCreated:handle];
  XCTAssertNil([_flow readCreated:handle]);
  NSMutableArray *got = [NSMutableArray array];
  [_flow createdClearAttachments:handle reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqualObjects(got, @[ BGSFlutterFileNotLive ]);
}

- (void)testTheTimeToLiveReleasesTheReportAndFreesTheSlot {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  BGSFlowTask *ttl = _createdTimers.lastObject;
  ttl.block();
  XCTAssertNil([_flow readCreated:handle]);
  _sdk.createCompletion = nil;
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:[NSMutableArray array]]];
  XCTAssertNotNil(_sdk.createCompletion, @"not busy");
}

- (void)testAResetReleasesTheOrphan {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  [_flow resetOwner:_engine];
  XCTAssertNil([_flow readCreated:handle]);
  [_flow resetOwner:_engine];
}

- (void)testApplyIsNoForADeadHandleAndAppliesToALiveOne {
  BugseeExtendedReport *report = [self newCreated];
  NSString *handle = [self createWith:[NSMutableArray array] report:report];
  BGSFlutterCreatedReportPatch *p = [BGSFlutterCreatedReportPatch new];
  p.setSummary = YES;
  p.summary = @"s";
  NSString *message = nil;
  XCTAssertTrue([_flow applyToCreated:handle patch:p message:&message]);
  XCTAssertNil(message);
  XCTAssertEqualObjects(report.summary, @"s");
  XCTAssertFalse([_flow applyToCreated:@"cr-9" patch:p message:&message]);
  p.severity = @9;
  XCTAssertTrue([_flow applyToCreated:handle patch:p message:&message]);
  XCTAssertNotNil(message, @"a bad field is a message, not an application");
}


#pragma mark - Phase 6 review

- (void)testAnUploadTheSdkNeverAnswersFailsClosedAndALateCompletionIsIgnored {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  NSMutableArray *got = [NSMutableArray array];
  [_flow uploadCreated:handle reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqual(_uploadTimers.count, 1u);
  _uploadTimers.firstObject.block();
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"error:upload-timeout" ]);
  _sdk.uploadDone();  // the SDK answers after all
  [self drainAll];
  XCTAssertEqual(got.count, 1u, @"exactly one answer");
}

- (void)testAnAnsweredUploadCancelsItsTimerAndALateTimerDoesNothing {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  NSMutableArray *got = [NSMutableArray array];
  [_flow uploadCreated:handle reply:[self collector:got]];
  [self drainAll];
  BGSFlowTask *timer = _uploadTimers.firstObject;
  _sdk.uploadDone();
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @YES ]);
  XCTAssertTrue(timer.cancelled);
  XCTAssertEqual(_uploadTimers.count, 0u);
  timer.block();  // already started when the cancel came
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @YES ]);
}

- (void)testAnSdkThatThrowsOnUploadCancelsTheTimerToo {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  _sdk.throwOnUpload = YES;
  NSMutableArray *got = [NSMutableArray array];
  [_flow uploadCreated:handle reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"error:sdk-error" ]);
  XCTAssertEqual(_uploadTimers.count, 0u);
}

- (void)testAHandlerOperationQueuedBehindASlowCopyDoesNotStartOnceTheWindowClosed {
  NSString *handle = [self liveHandle];
  NSMutableArray *got = [NSMutableArray array];
  [_flow handlerAddFile:handle path:_file name:@"late" mimeType:nil move:YES reply:[self collector:got]];
  _clockMs = 25000;  // the slow copy ahead of it took the handler's window (20 s) and more
  [_worker drain];
  [self drainAll];
  XCTAssertEqualObjects(got, @[ BGSFlutterFileNotLive ]);
  XCTAssertEqual(_handlerReport.adds.count, 0u, @"nothing was imported");
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:_file], @"and nothing was consumed");
}

- (void)testAnotherEnginesResetKeepsMyCreatedReport {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  [_flow resetOwner:[NSObject new]];
  XCTAssertNotNil([_flow readCreated:handle]);
  NSMutableArray *busy = [NSMutableArray array];
  [_flow createForOwner:[NSObject new]
                  ttlMs:1000
                  reply:^(id value, NSString *code, NSString *message) {
                    [busy addObject:code];
                  }];
  XCTAssertEqualObjects(busy, @[ BGSFlutterCreateBusy ]);
  [_flow resetOwner:_engine];
  XCTAssertNil([_flow readCreated:handle]);
}

- (void)testAnInFlightCreateSurvivesAnotherEnginesReset {
  NSMutableArray *got = [NSMutableArray array];
  [_flow createForOwner:_engine ttlMs:600000 reply:[self collector:got]];
  [_flow resetOwner:[NSObject new]];
  _sdk.createCompletion([self newCreated]);
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"cr-1" ]);
}

- (void)testAnInFlightCreateIsReleasedByItsOwnEnginesReset {
  NSMutableArray *got = [NSMutableArray array];
  [_flow createForOwner:_engine ttlMs:600000 reply:[self collector:got]];
  [_flow resetOwner:_engine];
  _sdk.createCompletion([self newCreated]);
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"ok" ], @"answered with none: the late report is not published");
}

- (void)testTooManyCreatesAreRateLimitedWithATypedCode {
  for (NSUInteger i = 0; i < BGSFlutterCreatedRateLimit; i++) {
    NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
    [_flow discardCreated:handle];
    _sdk.createCompletion = nil;
  }
  NSMutableArray *got = [NSMutableArray array];
  [_flow createForOwner:_engine ttlMs:1000 reply:[self collector:got]];
  XCTAssertEqualObjects(got, @[ @"error:create-rate-limited" ]);
  XCTAssertNil(_sdk.createCompletion, @"the SDK was not asked");
}

- (void)testACreatedEmptyFileIsRefusedLikeEmptyBytes {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  NSString *empty = [_dir stringByAppendingPathComponent:@"empty.txt"];
  [[NSData data] writeToFile:empty atomically:YES];
  NSMutableArray *got = [NSMutableArray array];
  [_flow createdAddFile:handle path:empty name:@"e" mimeType:nil reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqualObjects(got, @[ @"error:invalid-argument" ]);
}


- (void)testACreatedFileIsReadOffMainAndAppliedOnMain {
  BugseeExtendedReport *report = [self newCreated];
  NSString *handle = [self createWith:[NSMutableArray array] report:report];
  NSMutableArray *got = [NSMutableArray array];
  [_flow createdAddFile:handle path:_file name:@"a" mimeType:nil reply:[self collector:got]];
  XCTAssertEqual(_createdWorker.tasks.count, 1u, @"the read is queued on the created worker");
  XCTAssertEqual(_main.tasks.count, 0u, @"nothing was queued for main yet: no read or decode on the UI thread");
  [_createdWorker drain];
  // The file is gone before main runs: if the read had been left for main it would fail now.
  [NSFileManager.defaultManager removeItemAtPath:_file error:NULL];
  XCTAssertEqual(report.attachments.count, 0u, @"read, not yet applied");
  XCTAssertEqual(_main.tasks.count, 1u, @"the apply is on main");
  [_main drain];
  XCTAssertEqual(report.attachments.count, 1u);
  XCTAssertEqualObjects(got, @[ @"ok" ]);
}

- (void)testAnAddQueuedBeforeAnUploadIsStillAppliedBeforeTheSdkSeesTheReport {
  BugseeExtendedReport *report = [self newCreated];
  NSString *handle = [self createWith:[NSMutableArray array] report:report];
  [_flow createdAddFile:handle path:_file name:@"a" mimeType:nil reply:[self collector:[NSMutableArray array]]];
  [_flow uploadCreated:handle reply:[self collector:[NSMutableArray array]]];
  [self drainAll];
  XCTAssertEqual(report.attachments.count, 1u, @"applied");
  XCTAssertEqual(_sdk.uploaded.count, 1u, @"and only then handed to the SDK");
  XCTAssertEqualObjects(_sdk.countsAtUpload, @[ @1 ], @"with the attachment already in it WHEN the SDK was handed the report");
}

- (void)testACreatedWorkerThatIsFullAnswersBusyAndAnUploadStillReachesTheSdk {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  _createdWorker.accept = NO;
  NSMutableArray *got = [NSMutableArray array];
  [_flow createdAddFile:handle path:_file name:@"a" mimeType:nil reply:[self collector:got]];
  [self drainAll];
  XCTAssertEqualObjects(got, @[ BGSFlutterFileBusy ]);
  [_flow uploadCreated:handle reply:[self collector:[NSMutableArray array]]];
  [self drainAll];
  XCTAssertEqual(_sdk.uploaded.count, 1u);
}


- (void)testCreatedOperationsLeaveRoomForTheUploadBehindThem {
  BugseeExtendedReport *report = [self newCreated];
  NSString *handle = [self createWith:[NSMutableArray array] report:report];
  NSMutableArray *accepted = [NSMutableArray array];
  for (NSInteger i = 0; i < BGSFlutterCreatedOpsLimit; i++) {
    [_flow createdAddData:handle data:[NSData dataWithBytes:"x" length:1] name:@"b" mimeType:nil reply:[self collector:accepted]];
  }
  NSMutableArray *over = [NSMutableArray array];
  [_flow createdAddData:handle data:[NSData dataWithBytes:"x" length:1] name:@"too many" mimeType:nil reply:[self collector:over]];
  [_main drain];
  XCTAssertEqualObjects(over, @[ BGSFlutterFileBusy ]);
  XCTAssertEqual(_createdWorker.tasks.count, (NSUInteger)BGSFlutterCreatedOpsLimit);
  [_flow uploadCreated:handle reply:[self collector:[NSMutableArray array]]];
  XCTAssertEqual(_createdWorker.tasks.count, (NSUInteger)BGSFlutterCreatedOpsLimit + 1, @"queued behind them");
  [self drainAll];
  XCTAssertEqualObjects(_sdk.countsAtUpload, @[ @3 ], @"the SDK keeps 3 legacy attachments; all the adds ran first");
  XCTAssertEqual(accepted.count, (NSUInteger)BGSFlutterCreatedOpsLimit);
}

- (void)testTheBudgetIsGivenBackWhenOperationsFinish {
  NSString *handle = [self createWith:[NSMutableArray array] report:[self newCreated]];
  for (int round = 0; round < 3; round++) {
    for (NSInteger i = 0; i < BGSFlutterCreatedOpsLimit; i++) {
      [_flow createdClearAttachments:handle reply:[self collector:[NSMutableArray array]]];
    }
    [self drainAll];
  }
  NSMutableArray *again = [NSMutableArray array];
  [_flow createdClearAttachments:handle reply:[self collector:again]];
  [self drainAll];
  XCTAssertEqualObjects(again, @[ @"ok" ]);
}

@end
