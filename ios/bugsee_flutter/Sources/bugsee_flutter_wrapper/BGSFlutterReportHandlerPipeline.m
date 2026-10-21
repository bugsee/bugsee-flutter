#import "BGSFlutterReportHandlerPipeline.h"

#import <os/lock.h>

#import "BGSFlutterReportOps.h"

@import Bugsee;

const int64_t BGSFlutterReportLiveDeadlineMs = 25000;
const int64_t BGSFlutterReportRecoveryDeadlineMs = 2000;
const int64_t BGSFlutterReportSdkLiveHandlerTimeoutMs = 30000;
const int64_t BGSFlutterReportSdkBoundedCapMs = 3000;

int64_t BGSFlutterReportDeadlineMs(BOOL onMainThread) {
  return onMainThread ? BGSFlutterReportLiveDeadlineMs : BGSFlutterReportRecoveryDeadlineMs;
}

@interface BGSFlutterReportRequest ()
- (instancetype)initWithHandle:(NSString *)handle
                    deliveryId:(NSString *)deliveryId
                         after:(BOOL)after
                      reportId:(NSString *)reportId
                          type:(NSString *)type
                    deadlineMs:(int64_t)deadlineMs;
@end

@implementation BGSFlutterReportRequest
- (instancetype)initWithHandle:(NSString *)handle
                    deliveryId:(NSString *)deliveryId
                         after:(BOOL)after
                      reportId:(NSString *)reportId
                          type:(NSString *)type
                    deadlineMs:(int64_t)deadlineMs {
  self = [super init];
  if (self) {
    _handle = [handle copy];
    _deliveryId = [deliveryId copy];
    _after = after;
    _reportId = [reportId copy];
    _type = [type copy];
    _deadlineMs = deadlineMs;
  }
  return self;
}
@end

/// One engine's Dart end. `before`/`after` are guarded by the pipeline's lock.
@interface BGSFlutterReportRegistration : NSObject
@property(nonatomic, copy) BGSFlutterReportSink sink;
@property(nonatomic) BOOL before;
@property(nonatomic) BOOL after;
@end
@implementation BGSFlutterReportRegistration
@end

/// One dispatch that reached Dart. `done`, `timer`, `report` and `completion` are guarded by
/// the pipeline's lock; everything else is immutable.
@interface BGSFlutterReportHandle : NSObject
@property(nonatomic, copy, readonly) NSString *handleId;
/// Nilled by finish, with `completion`: the deadline task captures the handle, and a cancelled
/// dispatch block keeps its captures until its fire time.
@property(nonatomic, strong, nullable) id report;
@property(nonatomic, copy, nullable) dispatch_block_t completion;
@property(nonatomic, strong, readonly) id owner;
/// The exactly-once guard. Whoever flips it runs the completion.
@property(nonatomic) BOOL done;
@property(nonatomic, strong, nullable) id timer;
@end
@implementation BGSFlutterReportHandle
- (instancetype)initWithId:(NSString *)handleId
                    report:(id)report
                completion:(dispatch_block_t)completion
                     owner:(id)owner {
  self = [super init];
  if (self) {
    _handleId = [handleId copy];
    _report = report;
    _completion = [completion copy];
    _owner = owner;
  }
  return self;
}
@end

static NSString *PhaseWire(BGSFlutterReportPhase phase) {
  return phase == BGSFlutterReportPhaseBefore ? @"before" : @"after";
}

/// The SDK's own fault must not escape into Dart's queue or the timer's.
static void RunQuietly(dispatch_block_t completion) {
  if (completion == nil) {
    return;
  }
  @try {
    completion();
  } @catch (NSException *exception) {
    NSLog(@"[BugseeFlutter] report handler completion threw: %@", NSStringFromClass(exception.class));
  }
}

static NSString *SafeReportId(id report) {
  @try {
    NSString *reportId = ((id<BGSReportContract>)report).reportId;
    return [reportId isKindOfClass:[NSString class]] ? reportId : @"";
  } @catch (NSException *exception) {
    return @"";
  }
}

@implementation BGSFlutterReportHandlerPipeline {
  BGSFlutterReportScheduler _schedule;
  BGSFlutterReportCancel _cancel;
  BGSFlutterReportPlatformPost _platformPost;
  BGSFlutterReportLog _log;

  /// Guards everything below. The SDK dispatches on main (live) or its own threads (recovery),
  /// Dart completes on main, deadlines fire on the scheduler's queue: all of them meet here.
  /// Never held while calling out: not the SDK's completion, not a sink, not the scheduler.
  os_unfair_lock _lock;
  NSMutableArray<BGSFlutterReportRegistration *> *_registrations;  // most recent first
  NSMutableDictionary<NSString *, BGSFlutterReportHandle *> *_handles;
  uint64_t _counter;
}

+ (instancetype)shared {
  static BGSFlutterReportHandlerPipeline *shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // One serial queue for every handle's deadline. A cancelled block that has not started
    // never runs; one that has already started still reaches the handle's guard, which is
    // what makes cancelling safe to race.
    dispatch_queue_t queue =
        dispatch_queue_create("com.bugsee.flutter.report-deadline", DISPATCH_QUEUE_SERIAL);
    shared = [[BGSFlutterReportHandlerPipeline alloc]
        initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
          dispatch_block_t block = dispatch_block_create(0, task);
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayMs * (int64_t)NSEC_PER_MSEC), queue,
                         block);
          return block;
        }
        cancel:^(id token) {
          dispatch_block_cancel((dispatch_block_t)token);
        }
        platformPost:^(dispatch_block_t task) {
          // Never inline, even when the caller IS the main thread (the live path): the request
          // is sent after the SDK's call has returned.
          dispatch_async(dispatch_get_main_queue(), task);
        }
        log:^(NSString *line) {
          // NSLog, not os_log: it reaches the `devicectl --console` stream device tests match.
          NSLog(@"%@", line);
        }];
  });
  return shared;
}

- (instancetype)initWithScheduler:(BGSFlutterReportScheduler)scheduler
                           cancel:(BGSFlutterReportCancel)cancel
                     platformPost:(BGSFlutterReportPlatformPost)platformPost
                              log:(BGSFlutterReportLog)log {
  self = [super init];
  if (self) {
    _schedule = [scheduler copy];
    _cancel = [cancel copy];
    _platformPost = [platformPost copy];
    _log = [log copy];
    _lock = OS_UNFAIR_LOCK_INIT;
    _registrations = [NSMutableArray array];
    _handles = [NSMutableDictionary dictionary];
  }
  return self;
}

#pragma mark - Engines

- (id)attachSink:(BGSFlutterReportSink)sink {
  BGSFlutterReportRegistration *registration = [[BGSFlutterReportRegistration alloc] init];
  registration.sink = sink;
  os_unfair_lock_lock(&_lock);
  [_registrations insertObject:registration atIndex:0];
  os_unfair_lock_unlock(&_lock);
  return registration;
}

- (void)setPhasesForOwner:(id)owner before:(BOOL)before after:(BOOL)after {
  os_unfair_lock_lock(&_lock);
  if ([_registrations containsObject:owner]) {
    ((BGSFlutterReportRegistration *)owner).before = before;
    ((BGSFlutterReportRegistration *)owner).after = after;
  }
  os_unfair_lock_unlock(&_lock);
}

- (void)detachOwner:(id)owner {
  NSMutableArray<BGSFlutterReportHandle *> *stale = [NSMutableArray array];
  os_unfair_lock_lock(&_lock);
  [_registrations removeObject:owner];
  for (BGSFlutterReportHandle *handle in _handles.allValues) {
    if (handle.owner == owner) {
      [stale addObject:handle];
    }
  }
  os_unfair_lock_unlock(&_lock);
  for (BGSFlutterReportHandle *handle in stale) {
    [self finish:handle by:@"detach"];
  }
}

#pragma mark - Dispatch

- (void)dispatchPhase:(BGSFlutterReportPhase)phase
               report:(id)report
        isTerminating:(BOOL)isTerminating
         onMainThread:(BOOL)onMainThread
           completion:(dispatch_block_t)completion {
  // At most once, whatever happens below.
  NSObject *onceGuard = [[NSObject alloc] init];
  __block BOOL ran = NO;
  dispatch_block_t once = ^{
    @synchronized(onceGuard) {
      if (ran || completion == nil) {
        return;
      }
      ran = YES;
    }
    completion();
  };
  @try {
    [self dispatchOnce:phase
                report:report
         isTerminating:isTerminating
          onMainThread:onMainThread
            completion:once];
  } @catch (NSException *exception) {
    // Whatever went wrong, the SDK must not wait for us.
    NSLog(@"[BugseeFlutter] report handler dispatch failed: %@", NSStringFromClass(exception.class));
    RunQuietly(once);
  }
}

- (void)dispatchOnce:(BGSFlutterReportPhase)phase
              report:(id)report
       isTerminating:(BOOL)isTerminating
        onMainThread:(BOOL)onMainThread
          completion:(dispatch_block_t)completion {
  if (report == nil) {
    [self completeUnminted:phase reportId:nil completion:completion by:@"no-report"];
    return;
  }
  // The process dies when this returns; nothing asynchronous survives it and the Dart runtime
  // may already be gone. Not even read from the report: touch nothing on a dying process.
  if (isTerminating) {
    [self completeUnminted:phase reportId:nil completion:completion by:@"terminating"];
    return;
  }

  os_unfair_lock_lock(&_lock);
  BGSFlutterReportRegistration *target = nil;
  for (BGSFlutterReportRegistration *candidate in _registrations) {
    if (phase == BGSFlutterReportPhaseBefore ? candidate.before : candidate.after) {
      target = candidate;
      break;
    }
  }
  os_unfair_lock_unlock(&_lock);
  if (target == nil) {
    [self completeUnminted:phase reportId:SafeReportId(report) completion:completion by:@"no-handler"];
    return;
  }

  const int64_t deadlineMs = BGSFlutterReportDeadlineMs(onMainThread);
  NSString *reportId = SafeReportId(report);
  NSString *type = [BGSFlutterReportOps typeOfReport:report];
  os_unfair_lock_lock(&_lock);
  NSString *handleId = [NSString stringWithFormat:@"rh-%llu", ++_counter];
  BGSFlutterReportHandle *handle = [[BGSFlutterReportHandle alloc] initWithId:handleId
                                                                       report:report
                                                                   completion:completion
                                                                        owner:target];
  _handles[handleId] = handle;
  // A detach that ran after the lookup above removed the registration, and swept the table
  // before this handle was in it; whichever side comes second catches the handle.
  const BOOL detached = ![_registrations containsObject:target];
  os_unfair_lock_unlock(&_lock);
  if (detached) {
    [self finish:handle by:@"detach"];
    return;
  }

  // Stable for one report and phase, so Dart recognises a re-delivery; unique (never shared)
  // when the id is unreadable, so distinct reports never collide.
  NSString *deliveryId = reportId.length > 0
                             ? [NSString stringWithFormat:@"%@:%@", PhaseWire(phase), reportId]
                             : [NSString stringWithFormat:@"%@:?%@", PhaseWire(phase), handleId];
  BGSFlutterReportRequest *request =
      [[BGSFlutterReportRequest alloc] initWithHandle:handleId
                                           deliveryId:deliveryId
                                                after:phase == BGSFlutterReportPhaseAfter
                                             reportId:reportId
                                                 type:type
                                           deadlineMs:deadlineMs];
  @try {
    // The task holds the handle itself, not its id: a deadline that was already running when
    // Dart completed must still hit the guard.
    id timer = _schedule(^{
      [self finish:handle by:@"deadline"];
    }, deadlineMs);
    os_unfair_lock_lock(&_lock);
    const BOOL alreadyDone = handle.done;
    if (!alreadyDone) {
      handle.timer = timer;
    }
    os_unfair_lock_unlock(&_lock);
    if (alreadyDone) {
      [self cancelQuietly:timer];
      return;
    }
    _log([NSString stringWithFormat:@"[BugseeFlutter] report handler %@ phase=%@ deadline=%lld",
                                    handleId, PhaseWire(phase), deadlineMs]);
    // To the main queue, never inline and never waited for. Dart's reply is delivered there, and
    // on the live path this very call IS the main thread: see the class comment.
    _platformPost(^{
      [self deliver:handle target:target request:request];
    });
  } @catch (NSException *exception) {
    // The handle is in the table: finishing it runs the completion and makes the report refuse
    // edits, instead of leaving a live proxy nobody will complete.
    NSLog(@"[BugseeFlutter] report handler %@ could not be set up: %@", handleId,
          NSStringFromClass(exception.class));
    [self finish:handle by:@"error"];
  }
}

- (void)deliver:(BGSFlutterReportHandle *)handle
         target:(BGSFlutterReportRegistration *)target
        request:(BGSFlutterReportRequest *)request {
  os_unfair_lock_lock(&_lock);
  const BOOL over = handle.done;
  os_unfair_lock_unlock(&_lock);
  if (over) {
    return;
  }
  @try {
    target.sink(request, ^{
      [self finish:handle by:@"unreachable"];
    });
  } @catch (NSException *exception) {
    // A dead bridge throws from the send. Dart will never answer, so answer for it.
    NSLog(@"[BugseeFlutter] report handler %@ could not reach Dart: %@", handle.handleId,
          NSStringFromClass(exception.class));
    [self finish:handle by:@"unreachable"];
  }
}

#pragma mark - Dart's side

- (BOOL)completeHandle:(NSString *)handleId {
  os_unfair_lock_lock(&_lock);
  BGSFlutterReportHandle *handle = _handles[handleId];
  os_unfair_lock_unlock(&_lock);
  return handle != nil && [self finish:handle by:@"dart"];
}

- (id)reportForHandle:(NSString *)handleId {
  if (handleId == nil) {
    return nil;
  }
  os_unfair_lock_lock(&_lock);
  BGSFlutterReportHandle *handle = _handles[handleId];
  id report = (handle == nil || handle.done) ? nil : handle.report;
  os_unfair_lock_unlock(&_lock);
  return report;
}

- (BGSFlutterReportEditResult)editHandle:(NSString *)handleId
                                    edit:(BGSFlutterReportEdit)edit
                                   error:(NSError **)error {
  id report = [self reportForHandle:handleId];
  if (report == nil) {
    return BGSFlutterReportEditNotLive;
  }
  return edit(report, error) ? BGSFlutterReportEditApplied : BGSFlutterReportEditRefused;
}

#pragma mark - Private

/// @return YES only for the call that ran the SDK completion.
- (BOOL)finish:(BGSFlutterReportHandle *)handle by:(NSString *)by {
  os_unfair_lock_lock(&_lock);
  if (handle.done) {
    os_unfair_lock_unlock(&_lock);
    return NO;
  }
  handle.done = YES;
  if (_handles[handle.handleId] == handle) {
    [_handles removeObjectForKey:handle.handleId];
  }
  id timer = handle.timer;
  handle.timer = nil;
  dispatch_block_t completion = handle.completion;
  handle.completion = nil;
  handle.report = nil;
  os_unfair_lock_unlock(&_lock);

  // Outside the lock from here: the completion re-enters the SDK, and a cancel or a log line
  // has no business holding up every other handle.
  if (timer != nil) {
    [self cancelQuietly:timer];
  }
  _log([NSString stringWithFormat:@"[BugseeFlutter] report handler %@ completed by=%@",
                                  handle.handleId, by]);
  RunQuietly(completion);
  return YES;
}

/// No handle was minted; the line still carries the report for correlation.
- (void)completeUnminted:(BGSFlutterReportPhase)phase
                reportId:(nullable NSString *)reportId
              completion:(dispatch_block_t)completion
                      by:(NSString *)by {
  _log([NSString stringWithFormat:@"[BugseeFlutter] report handler - completed by=%@ phase=%@ report=%@",
                                  by, PhaseWire(phase), reportId]);
  RunQuietly(completion);
}

- (void)cancelQuietly:(id)timer {
  if (timer == nil) {
    return;
  }
  @try {
    _cancel(timer);
  } @catch (NSException *exception) {
    NSLog(@"[BugseeFlutter] report handler timer cancel threw: %@",
          NSStringFromClass(exception.class));
  }
}

@end
