#import <Foundation/Foundation.h>

#import "BGSFlutterFacadeOps.h"

NS_ASSUME_NONNULL_BEGIN

/// The SDK entry points used for Dart errors; the real ones are `BGSFlutterRealExceptionSdk`. A seam
/// so a unit test can see what reaches the SDK (the Android twin is `ExceptionOps.Sdk`).
@protocol BGSFlutterExceptionSDK <NSObject>
/// Whether the SDK is Launching or Launched (`bugseeAvailableForUserDumps`, Bugsee.m:1630).
- (BOOL)isLaunchedOrLaunching;
/// `+logException:reason:domain:skipFrames:completion:`: an error report.
- (void)logHandledName:(NSString *)name
                reason:(NSString *)reason
                domain:(nullable NSString *)domain
            skipFrames:(NSInteger)skipFrames;
/// `+logUnhandledException:reason:completion:`: a crash report, filed by the next launch.
- (void)logUnhandledName:(NSString *)name reason:(NSString *)reason;
@end

/// The real SDK.
@interface BGSFlutterRealExceptionSdk : NSObject <BGSFlutterExceptionSDK>
@end

/// Dart errors (Phase 5a). Dart builds the JSON document (doc/exceptions.md); this hands it to the
/// SDK as the reason of an exception named `FlutterManagedException`, the name the backend routes on.
///
/// Before launch and after stop the SDK drops a handled exception itself (Bugsee.m:1544); the
/// unhandled path is NOT gated by the SDK (its crash manager outlives a stop and the fallback
/// writes a crash report), so this gates both the same way first: the answer (NO) says the SDK was
/// not handed it. Nothing is queued. On a simulator and Mac Catalyst the SDK files nothing at all.
@interface BGSFlutterExceptionOps : NSObject

/// The exception name the backend routes on; compared with Dart's by the drift guard.
@property(class, readonly) NSString *exceptionName;
/// The longest document accepted (UTF-16 units); compared with Dart's by the drift guard.
@property(class, readonly) NSInteger maxPayloadLength;
/// The longest domain accepted; compared with Dart's by the drift guard.
@property(class, readonly) NSInteger maxDomainLength;

/// `value` of the result: an `NSNumber` BOOL, whether the SDK was handed the exception.
+ (BGSFlutterFacadeResult *)logWithSdk:(id<BGSFlutterExceptionSDK>)sdk
                               payload:(nullable NSString *)payload
                               handled:(BOOL)handled
                                domain:(nullable NSString *)domain NS_SWIFT_NAME(log(sdk:payload:handled:domain:));

@end

NS_ASSUME_NONNULL_END
