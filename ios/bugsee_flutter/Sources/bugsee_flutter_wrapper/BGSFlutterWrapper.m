#import "BGSFlutterWrapper.h"

#import "BGSFlutterLifecycleHub.h"
#import "BGSFlutterReportHandlerPipeline.h"
#import "BGSFlutterSecureRectangleStore.h"
#import "BGSFlutterViewHierarchyStore.h"

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

@implementation BGSFlutterWrapper {
  // Process-wide objects, held by reference: this wrapper is replaced when Dart
  // refines the identity, so nothing that must survive that lives in it (5.4.2).
  BGSFlutterLifecycleHub *_hub;
  BGSFlutterSecureRectangleStore *_secureRectangles;
  BGSFlutterReportHandlerPipeline *_reports;
  BGSFlutterViewHierarchyStore *_views;
}

+ (instancetype)wrapperAtProcessStart {
  return [self wrapperWithType:BGSFlutterWrapperType
                       version:BGSFlutterWrapperVersion
                         build:nil
                       context:nil];
}

+ (instancetype)wrapperWithType:(id)type version:(id)version build:(id)build context:(id)context {
  return [self wrapperWithType:type
                       version:version
                         build:build
                       context:context
                           hub:[BGSFlutterLifecycleHub shared]
              secureRectangles:[BGSFlutterSecureRectangleStore shared]
                       reports:[BGSFlutterReportHandlerPipeline shared]];
}

+ (instancetype)wrapperWithType:(id)type
                        version:(id)version
                          build:(id)build
                        context:(id)context
                            hub:(BGSFlutterLifecycleHub *)hub
               secureRectangles:(BGSFlutterSecureRectangleStore *)secureRectangles {
  return [self wrapperWithType:type
                       version:version
                         build:build
                       context:context
                           hub:hub
              secureRectangles:secureRectangles
                       reports:[BGSFlutterReportHandlerPipeline shared]];
}

+ (instancetype)wrapperWithType:(id)type
                        version:(id)version
                          build:(id)build
                        context:(id)context
                            hub:(BGSFlutterLifecycleHub *)hub
               secureRectangles:(BGSFlutterSecureRectangleStore *)secureRectangles
                        reports:(BGSFlutterReportHandlerPipeline *)reports {
  return [self wrapperWithType:type
                       version:version
                         build:build
                       context:context
                           hub:hub
              secureRectangles:secureRectangles
                       reports:reports
                 viewHierarchy:[BGSFlutterViewHierarchyStore shared]];
}

+ (instancetype)wrapperWithType:(id)type
                        version:(id)version
                          build:(id)build
                        context:(id)context
                            hub:(BGSFlutterLifecycleHub *)hub
               secureRectangles:(BGSFlutterSecureRectangleStore *)secureRectangles
                        reports:(BGSFlutterReportHandlerPipeline *)reports
                  viewHierarchy:(BGSFlutterViewHierarchyStore *)views {
  BGSFlutterWrapper *wrapper = [[BGSFlutterWrapper alloc] init];
  wrapper->_views = views;
  wrapper->_hub = hub;
  wrapper->_secureRectangles = secureRectangles;
  wrapper->_reports = reports;
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

// Always answers, exactly once, and never throws (workbook 6.1): `vh` (the managed view
// hierarchy) from BGSFlutterViewHierarchyStore, SYNCHRONOUSLY, on whatever thread the SDK asks
// (the main thread: a reply that waited for Dart would deadlock it), and every other type, and
// `vh` when there is nothing to say, with nil. The SDK stores a non-nil reply byte for byte, so
// the store has already made it safe to store (privacy is Dart's: no text; fail closed here).
- (void)requestDataWithType:(NSString *)dataType callback:(id<BGSDataRequestResultCallback>)callback {
  @try {
    NSString *answer = nil;
    if ([[BGSFlutterViewHierarchyStore dataType] isEqualToString:dataType]) {
      answer = [_views answer];
    }
    [callback onResult:answer];
  } @catch (NSException *exception) {
    // The SDK must never see a throw from a wrapper.
  }
}

- (void)onLifecycleEvent:(NSString *)eventType data:(id)data {
  // The SDK's serial queue. The hub strips the prefix, hops to the main queue
  // and never throws.
  [_hub dispatchRawName:eventType data:data];
}

- (NSData *)secureRectanglesForDisplay:(NSInteger)display {
  // From the store, not from this object: this wrapper is replaced.
  return [_secureRectangles pullForDisplay:display];
}

// Report handlers (workbook Part 7): see BGSFlutterReportHandlerPipeline. On the live path the
// SDK calls these ON THE MAIN THREAD, on recovery on a worker, so nothing here may block, and the
// SDK's completion runs exactly once whatever happens. The pipeline is process-wide, not part of
// this replaceable object.
- (void)onBeforeReportCreated:(id<BGSReportContract>)report
                isTerminating:(BOOL)isTerminating
                   completion:(BGSCallback)completion {
  [_reports dispatchPhase:BGSFlutterReportPhaseBefore
                   report:report
            isTerminating:isTerminating
             onMainThread:[NSThread isMainThread]
               completion:completion];
}

- (void)onAfterReportCreated:(id<BGSReportContract>)report
               isTerminating:(BOOL)isTerminating
                  completion:(BGSCallback)completion {
  [_reports dispatchPhase:BGSFlutterReportPhaseAfter
                   report:report
            isTerminating:isTerminating
             onMainThread:[NSThread isMainThread]
               completion:completion];
}

@end

@implementation BGSFlutterWrapperRegistrar

static BGSFlutterWrapper *gWrapper;
static void (^gRegister)(id);

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
      [self submit:(id<BugseeWrapper>)gWrapper];
      NSLog(@"[BugseeFlutter] wrapper registered type=%@ version=%@", gWrapper.wrapperType,
            gWrapper.wrapperVersion);
    } @catch (NSException *exception) {
      NSLog(@"[BugseeFlutter] could not register the wrapper: %@", exception.name);
    }
  }
}

+ (BOOL)replaceWithType:(id)type version:(id)version build:(id)build context:(id)context {
  @synchronized(self) {
    @try {
      BGSFlutterWrapper *refined = [BGSFlutterWrapper wrapperWithType:type
                                                              version:version
                                                                build:build
                                                              context:context];
      // Replaces the object only. The lifecycle hub and the secure-rectangle store
      // are process-wide and keep their state (5.4.2).
      gWrapper = refined;
      [self submit:(id<BugseeWrapper>)refined];
      NSLog(@"[BugseeFlutter] wrapper refined type=%@ version=%@ context=%@", refined.wrapperType,
            refined.wrapperVersion, refined.context);
      return YES;
    } @catch (NSException *exception) {
      NSLog(@"[BugseeFlutter] could not register the refined wrapper: %@", exception.name);
      return NO;
    }
  }
}

+ (void)submit:(id<BugseeWrapper>)wrapper {
  void (^seam)(id) = gRegister;
  if (seam != nil) {
    seam(wrapper);
  } else {
    [Bugsee setWrapper:wrapper];
  }
}

+ (void)setRegistrationHandlerForTests:(void (^)(id))handler {
  @synchronized(self) {
    gRegister = [handler copy];
  }
}

@end
