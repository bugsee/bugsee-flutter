#import <Foundation/Foundation.h>

@class BGSFlutterLifecycleHub;
@class BGSFlutterReportHandlerPipeline;
@class BGSFlutterSecureRectangleStore;

NS_ASSUME_NONNULL_BEGIN

/// The Flutter wrapper registered with the Bugsee SDK, and the one place its iOS
/// identity lives. Declared without conforming to `BugseeWrapper` here so the
/// header needs no SDK import; the conformance is declared in the .m.
///
/// Identity is real (workbook Part 3), lifecycle events are forwarded (Part 4), report
/// handlers go through `BGSFlutterReportHandlerPipeline` (Part 7), and data requests are
/// answered with nil until Phase 5. None of it throws.
///
/// This object is replaced mid-session when Dart refines the identity, so it holds
/// no state that must survive: lifecycle events go to the process-wide
/// `BGSFlutterLifecycleHub` and secure rectangles come from the process-wide
/// `BGSFlutterSecureRectangleStore` (5.4.2).
@interface BGSFlutterWrapper : NSObject

@property(nonatomic, copy, readonly) NSString *wrapperType;
@property(nonatomic, copy, readonly) NSString *wrapperVersion;
@property(nonatomic, copy, readonly, nullable) NSString *wrapperBuild;
@property(nonatomic, copy, readonly, nullable) NSDictionary<NSString *, NSString *> *context;

/// The identity knowable before Dart exists: type and version only.
+ (instancetype)wrapperAtProcessStart;

/// A missing or empty type/version becomes "unknown"; context entries that are
/// not string-to-string are dropped, not stringified.
+ (instancetype)wrapperWithType:(nullable id)type
                        version:(nullable id)version
                          build:(nullable id)build
                        context:(nullable id)context;

/// As above with the process-wide collaborators supplied; for tests.
+ (instancetype)wrapperWithType:(nullable id)type
                        version:(nullable id)version
                          build:(nullable id)build
                        context:(nullable id)context
                            hub:(BGSFlutterLifecycleHub *)hub
               secureRectangles:(BGSFlutterSecureRectangleStore *)secureRectangles;

/// As above with every process-wide collaborator supplied; for tests.
+ (instancetype)wrapperWithType:(nullable id)type
                        version:(nullable id)version
                          build:(nullable id)build
                        context:(nullable id)context
                            hub:(BGSFlutterLifecycleHub *)hub
               secureRectangles:(BGSFlutterSecureRectangleStore *)secureRectangles
                        reports:(BGSFlutterReportHandlerPipeline *)reports;

@end

/// Registers the wrapper at image load, independent of the Flutter engine.
///
/// A host may call `+[Bugsee launchWithToken:]` natively in
/// `application:didFinishLaunchingWithOptions:`, before any engine exists and so
/// before Flutter registers plugins. A wrapper registered from
/// `register(with:)` would be missing for that launch (workbook 2.1). `+load`
/// runs before `main`. `+ensureRegistered` registers only on its first call and is also called
/// from the Swift plugin class, which keeps this object file linked out of the
/// static archive.
@interface BGSFlutterWrapperRegistrar : NSObject
+ (void)ensureRegistered;

/// Replaces the placeholder with the full identity once the Dart runtime is up
/// (workbook 2.4.2). Never throws. Returns whether a wrapper was submitted.
+ (BOOL)replaceWithType:(nullable id)type
                version:(nullable id)version
                  build:(nullable id)build
                context:(nullable id)context;

/// For tests only: receives every wrapper in place of `+[Bugsee setWrapper:]`;
/// nil restores the SDK call.
+ (void)setRegistrationHandlerForTests:(nullable void (^)(id wrapper))handler;
@end

NS_ASSUME_NONNULL_END
