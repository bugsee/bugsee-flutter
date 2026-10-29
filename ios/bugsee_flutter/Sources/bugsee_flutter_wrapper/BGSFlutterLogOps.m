#import "BGSFlutterLogOps.h"

#import "BGSFlutterNetworkOps.h"

@import Bugsee;
// 7.0 GA moves the wrapper contract to the Bugsee.SPI submodule (BugseeSPI.h);
// the 7.0 betas declare it in Bugsee.h.
#if __has_include(<Bugsee/BugseeSPI.h>)
#import <Bugsee/BugseeSPI.h>
#endif

static const NSInteger kMinLevel = 1;
static const NSInteger kMaxLevel = 5;

@implementation BGSFlutterRealLogSdk

- (BOOL)acceptsLogs {
  Bugsee *bugsee = [Bugsee sharedInstance];
  if (bugsee == nil || (bugsee.status != BugseeStatusLaunched && bugsee.status != BugseeStatusLaunching)) {
    return NO;
  }
  // The option's own default: capture.logs is on unless the app turned it off.
  id capture = [Bugsee getLaunchOptions][BugseeOptionCaptureLogs];
  return capture == nil || ![capture isKindOfClass:[NSNumber class]] || [capture boolValue];
}

- (BOOL)submitLogWithTag:(NSString *)tag message:(NSString *)message level:(NSInteger)level {
  id<BGSWrapperChannel> channel = [BGSFlutterNetworkChannel shared].channel;
  if (channel == nil || ![channel respondsToSelector:@selector(logWithTag:message:level:source:)]) {
    return NO;
  }
  // Attributed to the wrapper, and always filtered by the SDK (the channel has no flag).
  [channel logWithTag:tag message:message level:(BugseeLogLevel)level source:BGSLogEventSourceCustom];
  return YES;
}

@end

static NSString *StringOrNil(id value) {
  return [value isKindOfClass:[NSString class]] ? value : nil;
}

@implementation BGSFlutterLogOps

+ (NSInteger)minLevel {
  return kMinLevel;
}

+ (NSInteger)maxLevel {
  return kMaxLevel;
}

+ (NSInteger)wrapperSource {
  return BGSLogEventSourceCustom;
}

+ (NSInteger)addLinesWithSdk:(id<BGSFlutterLogSDK>)sdk lines:(NSArray<NSDictionary<NSString *, id> *> *)lines {
  if (![lines isKindOfClass:[NSArray class]] || lines.count == 0) {
    return 0;
  }
  @try {
    if (![sdk acceptsLogs]) {
      return 0;
    }
  } @catch (NSException *exception) {
    return 0;
  }
  NSInteger handed = 0;
  for (NSDictionary<NSString *, id> *line in lines) {
    if ([self addLineWithSdk:sdk line:line]) {
      handed++;
    }
  }
  return handed;
}

+ (BOOL)addLineWithSdk:(id<BGSFlutterLogSDK>)sdk line:(NSDictionary<NSString *, id> *)line {
  if (![line isKindOfClass:[NSDictionary class]]) {
    return NO;
  }
  NSString *message = StringOrNil(line[@"message"]);
  id levelValue = line[@"level"];
  NSInteger level = [levelValue isKindOfClass:[NSNumber class]] ? [levelValue integerValue] : 0;
  if (message.length == 0 || level < kMinLevel || level > kMaxLevel) {
    return NO;
  }
  NSString *tag = StringOrNil(line[@"tag"]);
  if (tag.length == 0) tag = nil;
  @try {
    return [sdk submitLogWithTag:tag message:message level:level];
  } @catch (NSException *exception) {
    // The app's native log filter (or the SDK) threw on this thread: the line is dropped.
    return NO;
  }
}

@end
