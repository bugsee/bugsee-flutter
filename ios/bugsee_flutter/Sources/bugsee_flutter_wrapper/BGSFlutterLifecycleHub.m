#import "BGSFlutterLifecycleHub.h"

static NSString *const BGSFlutterLifecyclePrefix = @"com.bugsee.lifecycle.";
static const NSUInteger BGSFlutterLifecycleBufferCapacity = 64;

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

/// Identity-compared handle returned by -attachSink:.
@interface BGSFlutterLifecycleSinkToken : NSObject
@property(nonatomic, copy, readonly) BGSFlutterLifecycleSink sink;
@end
@implementation BGSFlutterLifecycleSinkToken
- (instancetype)initWithSink:(BGSFlutterLifecycleSink)sink {
  if ((self = [super init])) {
    _sink = [sink copy];
  }
  return self;
}
@end

@implementation BGSFlutterLifecycleHub {
  dispatch_queue_t _queue;
  NSMutableArray<BGSFlutterLifecycleEvent *> *_buffer;
  BGSFlutterLifecycleSinkToken *_token;
  NSUInteger _dropped;
}

+ (NSString *)prefix {
  return BGSFlutterLifecyclePrefix;
}

+ (NSUInteger)bufferCapacity {
  return BGSFlutterLifecycleBufferCapacity;
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
      if (_token == nil) {
        [self bufferLocked:event];
      } else {
        [self postLocked:_token event:event];
      }
    }
  } @catch (NSException *exception) {
    NSLog(@"[BugseeFlutter] could not forward lifecycle event: %@", exception.name);
  }
}

- (id)attachSink:(BGSFlutterLifecycleSink)sink {
  BGSFlutterLifecycleSinkToken *token = [[BGSFlutterLifecycleSinkToken alloc] initWithSink:sink];
  @synchronized(self) {
    _token = token;
    NSArray<BGSFlutterLifecycleEvent *> *pending = [_buffer copy];
    [_buffer removeAllObjects];
    for (BGSFlutterLifecycleEvent *event in pending) {
      [self postLocked:token event:event];
    }
  }
  return token;
}

- (void)detach:(id)token {
  @synchronized(self) {
    if (_token == token) {
      _token = nil;
    }
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
  dispatch_async(_queue, ^{
    BOOL stillCurrent;
    @synchronized(self) {
      stillCurrent = (self->_token == token);
      if (!stillCurrent) {
        // Detached between the post and now: keep it for the next attach
        // rather than send into a dead engine.
        [self bufferLocked:event];
      }
    }
    if (!stillCurrent) {
      return;
    }
    @try {
      token.sink(event);
    } @catch (NSException *exception) {
      NSLog(@"[BugseeFlutter] lifecycle sink threw for %@: %@", event.name, exception.name);
    }
  });
}

/// Caller holds the lock.
- (void)bufferLocked:(BGSFlutterLifecycleEvent *)event {
  [_buffer addObject:event];
  if (_buffer.count > BGSFlutterLifecycleBufferCapacity) {
    [_buffer removeObjectAtIndex:0];
    _dropped += 1;
    NSLog(@"[BugseeFlutter] lifecycle buffer full (%lu), dropped the oldest event; total dropped %lu",
          (unsigned long)BGSFlutterLifecycleBufferCapacity, (unsigned long)_dropped);
  }
}

@end
