#import "BGSFlutterLaunchOps.h"

@import Bugsee;

@implementation BGSFlutterRealBugsee

- (NSString *)statusName {
  switch ([Bugsee sharedInstance].status) {
    case BugseeStatusLaunching:
      return @"launching";
    case BugseeStatusLaunched:
      return @"launched";
    case BugseeStatusStopping:
      return @"stopping";
    case BugseeStatusStopped:
    default:
      // No shared instance yet (nil) reads as stopped, as a status of 0 does.
      return @"stopped";
  }
}

- (void)launchWithToken:(NSString *)token
                options:(NSDictionary<NSString *, id> *)options
                started:(void (^)(BOOL))started {
  // `+optionsFrom:` is nil for an empty dictionary, which `launchWithToken:options:started:` takes.
  // The dictionary form of launch has no `started:`, so the object form is used.
  [Bugsee launchWithToken:token options:[BugseeOptions optionsFrom:options] started:started];
}

- (void)stop:(void (^)(void))done {
  [Bugsee stop:done];
}

- (NSDictionary<NSString *, id> *)launchOptionsHostOnly:(BOOL)hostOnly {
  return hostOnly ? [Bugsee getHostLaunchOptions] : [Bugsee getLaunchOptions];
}

@end

static NSString *const kLaunched = @"launched";
static NSString *const kAlreadyRunning = @"already-running";
static NSString *const kDeferred = @"deferred";
static NSString *const kRefused = @"refused";
static NSString *const kInvalidToken = @"invalid-token";
static NSString *const kStopping = @"stopping";
static NSString *const kFailed = @"failed";
static NSString *const kErrorCode = @"launch-failed";

static NSLock *StopLock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [[NSLock alloc] init];
  });
  return lock;
}
static NSInteger gStopsInFlight = 0;

static BOOL StopInFlight(void) {
  [StopLock() lock];
  BOOL inFlight = gStopsInFlight > 0;
  [StopLock() unlock];
  return inFlight;
}

@implementation BGSFlutterLaunchOps

+ (void)beginStop {
  [StopLock() lock];
  gStopsInFlight++;
  [StopLock() unlock];
}

+ (NSString *)launched { return kLaunched; }
+ (NSString *)alreadyRunning { return kAlreadyRunning; }
+ (NSString *)deferred { return kDeferred; }
+ (NSString *)refused { return kRefused; }
+ (NSString *)invalidToken { return kInvalidToken; }
+ (NSString *)stopping { return kStopping; }
+ (NSString *)failed { return kFailed; }
+ (NSString *)errorCode { return kErrorCode; }

+ (NSDictionary<NSString *, id> *)sdkOptionsFromFlat:(NSDictionary *)flat {
  NSMutableDictionary<NSString *, id> *out = [NSMutableDictionary dictionary];
  if (![flat isKindOfClass:[NSDictionary class]]) {
    return out;
  }
  [flat enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    if ([key isKindOfClass:[NSString class]] &&
        ([value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]])) {
      out[key] = value;
    }
  }];
  return out;
}

+ (NSError *)errorFromException:(NSException *)exception {
  // The name and reason only: never the token or the options.
  return [NSError errorWithDomain:@"com.bugsee.flutter"
                             code:1
                         userInfo:@{
                           NSLocalizedDescriptionKey :
                               [NSString stringWithFormat:@"%@: %@", exception.name,
                                                          exception.reason ?: @"(no reason)"]
                         }];
}

+ (void)launchWithSdk:(id<BGSFlutterBugseeSDK>)sdk
                token:(NSString *)token
              options:(NSDictionary *)flat
           completion:(void (^)(NSString *, NSString *, NSError *))completion {
  // The SDK's callback is answered to Dart ONCE: a second call (a deferred launch that later
  // starts) would resume the Swift side's checked continuation twice, which traps.
  NSLock *answeredLock = [[NSLock alloc] init];
  __block BOOL answered = NO;
  @try {
    if (![token isKindOfClass:[NSString class]] ||
        [[token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            length] == 0) {
      completion(kRefused, kInvalidToken, nil);
      return;
    }
    NSString *status = [sdk statusName];
    // A stop that was requested but that the SDK has not started yet outranks what the status
    // still says (see +beginStop).
    if (StopInFlight() || [status isEqualToString:@"stopping"]) {
      completion(kRefused, kStopping, nil);
      return;
    }
    if ([status isEqualToString:@"launching"] || [status isEqualToString:@"launched"]) {
      completion(kAlreadyRunning, nil, nil);
      return;
    }
    NSDictionary<NSString *, id> *options = [self sdkOptionsFromFlat:flat];
    [sdk launchWithToken:token
                 options:options
                 started:^(BOOL success) {
                   [answeredLock lock];
                   const BOOL already = answered;
                   answered = YES;
                   [answeredLock unlock];
                   if (already) {
                     return;
                   }
                   if (!success) {
                     completion(kRefused, kFailed, nil);
                     return;
                   }
                   // YES with the SDK still stopped: the app is in the background and the SDK
                   // starts when it becomes active.
                   completion([[sdk statusName] isEqualToString:@"stopped"] ? kDeferred : kLaunched,
                              nil, nil);
                 }];
  } @catch (NSException *exception) {
    [answeredLock lock];
    const BOOL already = answered;
    [answeredLock unlock];
    // An SDK that called back and then threw has already been answered.
    if (!already) {
      completion(nil, nil, [self errorFromException:exception]);
    }
  }
}

+ (void)endStop {
  [StopLock() lock];
  if (gStopsInFlight > 0) gStopsInFlight--;
  [StopLock() unlock];
}

+ (void)stopWithSdk:(id<BGSFlutterBugseeSDK>)sdk done:(void (^)(NSError *))done {
  @try {
    [sdk stop:^{
      [self endStop];
      done(nil);
    }];
  } @catch (NSException *exception) {
    [self endStop];
    done([self errorFromException:exception]);
  }
}

+ (NSDictionary<NSString *, id> *)reportedOptionsFromSdk:(NSDictionary *)sdk {
  NSMutableDictionary<NSString *, id> *out = [NSMutableDictionary dictionary];
  if (![sdk isKindOfClass:[NSDictionary class]]) {
    return out;
  }
  [sdk enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    if (![key isKindOfClass:[NSString class]]) {
      return;
    }
    if ([value isKindOfClass:[NSString class]]) {
      out[key] = value;
    } else if ([value isKindOfClass:[NSNumber class]]) {
      // A float (32 bit) is reported as a double; a bool stays a bool.
      const char *type = [value objCType];
      if (strcmp(type, "f") == 0 || strcmp(type, "d") == 0) {
        out[key] = @([value doubleValue]);
      } else {
        out[key] = value;
      }
    }
  }];
  return out;
}

@end
