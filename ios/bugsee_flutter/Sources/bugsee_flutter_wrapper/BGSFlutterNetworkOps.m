#import "BGSFlutterNetworkOps.h"

@import Bugsee;

static NSString *const kStageBefore = @"before";
static NSString *const kStageRedirect = @"redirect";
static NSString *const kStageComplete = @"complete";
static NSString *const kStageError = @"error";
static NSString *const kStageAbort = @"abort";

static const int64_t kMaxAgeMs = 60LL * 60LL * 1000LL;

@implementation BGSFlutterNetworkChannel

+ (instancetype)shared {
  static BGSFlutterNetworkChannel *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[BGSFlutterNetworkChannel alloc] init];
  });
  return shared;
}

@end

@implementation BGSFlutterRealNetworkSdk

- (BOOL)acceptsNetworkEvents {
  Bugsee *bugsee = [Bugsee sharedInstance];
  if (bugsee == nil || bugsee.status != BugseeStatusLaunched) {
    return NO;
  }
  // The option's own default: capture.network is on unless the app turned it off.
  id capture = [Bugsee getLaunchOptions][BugseeOptionCaptureNetwork];
  return capture == nil || ![capture isKindOfClass:[NSNumber class]] || [capture boolValue];
}

- (NSTimeInterval)currentTimestampMs {
  // `BugseeGetCurrentTimeStampMs` (BGSUtil.m) is not public: it is exactly this.
  return (CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970) * 1000.0;
}

- (BOOL)submitNetworkEvent:(id)event {
  id<BGSWrapperChannel> channel = [BGSFlutterNetworkChannel shared].channel;
  if (channel == nil || ![channel respondsToSelector:@selector(addNetworkEvent:requiresFiltering:)]) {
    return NO;
  }
  // Filtering REQUIRED: the default sanitizer and the app's native filter must see it.
  [channel addNetworkEvent:event requiresFiltering:YES];
  return YES;
}

@end

static NSString *StringOrNil(id value) {
  return [value isKindOfClass:[NSString class]] ? value : nil;
}

static int64_t IntegerOr(id value, int64_t fallback) {
  return [value isKindOfClass:[NSNumber class]] ? [value longLongValue] : fallback;
}

@implementation BGSFlutterNetworkOps

+ (NSArray<NSString *> *)stageNames {
  return @[ kStageBefore, kStageRedirect, kStageComplete, kStageError, kStageAbort ];
}

+ (int64_t)maxAgeMs {
  return kMaxAgeMs;
}

+ (NSString *)sdkStageForWire:(NSString *)wire {
  if ([wire isEqualToString:kStageBefore]) return BugseeNetworkEventBegin;
  if ([wire isEqualToString:kStageComplete]) return BugseeNetworkEventComplete;
  if ([wire isEqualToString:kStageError]) return BugseeNetworkEventError;
  // iOS spells it `cancel` (the bundle schema says `abort`; the SDK's own interception emits
  // `cancel`, so a bundle from either route reads the same).
  if ([wire isEqualToString:kStageAbort]) return BugseeNetworkEventCancel;
  // `redirect` has no iOS stage: the SDK reports it as `redirectedFromURL` on the final event.
  return nil;
}

+ (NSInteger)addEventsWithSdk:(id<BGSFlutterNetworkSDK>)sdk
                       events:(NSArray<NSDictionary<NSString *, id> *> *)events {
  if (![events isKindOfClass:[NSArray class]] || events.count == 0) {
    return 0;
  }
  @try {
    if (![sdk acceptsNetworkEvents]) {
      return 0;
    }
  } @catch (NSException *exception) {
    return 0;
  }
  NSInteger handed = 0;
  for (NSDictionary<NSString *, id> *event in events) {
    if ([self addEventWithSdk:sdk event:event]) {
      handed++;
    }
  }
  return handed;
}

+ (BOOL)addEventWithSdk:(id<BGSFlutterNetworkSDK>)sdk event:(NSDictionary<NSString *, id> *)message {
  if (![message isKindOfClass:[NSDictionary class]]) {
    return NO;
  }
  NSString *stage = [self sdkStageForWire:StringOrNil(message[@"stage"])];
  NSString *identifier = StringOrNil(message[@"id"]);
  NSString *url = StringOrNil(message[@"url"]);
  NSString *mechanism = StringOrNil(message[@"mechanism"]);
  if (stage == nil || identifier.length == 0 || url.length == 0 || mechanism.length == 0) {
    return NO;
  }

  NSMutableDictionary<NSString *, NSString *> *headers = nil;
  if ([message[@"headers"] isKindOfClass:[NSDictionary class]]) {
    headers = [NSMutableDictionary dictionary];
    [(NSDictionary *)message[@"headers"] enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
      if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
        headers[key] = value;
      }
    }];
  }

  NSString *bodyText = StringOrNil(message[@"body"]);
  NSData *body = bodyText == nil ? nil : [bodyText dataUsingEncoding:NSUTF8StringEncoding];
  NSString *reason = StringOrNil(message[@"noBodyReason"]);
  if (reason.length == 0) reason = nil;
  int64_t size = MAX(0, IntegerOr(message[@"size"], 0));
  int64_t status = IntegerOr(message[@"statusCode"], 0);
  if (status < 0 || status > 999) status = 0;
  int64_t age = MIN(kMaxAgeMs, MAX(0, IntegerOr(message[@"ageMs"], 0)));

  // The SDK's error dictionary: `description` is what the bundle's `custom.error` shows. iOS has no
  // field for a longer description than the short one, so the short one is what it keeps.
  NSString *errorText = StringOrNil(message[@"errorShortMessage"]);
  if (errorText.length == 0) errorText = StringOrNil(message[@"errorDescription"]);
  NSDictionary *error = errorText.length == 0 ? nil : @{
    @"description" : errorText,
    @"code" : @0,
    @"domain" : @"dart:io",
  };

  NSString *redirectedFrom = StringOrNil(message[@"redirectedFromUrl"]);
  if (redirectedFrom.length == 0) redirectedFrom = nil;

  @try {
    BugseeNetworkEvent *event = [BugseeNetworkEvent eventWithID:identifier
                                                     HTTPmethod:StringOrNil(message[@"method"])
                                                           type:BugseeNetwork
                                                bugseeEventType:stage
                                                            url:url
                                                  redirectedUrl:redirectedFrom
                                                           body:body
                                                          error:error
                                                        headers:headers
                                                   noBodyReason:reason
                                                       dataSize:size
                                                   responseCode:(NSInteger)status];
    event.mechanism = mechanism;
    event.timestamp = [sdk currentTimestampMs] - (NSTimeInterval)age;
    return [sdk submitNetworkEvent:event];
  } @catch (NSException *exception) {
    // The app's native filter (or the SDK) threw on this thread: the event is dropped.
    return NO;
  }
}

@end
