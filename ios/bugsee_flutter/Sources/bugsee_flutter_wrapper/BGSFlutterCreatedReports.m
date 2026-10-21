#import "BGSFlutterCreatedReports.h"

#import <os/lock.h>

@implementation BGSFlutterCreatedReports {
  BGSFlutterCreatedScheduler _schedule;
  BGSFlutterCreatedCancel _cancel;
  os_unfair_lock _lock;
  BOOL _creating;
  NSUInteger _currentStamp;
  NSUInteger _nextStamp;
  id _report;
  NSString *_handle;
  NSUInteger _next;
  id _timer;
}

+ (instancetype)shared {
  static BGSFlutterCreatedReports *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dispatch_queue_t queue = dispatch_queue_create("com.bugsee.flutter.created-reports", DISPATCH_QUEUE_SERIAL);
    shared = [[BGSFlutterCreatedReports alloc]
        initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
          dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
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
        }];
  });
  return shared;
}

- (instancetype)initWithScheduler:(BGSFlutterCreatedScheduler)scheduler
                           cancel:(BGSFlutterCreatedCancel)cancel {
  self = [super init];
  if (self) {
    _schedule = [scheduler copy];
    _cancel = [cancel copy];
    _lock = OS_UNFAIR_LOCK_INIT;
    _nextStamp = 1;
    _next = 1;
  }
  return self;
}

/// With `_lock` held.
- (void)cancelTimerLocked {
  id timer = _timer;
  _timer = nil;
  if (timer != nil) {
    @try {
      _cancel(timer);
    } @catch (NSException *exception) {
      // A timer that cannot be cancelled fires into a stale stamp or handle and does nothing.
    }
  }
}

- (NSUInteger)reserveWithCreateTimeoutMs:(int64_t)createTimeoutMs onTimeout:(dispatch_block_t)onTimeout {
  os_unfair_lock_lock(&_lock);
  if (_creating || _report != nil) {
    os_unfair_lock_unlock(&_lock);
    return 0;
  }
  _creating = YES;
  const NSUInteger stamp = _nextStamp;
  _nextStamp = _nextStamp == NSUIntegerMax ? 1 : _nextStamp + 1;
  _currentStamp = stamp;
  _timer = _schedule(^{
    os_unfair_lock_lock(&self->_lock);
    const BOOL timedOut = self->_creating && self->_currentStamp == stamp;
    if (timedOut) {
      self->_creating = NO;
      self->_currentStamp = 0;
      self->_timer = nil;
    }
    os_unfair_lock_unlock(&self->_lock);
    if (timedOut && onTimeout != nil) {
      onTimeout();
    }
  }, createTimeoutMs);
  os_unfair_lock_unlock(&_lock);
  return stamp;
}

- (NSString *)fulfil:(NSUInteger)stamp
              report:(id)report
               ttlMs:(int64_t)ttlMs
           onExpired:(void (^)(id))onExpired {
  os_unfair_lock_lock(&_lock);
  if (!_creating || stamp == 0 || stamp != _currentStamp) {
    os_unfair_lock_unlock(&_lock);
    return nil;
  }
  [self cancelTimerLocked];
  _creating = NO;
  _currentStamp = 0;
  if (report == nil) {
    os_unfair_lock_unlock(&_lock);
    return nil;
  }
  NSString *minted = [NSString stringWithFormat:@"cr-%lu", (unsigned long)_next++];
  _handle = minted;
  _report = report;
  _timer = _schedule(^{
    id gone = [self takeHandle:minted];
    if (gone != nil && onExpired != nil) {
      onExpired(gone);
    }
  }, ttlMs);
  os_unfair_lock_unlock(&_lock);
  return minted;
}

- (BOOL)isReserved:(NSUInteger)stamp {
  os_unfair_lock_lock(&_lock);
  const BOOL reserved = _creating && stamp != 0 && stamp == _currentStamp;
  os_unfair_lock_unlock(&_lock);
  return reserved;
}

- (id)reportForHandle:(NSString *)handle {
  os_unfair_lock_lock(&_lock);
  id report = (_report != nil && handle != nil && [handle isEqualToString:_handle]) ? _report : nil;
  os_unfair_lock_unlock(&_lock);
  return report;
}

- (id)takeHandle:(NSString *)handle {
  os_unfair_lock_lock(&_lock);
  id report = (_report != nil && handle != nil && [handle isEqualToString:_handle]) ? _report : nil;
  if (report != nil) {
    [self cancelTimerLocked];
    _report = nil;
    _handle = nil;
  }
  os_unfair_lock_unlock(&_lock);
  return report;
}

- (id)clear {
  os_unfair_lock_lock(&_lock);
  [self cancelTimerLocked];
  id report = _report;
  _creating = NO;
  _currentStamp = 0;
  _report = nil;
  _handle = nil;
  os_unfair_lock_unlock(&_lock);
  return report;
}

@end
