#import "BGSFlutterReportFileFlow.h"

#import <os/lock.h>

@import Bugsee;

NSString *const BGSFlutterCreateBusy = @"create-busy";
NSString *const BGSFlutterCreateTimeout = @"create-timeout";
NSString *const BGSFlutterCreateRateLimited = @"create-rate-limited";
NSString *const BGSFlutterUploadTimeout = @"upload-timeout";
NSString *const BGSFlutterFlowNotLive = @"not-live";
const int64_t BGSFlutterUploadTimeoutMs = 45000;
NSString *const BGSFlutterFlowInvalidArgument = @"invalid-argument";
NSString *const BGSFlutterFlowSdkError = @"sdk-error";
const int64_t BGSFlutterCreateTimeoutMs = 45000;

@implementation BGSFlutterRealCreatedReportSdk
- (void)createReportWithCompletion:(void (^)(id _Nullable))completion {
  [Bugsee createReportWithCompletion:^(BugseeExtendedReport *report) {
    completion(report);
  }];
}
- (void)uploadReport:(id)report completion:(void (^)(void))completion {
  [Bugsee uploadReport:(BugseeExtendedReport *)report completion:completion];
}
@end

typedef BGSFlutterFileOutcome * (^BGSFlutterHandlerOp)(id report);
typedef BGSFlutterFileOutcome * (^BGSFlutterCreatedOp)(id report);

@implementation BGSFlutterReportFileFlow {
  BGSFlutterReportHandlerPipeline *_pipeline;
  BGSFlutterCreatedReports *_created;
  BGSFlutterFlowWorker _worker;
  BGSFlutterFlowWorker _createdWorker;
  BGSFlutterFlowMain _main;
  id<BGSFlutterCreatedReportSdk> _sdk;
  BGSFlutterCreatedScheduler _scheduler;
  BGSFlutterCreatedCancel _cancel;
  int64_t _createTimeoutMs;
  int64_t _uploadTimeoutMs;
}

/// A bounded serial queue: a loop of adds must not grow without limit, and a full queue refuses the call.
static BGSFlutterFlowWorker BGSBoundedWorker(const char *label) {
  dispatch_queue_t queue = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
  static const int kCapacity = 64;
  __block int waiting = 0;
  os_unfair_lock_t lock = malloc(sizeof(os_unfair_lock));
  *lock = OS_UNFAIR_LOCK_INIT;
  return ^BOOL(dispatch_block_t task) {
    os_unfair_lock_lock(lock);
    if (waiting >= kCapacity) {
      os_unfair_lock_unlock(lock);
      return NO;
    }
    waiting++;
    os_unfair_lock_unlock(lock);
    dispatch_async(queue, ^{
      task();
      os_unfair_lock_lock(lock);
      waiting--;
      os_unfair_lock_unlock(lock);
    });
    return YES;
  };
}

+ (instancetype)shared {
  static BGSFlutterReportFileFlow *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_queue_t timers = dispatch_queue_create("com.bugsee.flutter.report-timers", DISPATCH_QUEUE_SERIAL);
    shared = [[BGSFlutterReportFileFlow alloc]
        initWithPipeline:[BGSFlutterReportHandlerPipeline shared]
                 created:[BGSFlutterCreatedReports shared]
                  worker:BGSBoundedWorker("com.bugsee.flutter.report-files")
           createdWorker:BGSBoundedWorker("com.bugsee.flutter.created-report")
                    main:^(dispatch_block_t task) {
                      dispatch_async(dispatch_get_main_queue(), task);
                    }
                     sdk:[[BGSFlutterRealCreatedReportSdk alloc] init]
               scheduler:^id(dispatch_block_t task, int64_t delayMs) {
                 dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, timers);
                 dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, delayMs * NSEC_PER_MSEC),
                                           DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
                 dispatch_source_set_event_handler(timer, ^{
                   dispatch_source_cancel(timer);
                   task();
                 });
                 dispatch_resume(timer);
                 return timer;
               }
                  cancel:^(id token) {
                    dispatch_source_cancel((dispatch_source_t)token);
                  }
         createTimeoutMs:BGSFlutterCreateTimeoutMs
         uploadTimeoutMs:BGSFlutterUploadTimeoutMs];
  });
  return shared;
}

- (instancetype)initWithPipeline:(BGSFlutterReportHandlerPipeline *)pipeline
                         created:(BGSFlutterCreatedReports *)created
                          worker:(BGSFlutterFlowWorker)worker
                   createdWorker:(BGSFlutterFlowWorker)createdWorker
                            main:(BGSFlutterFlowMain)main
                             sdk:(id<BGSFlutterCreatedReportSdk>)sdk
                       scheduler:(BGSFlutterCreatedScheduler)scheduler
                          cancel:(BGSFlutterCreatedCancel)cancel
                 createTimeoutMs:(int64_t)createTimeoutMs
                 uploadTimeoutMs:(int64_t)uploadTimeoutMs {
  self = [super init];
  if (self) {
    _pipeline = pipeline;
    _created = created;
    _worker = [worker copy];
    _createdWorker = [createdWorker copy];
    _main = [main copy];
    _sdk = sdk;
    _scheduler = [scheduler copy];
    _cancel = [cancel copy];
    _createTimeoutMs = createTimeoutMs;
    _uploadTimeoutMs = uploadTimeoutMs;
  }
  return self;
}

#pragma mark - Plumbing

- (void)answer:(BGSFlutterFlowReply)reply value:(id)value {
  _main(^{
    reply(value, nil, nil);
  });
}

- (void)fail:(BGSFlutterFlowReply)reply code:(NSString *)code message:(NSString *)message {
  _main(^{
    reply(nil, code, message);
  });
}

/// A refusal is a code (the value); an argument error is an error reply; nothing else is possible.
- (void)settle:(BGSFlutterFileOutcome *)outcome reply:(BGSFlutterFlowReply)reply {
  if (outcome.argumentError != nil) {
    [self fail:reply code:BGSFlutterFlowInvalidArgument message:outcome.argumentError];
  } else {
    [self answer:reply value:outcome.code];
  }
}

/// Runs `op` and settles, turning an exception into an `sdk-error` (an NSException escaping into Swift
/// crashes the app); the message is the exception's class only, never a path.
- (void)run:(BGSFlutterHandlerOp)op on:(id)report reply:(BGSFlutterFlowReply)reply {
  BGSFlutterFileOutcome *outcome = nil;
  @try {
    outcome = op(report);
  } @catch (NSException *exception) {
    [self fail:reply
          code:BGSFlutterFlowSdkError
       message:[@"report file operation: " stringByAppendingString:NSStringFromClass(exception.class)]];
    return;
  }
  [self settle:outcome reply:reply];
}

#pragma mark - A handler's report

- (void)handler:(NSString *)handle op:(BGSFlutterHandlerOp)op reply:(BGSFlutterFlowReply)reply {
  BGSFlutterReportLease *lease = [_pipeline acquireHandle:handle];
  if (lease == nil) {
    [self answer:reply value:BGSFlutterFileNotLive];
    return;
  }
  const BOOL queued = _worker(^{
    if ([lease windowClosed]) {
      // Queued behind a slow copy and the handler's window ran out meanwhile: the SDK has moved on (or is
      // about to), so nothing is started and nothing was touched.
      [self answer:reply value:BGSFlutterFileNotLive];
    } else {
      [self run:op on:lease.report reply:reply];
    }
    [lease end];
  });
  if (!queued) {
    [lease end];
    [self answer:reply value:BGSFlutterFileBusy];
  }
}

- (void)handlerAddFile:(NSString *)handle
                  path:(NSString *)path
                  name:(NSString *)name
              mimeType:(NSString *)mimeType
                  move:(BOOL)move
                 reply:(BGSFlutterFlowReply)reply {
  [self handler:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterReportFiles addFileAtPath:path name:name mimeType:mimeType move:move onReport:report];
             }
          reply:reply];
}

- (void)handlerAddData:(NSString *)handle
                  data:(NSData *)data
                  name:(NSString *)name
              mimeType:(NSString *)mimeType
                 reply:(BGSFlutterFlowReply)reply {
  [self handler:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterReportFiles addData:data name:name mimeType:mimeType onReport:report];
             }
          reply:reply];
}

- (void)handlerClearAttachments:(NSString *)handle reply:(BGSFlutterFlowReply)reply {
  [self handler:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterReportFiles clearAttachmentsOnReport:report];
             }
          reply:reply];
}

- (void)handlerSetScreenshot:(NSString *)handle
                        path:(NSString *)path
                   displayId:(int64_t)displayId
                   annotated:(BOOL)annotated
                       reply:(BGSFlutterFlowReply)reply {
  [self handler:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterReportFiles setScreenshotAtPath:path displayId:displayId annotated:annotated onReport:report];
             }
          reply:reply];
}

- (void)handlerRemoveScreenshot:(NSString *)handle displayId:(int64_t)displayId reply:(BGSFlutterFlowReply)reply {
  [self handler:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterReportFiles removeScreenshotWithDisplayId:displayId onReport:report];
             }
          reply:reply];
}

#pragma mark - createReport

- (void)createForOwner:(id)owner ttlMs:(int64_t)ttlMs reply:(BGSFlutterFlowReply)reply {
  __block os_unfair_lock answeredLock = OS_UNFAIR_LOCK_INIT;
  __block BOOL answered = NO;
  BOOL (^claim)(void) = ^BOOL {
    os_unfair_lock_lock(&answeredLock);
    const BOOL first = !answered;
    answered = YES;
    os_unfair_lock_unlock(&answeredLock);
    return first;
  };
  // The slot is taken before the SDK is asked: its completion answers later, on its own thread.
  const NSUInteger stamp = [_created reserveForOwner:owner
                                     createTimeoutMs:_createTimeoutMs
                                           onTimeout:^{
                                                        if (claim()) {
                                                          [self fail:reply
                                                                code:BGSFlutterCreateTimeout
                                                             message:@"the SDK did not answer createReport in time"];
                                                        }
                                                      }];
  if (stamp == BGSFlutterCreatedRateLimited) {
    reply(nil, BGSFlutterCreateRateLimited, @"too many created reports were started; the SDK cannot cancel one");
    return;
  }
  if (stamp == 0) {
    // On the caller's thread, already the platform thread.
    reply(nil, BGSFlutterCreateBusy, @"a created report is already outstanding");
    return;
  }
  @try {
    [_sdk createReportWithCompletion:^(id report) {
      NSString *handle = [self->_created fulfil:stamp
                                         report:report
                                          ttlMs:ttlMs
                                      onExpired:^(id expired) {
                                        // A BugseeExtendedReport holds its attachments in memory and
                                        // nothing on disk: dropping the last reference releases it.
                                      }];
      // A report the registry refused (timed out, or cleared by a reset) is dropped as it goes out
      // of scope: nobody will use it.
      if (claim()) {
        [self answer:reply value:handle];
      } else if (handle != nil) {
        // The caller was already told it timed out: release what was just registered.
        (void)[self->_created takeHandle:handle];
      }
    }];
  } @catch (NSException *exception) {
    [_created fulfil:stamp report:nil ttlMs:0 onExpired:^(id r) {}];
    if (claim()) {
      [self fail:reply
            code:BGSFlutterFlowSdkError
         message:[@"createReport: " stringByAppendingString:NSStringFromClass(exception.class)]];
    }
  }
}

- (BGSFlutterCreatedReportSnapshot *)readCreated:(NSString *)handle {
  id report = [_created reportForHandle:handle];
  return report == nil ? nil : [BGSFlutterCreatedReportOps readReport:report];
}

- (BOOL)applyToCreated:(NSString *)handle patch:(BGSFlutterCreatedReportPatch *)patch message:(NSString **)message {
  id report = [_created reportForHandle:handle];
  if (report == nil) {
    return NO;
  }
  NSString *problem = [BGSFlutterCreatedReportOps applyPatch:patch toReport:report];
  if (message != NULL) {
    *message = problem;
  }
  return YES;
}

/// A created report's operations: the part that touches the file system or decodes an image (`prepare`)
/// runs on the created-report worker, OFF main; the part that touches the object (`apply`) runs on main,
/// where the SDK uses it, and replies. Every operation, the upload and nothing else goes through the same
/// serial worker, so main sees them in the order Dart called them. Looked up NOW: an operation called
/// before an upload or a discard belongs to the report and one called after finds nothing.
- (void)created:(NSString *)handle
        prepare:(id (^)(void))prepare
          apply:(BGSFlutterFileOutcome * (^)(id prepared, id report))apply
          reply:(BGSFlutterFlowReply)reply {
  id report = [_created reportForHandle:handle];
  if (report == nil) {
    [self answer:reply value:BGSFlutterFileNotLive];
    return;
  }
  const BOOL queued = _createdWorker(^{
    id prepared = prepare != nil ? prepare() : nil;
    self->_main(^{
      [self run:^BGSFlutterFileOutcome *(id r) {
        return apply(prepared, r);
      }
             on:report
          reply:reply];
    });
  });
  if (!queued) {
    [self answer:reply value:BGSFlutterFileBusy];
  }
}

- (void)createdAddFile:(NSString *)handle
                  path:(NSString *)path
                  name:(NSString *)name
              mimeType:(NSString *)mimeType
                 reply:(BGSFlutterFlowReply)reply {
  [self created:handle
        prepare:^id {
          return [BGSFlutterCreatedReportOps prepareFileAtPath:path name:name mimeType:mimeType];
        }
          apply:^BGSFlutterFileOutcome *(id prepared, id report) {
            return [BGSFlutterCreatedReportOps applyPreparedFile:prepared name:name onReport:report];
          }
          reply:reply];
}

- (void)createdAddData:(NSString *)handle
                  data:(NSData *)data
                  name:(NSString *)name
              mimeType:(NSString *)mimeType
                 reply:(BGSFlutterFlowReply)reply {
  [self created:handle
        prepare:nil
          apply:^BGSFlutterFileOutcome *(id prepared, id report) {
            return [BGSFlutterCreatedReportOps addData:data name:name mimeType:mimeType onReport:report];
          }
          reply:reply];
}

- (void)createdClearAttachments:(NSString *)handle reply:(BGSFlutterFlowReply)reply {
  [self created:handle
        prepare:nil
          apply:^BGSFlutterFileOutcome *(id prepared, id report) {
            return [BGSFlutterCreatedReportOps clearAttachmentsOnReport:report];
          }
          reply:reply];
}

- (void)createdSetScreenshot:(NSString *)handle path:(NSString *)path annotated:(BOOL)annotated reply:(BGSFlutterFlowReply)reply {
  [self created:handle
        prepare:^id {
          return [BGSFlutterCreatedReportOps prepareScreenshotAtPath:path annotated:annotated];
        }
          apply:^BGSFlutterFileOutcome *(id prepared, id report) {
            return [BGSFlutterCreatedReportOps applyPreparedScreenshot:prepared onReport:report];
          }
          reply:reply];
}

- (void)uploadCreated:(NSString *)handle reply:(BGSFlutterFlowReply)reply {
  // Taken at once: the slot is free whatever the SDK answers, and a second upload (or any later
  // call) finds nothing. Operations called before this are queued on main ahead of it.
  id report = [_created takeHandle:handle];
  if (report == nil) {
    // Not "the SDK declined" (NO): the report is gone (uploaded, discarded, expired).
    [self fail:reply code:BGSFlutterFlowNotLive message:@"the created report is not live"];
    return;
  }
  __block os_unfair_lock answeredLock = OS_UNFAIR_LOCK_INIT;
  __block BOOL answered = NO;
  __block id timer = nil;
  BOOL (^claim)(void) = ^BOOL {
    os_unfair_lock_lock(&answeredLock);
    const BOOL first = !answered;
    answered = YES;
    id t = timer;
    timer = nil;
    os_unfair_lock_unlock(&answeredLock);
    if (first && t != nil) {
      @try {
        self->_cancel(t);
      } @catch (NSException *exception) {
        // A timer that cannot be cancelled fires into a decided answer and does nothing.
      }
    }
    return first;
  };
  // A deadline on the SDK's answer: its completion runs after the handlers and the scheduling, and nothing
  // says it must come. Exactly one answer wins; a completion that arrives after the timeout is ignored.
  // The report may still be sent: the error says so.
  id armed = _scheduler(^{
    os_unfair_lock_lock(&answeredLock);
    const BOOL first = !answered;
    answered = YES;
    timer = nil;
    os_unfair_lock_unlock(&answeredLock);
    if (first) {
      [self fail:reply code:BGSFlutterUploadTimeout message:@"the SDK did not say in time whether it took the report"];
    }
  }, _uploadTimeoutMs);
  os_unfair_lock_lock(&answeredLock);
  if (!answered) {
    timer = armed;
  }
  os_unfair_lock_unlock(&answeredLock);
  // Behind the operations already queued for this report (they prepare off main and apply on main; this
  // hops to main after them), so an attachment the app did or did not await is in the report when the
  // SDK processes it.
  dispatch_block_t send = ^{
    @try {
      [self->_sdk uploadReport:report
                    completion:^{
                      // The SDK says it has been handed off for processing, not that it was sent.
                      if (claim()) {
                        [self answer:reply value:@YES];
                      }
                    }];
    } @catch (NSException *exception) {
      if (claim()) {
        [self fail:reply
              code:BGSFlutterFlowSdkError
           message:[@"upload: " stringByAppendingString:NSStringFromClass(exception.class)]];
      }
    }
  };
  // The hop to main is queued by the worker AFTER the earlier operations queued theirs; a full queue sends
  // it directly rather than not at all.
  if (!_createdWorker(^{
        self->_main(send);
      })) {
    _main(send);
  }
}

- (void)discardCreated:(NSString *)handle {
  // Dropping the reference is the release: the object holds its attachments in memory.
  (void)[_created takeHandle:handle];
}

- (void)resetOwner:(id)owner {
  (void)[_created clearOwner:owner];
}

@end
