#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The Flutter wrapper registered with the Bugsee SDK, and the one place its iOS
/// identity lives. Declared without conforming to `BugseeWrapper` here so the
/// header needs no SDK import; the conformance is declared in the .m.
///
/// Identity is real (workbook Part 3). Everything else is a deliberately inert
/// stub until Phase 3 gives it behaviour. None of it throws.
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

@end

/// Registers the wrapper at image load, independent of the Flutter engine.
///
/// A host may call `+[Bugsee launchWithToken:]` natively in
/// `application:didFinishLaunchingWithOptions:`, before any engine exists and so
/// before Flutter registers plugins. A wrapper registered from
/// `register(with:)` would be missing for that launch (workbook 2.1). `+load`
/// runs before `main`. `+ensureRegistered` is idempotent and is also called
/// from the Swift plugin class, which keeps this object file linked out of the
/// static archive.
@interface BGSFlutterWrapperRegistrar : NSObject
+ (void)ensureRegistered;
@end

NS_ASSUME_NONNULL_END
