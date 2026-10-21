#import "BGSFlutterLifecycleHub.h"

static NSString *const BGSFlutterLifecyclePrefix = @"com.bugsee.lifecycle.";
static const NSUInteger BGSFlutterLifecycleBufferCapacity = 64;
/// Drops are always counted; a warning is logged for the first and then every Nth.
static const NSUInteger BGSFlutterLifecycleDropLogEvery = 100;

/// The only events that are status transitions (workbook 4.6). Repeated in Dart
/// (`statusTransitionEvents`) and Java; test/lifecycle_drift_test.dart compares them.
static NSSet<NSString *> *BGSFlutterStatusEvents(void) {
  static NSSet<NSString *> *events;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    events = [NSSet setWithObjects:@"Launching", @"Launched", @"Stopping", @"Stopped", nil];
  });
  return events;
}

/// The events whose payload is the report's id (workbook 4.5). Repeated in Dart
/// (`reportIdEvents`) and Java; test/lifecycle_drift_test.dart compares them.
static NSSet<NSString *> *BGSFlutterReportIdEvents(void) {
  static NSSet<NSString *> *events;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    events = [NSSet setWithObjects:@"BeforeReportAssembled", @"AfterReportAssembled",
                                   @"ReportAssemblyFailed", @"BeforeReportUploaded",
                                   @"AfterReportUploaded", @"ReportUploadFailed",
                                   @"ReportUploadFailedWithFutureRetry", nil];
  });
  return events;
}

@interface BGSFlutterLifecycleEvent ()
- (instancetype)initWithName:(NSString *)name
                    reportId:(nullable NSString *)reportId
                        data:(nullable NSDictionary<NSString *, NSString *> *)data;
@end

@implementation BGSFlutterLifecycleEvent
- (instancetype)initWithName:(NSString *)name
                    reportId:(NSString *)reportId
                        data:(NSDictionary<NSString *, NSString *> *)data {
  if ((self = [super init])) {
    _name = [name copy];
    _reportId = [reportId copy];
    _data = [data copy];
  }
  return self;
}
@end

/// One attached receiver, and the events posted to it that have not run yet. It is
/// also the token returned by -attachSink:.
@interface BGSFlutterLifecycleSinkToken : NSObject
@property(nonatomic, copy, readonly) BGSFlutterLifecycleSink sink;
@property(nonatomic, strong, readonly) NSMutableArray<BGSFlutterLifecycleEvent *> *inFlight;
@end
@implementation BGSFlutterLifecycleSinkToken
- (instancetype)initWithSink:(BGSFlutterLifecycleSink)sink {
  if ((self = [super init])) {
    _sink = [sink copy];
    _inFlight = [NSMutableArray array];
  }
  return self;
}
@end

@implementation BGSFlutterLifecycleHub {
  dispatch_queue_t _queue;
  NSMutableArray<BGSFlutterLifecycleEvent *> *_buffer;
  NSMutableArray<BGSFlutterLifecycleSinkToken *> *_tokens;
  // The latest Launching/Launched/Stopping/Stopped event, replayed to every new receiver.
  BGSFlutterLifecycleEvent *_lastStatus;
  NSUInteger _dropped;
}

+ (NSString *)prefix {
  return BGSFlutterLifecyclePrefix;
}

+ (NSUInteger)bufferCapacity {
  return BGSFlutterLifecycleBufferCapacity;
}

+ (NSUInteger)dropLogEvery {
  return BGSFlutterLifecycleDropLogEvery;
}

+ (instancetype)shared {
  static BGSFlutterLifecycleHub *hub;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    hub = [[BGSFlutterLifecycleHub alloc] initWithDeliveryQueue:dispatch_get_main_queue()];
  });
  return hub;
}

- (instancetype)initWithDeliveryQueue:(dispatch_queue_t)queue {
  if ((self = [super init])) {
    _queue = queue;
    _buffer = [NSMutableArray array];
    _tokens = [NSMutableArray array];
  }
  return self;
}

+ (BGSFlutterLifecycleEvent *)eventForRawName:(NSString *)rawName data:(id)data {
  // Once. A name that merely starts with the prefix twice keeps the second. The
  // bare prefix has no name to strip down to, so it is forwarded as is.
  NSString *name = rawName;
  if ([rawName hasPrefix:BGSFlutterLifecyclePrefix] &&
      rawName.length > BGSFlutterLifecyclePrefix.length) {
    name = [rawName substringFromIndex:BGSFlutterLifecyclePrefix.length];
  }
  NSString *reportId = nil;
  NSDictionary<NSString *, NSString *> *payload = nil;
  if ([data isKindOfClass:[NSString class]]) {
    // Carried, not interpreted; and only by the events that carry one.
    if ([BGSFlutterReportIdEvents() containsObject:name]) {
      reportId = data;
    }
  } else if ([data isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary<NSString *, NSString *> *cleaned = [NSMutableDictionary dictionary];
    [(NSDictionary *)data enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
      if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
        cleaned[key] = value;
      }
    }];
    if (cleaned.count > 0) {
      payload = cleaned;
    }
  }
  return [[BGSFlutterLifecycleEvent alloc] initWithName:name reportId:reportId data:payload];
}

- (void)dispatchRawName:(NSString *)rawName data:(id)data {
  if (![rawName isKindOfClass:[NSString class]]) {
    return;
  }
  @try {
    BGSFlutterLifecycleEvent *event = [BGSFlutterLifecycleHub eventForRawName:rawName data:data];
    @synchronized(self) {
      if ([BGSFlutterStatusEvents() containsObject:event.name]) {
        _lastStatus = event;
      }
      if (_tokens.count == 0) {
        [self bufferLocked:event];
      } else {
        for (BGSFlutterLifecycleSinkToken *token in [_tokens copy]) {
          [self postLocked:token event:event];
        }
      }
    }
  } @catch (NSException *exception) {
    NSLog(@"[BugseeFlutter] could not forward lifecycle event: %@", exception.name);
  }
}

/// Adds a receiver: every attached receiver gets every event (a background engine must
/// not take events from the UI engine). The new receiver first gets what it missed, in
/// order: the events buffered while nobody was attached, preceded by the latest status
/// event when the buffer does not already hold it.
- (id)attachSink:(BGSFlutterLifecycleSink)sink {
  BGSFlutterLifecycleSinkToken *token = [[BGSFlutterLifecycleSinkToken alloc] initWithSink:sink];
  @synchronized(self) {
    [_tokens addObject:token];
    if (_lastStatus != nil && ![_buffer containsObject:_lastStatus]) {
      [self postLocked:token event:_lastStatus];
    }
    NSArray<BGSFlutterLifecycleEvent *> *pending = [_buffer copy];
    [_buffer removeAllObjects];
    for (BGSFlutterLifecycleEvent *event in pending) {
      [self postLocked:token event:event];
    }
  }
  return token;
}

/// Removes only this receiver. Events posted to it that have not run yet are not lost:
/// when no receiver remains they go back to the FRONT of the buffer, in their original
/// order (older than anything buffered since); other receivers hold their own copies.
- (void)detach:(id)tokenObject {
  [self detach:tokenObject undelivered:nil];
}

- (void)detach:(id)tokenObject undelivered:(NSArray<BGSFlutterLifecycleEvent *> *)undelivered {
  @synchronized(self) {
    BGSFlutterLifecycleSinkToken *token = tokenObject;
    if (![_tokens containsObject:token]) {
      return;
    }
    [_tokens removeObject:token];
    if (_tokens.count == 0 && (token.inFlight.count > 0 || undelivered.count > 0)) {
      // `undelivered` (taken from the sink but never sent) is older than what was
      // still waiting for the sink, so it goes first.
      NSMutableArray<BGSFlutterLifecycleEvent *> *back = [NSMutableArray arrayWithArray:undelivered ?: @[]];
      [back addObjectsFromArray:token.inFlight];
      [_buffer replaceObjectsInRange:NSMakeRange(0, 0) withObjectsFromArray:back];
      while (_buffer.count > BGSFlutterLifecycleBufferCapacity) {
        [_buffer removeObjectAtIndex:0];
        [self noteDropLocked];
      }
    }
    [token.inFlight removeAllObjects];
  }
}

- (NSUInteger)droppedCount {
  @synchronized(self) {
    return _dropped;
  }
}

- (NSUInteger)bufferedCount {
  @synchronized(self) {
    return _buffer.count;
  }
}

/// Caller holds the lock. Queued while holding it, so flush and live events keep order.
- (void)postLocked:(BGSFlutterLifecycleSinkToken *)token event:(BGSFlutterLifecycleEvent *)event {
  [token.inFlight addObject:event];
  dispatch_async(_queue, ^{
    BGSFlutterLifecycleEvent *next = nil;
    @synchronized(self) {
      if (token.inFlight.count == 0) {
        return;  // empty once detached: -detach: cleared it after putting the events back
      }
      next = token.inFlight.firstObject;
      [token.inFlight removeObjectAtIndex:0];
    }
    @try {
      token.sink(next);
    } @catch (NSException *exception) {
      NSLog(@"[BugseeFlutter] lifecycle sink threw for %@: %@", next.name, exception.name);
    }
  });
}

/// Caller holds the lock.
- (void)bufferLocked:(BGSFlutterLifecycleEvent *)event {
  [_buffer addObject:event];
  if (_buffer.count > BGSFlutterLifecycleBufferCapacity) {
    [_buffer removeObjectAtIndex:0];
    [self noteDropLocked];
  }
}

/// Caller holds the lock. Counts every drop; logs the first and then every Nth.
- (void)noteDropLocked {
  _dropped += 1;
  if (_dropped == 1 || _dropped % BGSFlutterLifecycleDropLogEvery == 0) {
    NSLog(@"[BugseeFlutter] lifecycle buffer full (%lu), dropped the oldest event; total dropped %lu",
          (unsigned long)BGSFlutterLifecycleBufferCapacity, (unsigned long)_dropped);
  }
}

@end
