#import "BGSFlutterWrapper.h"

@import Bugsee;

// The wrapper identity on iOS, in one place. The type is the backend's
// identifier (Dart: `wrapperType`); the version must equal `version:` in
// pubspec.yaml (Dart: `wrapperVersion`). A SwiftPM manifest cannot read
// pubspec.yaml, so the version is a literal;
// test/wrapper_identity_test.dart fails if any copy drifts.
static NSString *const BGSFlutterWrapperType = @"flutter";
static NSString *const BGSFlutterWrapperVersion = @"10.0.0-dev.1";

static NSString *const BGSFlutterUnknown = @"unknown";

static NSString *BGSFlutterStringOr(id value, NSString *fallback) {
  return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : fallback;
}

@interface BGSFlutterWrapper () <BugseeWrapper>
@end

@implementation BGSFlutterWrapper

+ (instancetype)wrapperAtProcessStart {
  return [self wrapperWithType:BGSFlutterWrapperType
                       version:BGSFlutterWrapperVersion
                         build:nil
                       context:nil];
}

+ (instancetype)wrapperWithType:(id)type version:(id)version build:(id)build context:(id)context {
  BGSFlutterWrapper *wrapper = [[BGSFlutterWrapper alloc] init];
  wrapper->_wrapperType = [BGSFlutterStringOr(type, BGSFlutterUnknown) copy];
  wrapper->_wrapperVersion = [BGSFlutterStringOr(version, BGSFlutterUnknown) copy];
  wrapper->_wrapperBuild = [build isKindOfClass:[NSString class]] ? [build copy] : nil;
  NSMutableDictionary<NSString *, NSString *> *cleaned = [NSMutableDictionary dictionary];
  if ([context isKindOfClass:[NSDictionary class]]) {
    [(NSDictionary *)context enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
      if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
        cleaned[key] = value;
      }
    }];
  }
  wrapper->_context = [cleaned copy];
  return wrapper;
}

- (void)requestDataWithType:(NSString *)dataType callback:(id<BGSDataRequestResultCallback>)callback {
  @try {
    [callback onResult:nil];
  } @catch (NSException *exception) {
    // The SDK must never see a throw from a wrapper.
  }
}

- (void)onLifecycleEvent:(NSString *)eventType data:(id)data {
}

- (NSData *)secureRectanglesForDisplay:(NSInteger)display {
  // [version, count] as int32: no rectangles. Version 0 is the contract's
  // "unknown": the SDK then compares the rectangles themselves. A constant
  // version here would let a later wrapper that also starts at the same
  // version and carries real rectangles be ignored (unredacted capture).
  int32_t ints[2] = {0, 0};
  return [NSData dataWithBytes:ints length:sizeof(ints)];
}

- (void)onBeforeReportCreated:(id<BGSReportContract>)report
                isTerminating:(BOOL)isTerminating
                   completion:(BGSCallback)completion {
  completion();
}

- (void)onAfterReportCreated:(id<BGSReportContract>)report
               isTerminating:(BOOL)isTerminating
                  completion:(BGSCallback)completion {
  completion();
}

@end

@implementation BGSFlutterWrapperRegistrar

static BGSFlutterWrapper *gWrapper;

+ (void)load {
  [self ensureRegistered];
}

+ (void)ensureRegistered {
  @synchronized(self) {
    // Only the first call registers. Later calls (a second engine's
    // register(with:)) must not re-submit this placeholder over a richer wrapper
    // that replaced it once the runtime was up (workbook 2.4.2).
    if (gWrapper != nil) {
      return;
    }
    @try {
      gWrapper = [BGSFlutterWrapper wrapperAtProcessStart];
      [Bugsee setWrapper:(id<BugseeWrapper>)gWrapper];
      NSLog(@"[BugseeFlutter] wrapper registered type=%@ version=%@", gWrapper.wrapperType,
            gWrapper.wrapperVersion);
    } @catch (NSException *exception) {
      NSLog(@"[BugseeFlutter] could not register the wrapper: %@", exception.name);
    }
  }
}

@end
