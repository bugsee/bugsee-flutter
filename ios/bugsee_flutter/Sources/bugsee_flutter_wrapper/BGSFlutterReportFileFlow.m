#import "BGSFlutterReportFileFlow.h"

#import <os/lock.h>

@import Bugsee;

NSString *const BGSFlutterCreateBusy = @"create-busy";
NSString *const BGSFlutterCreateTimeout = @"create-timeout";
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
  BGSFlutterFlowMain _main;
  id<BGSFlutterCreatedReportSdk> _sdk;
  int64_t _createTimeoutMs;
}

+ (instancetype)shared {
  static BGSFlutterReportFileFlow *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_queue_t queue = dispatch_queue_create("com.bugsee.flutter.report-files", DISPATCH_QUEUE_SERIAL);
    // A bounded queue: a loop of adds must not grow without limit, and a full queue refuses the call.
    static const int kCapacity = 64;
    __block int waiting = 0;
    os_unfair_lock_t lock = malloc(sizeof(os_unfair_lock));
    *lock = OS_UNFAIR_LOCK_INIT;
    shared = [[BGSFlutterReportFileFlow alloc]
        initWithPipeline:[BGSFlutterReportHandlerPipeline shared]
                 created:[BGSFlutterCreatedReports shared]
                  worker:^BOOL(dispatch_block_t task) {
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
                  }
                    main:^(dispatch_block_t task) {
                      dispatch_async(dispatch_get_main_queue(), task);
                    }
                     sdk:[[BGSFlutterRealCreatedReportSdk alloc] init]
         createTimeoutMs:BGSFlutterCreateTimeoutMs];
  });
  return shared;
}

- (instancetype)initWithPipeline:(BGSFlutterReportHandlerPipeline *)pipeline
                         created:(BGSFlutterCreatedReports *)created
                          worker:(BGSFlutterFlowWorker)worker
                            main:(BGSFlutterFlowMain)main
                             sdk:(id<BGSFlutterCreatedReportSdk>)sdk
                 createTimeoutMs:(int64_t)createTimeoutMs {
  self = [super init];
  if (self) {
    _pipeline = pipeline;
    _created = created;
    _worker = [worker copy];
    _main = [main copy];
    _sdk = sdk;
    _createTimeoutMs = createTimeoutMs;
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
    [self run:op on:lease.report reply:reply];
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

- (void)createWithTtlMs:(int64_t)ttlMs reply:(BGSFlutterFlowReply)reply {
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
  const NSUInteger stamp = [_created reserveWithCreateTimeoutMs:_createTimeoutMs
                                                      onTimeout:^{
                                                        if (claim()) {
                                                          [self fail:reply
                                                                code:BGSFlutterCreateTimeout
                                                             message:@"the SDK did not answer createReport in time"];
                                                        }
                                                      }];
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

/// A created report's operations run where the SDK uses the object: on main, in call order. Looked
/// up NOW, so one called before an upload or a discard belongs to the report and one called after
/// finds nothing.
- (void)created:(NSString *)handle op:(BGSFlutterCreatedOp)op reply:(BGSFlutterFlowReply)reply {
  id report = [_created reportForHandle:handle];
  if (report == nil) {
    [self answer:reply value:BGSFlutterFileNotLive];
    return;
  }
  _main(^{
    [self run:op on:report reply:reply];
  });
}

- (void)createdAddFile:(NSString *)handle
                  path:(NSString *)path
                  name:(NSString *)name
              mimeType:(NSString *)mimeType
                 reply:(BGSFlutterFlowReply)reply {
  [self created:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterCreatedReportOps addFileAtPath:path name:name mimeType:mimeType onReport:report];
             }
          reply:reply];
}

- (void)createdAddData:(NSString *)handle
                  data:(NSData *)data
                  name:(NSString *)name
              mimeType:(NSString *)mimeType
                 reply:(BGSFlutterFlowReply)reply {
  [self created:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterCreatedReportOps addData:data name:name mimeType:mimeType onReport:report];
             }
          reply:reply];
}

- (void)createdClearAttachments:(NSString *)handle reply:(BGSFlutterFlowReply)reply {
  [self created:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterCreatedReportOps clearAttachmentsOnReport:report];
             }
          reply:reply];
}

- (void)createdSetScreenshot:(NSString *)handle path:(NSString *)path annotated:(BOOL)annotated reply:(BGSFlutterFlowReply)reply {
  [self created:handle
             op:^BGSFlutterFileOutcome *(id report) {
               return [BGSFlutterCreatedReportOps setScreenshotAtPath:path annotated:annotated onReport:report];
             }
          reply:reply];
}

- (void)uploadCreated:(NSString *)handle reply:(BGSFlutterFlowReply)reply {
  // Taken at once: the slot is free whatever the SDK answers, and a second upload (or any later
  // call) finds nothing. Operations called before this are queued on main ahead of it.
  id report = [_created takeHandle:handle];
  if (report == nil) {
    [self answer:reply value:@NO];
    return;
  }
  _main(^{
    @try {
      [self->_sdk uploadReport:report
                    completion:^{
                      // The SDK says it has been handed off for processing, not that it was sent.
                      [self answer:reply value:@YES];
                    }];
    } @catch (NSException *exception) {
      [self fail:reply
            code:BGSFlutterFlowSdkError
         message:[@"upload: " stringByAppendingString:NSStringFromClass(exception.class)]];
    }
  });
}

- (void)discardCreated:(NSString *)handle {
  // Dropping the reference is the release: the object holds its attachments in memory.
  (void)[_created takeHandle:handle];
}

- (void)reset {
  (void)[_created clear];
}

@end
