#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The SDK entry points launch, stop and status use; the real ones are `BGSFlutterRealBugsee`. A
/// seam so a unit test can see what reaches the SDK (the Android twin is `LaunchOps.Sdk`).
@protocol BGSFlutterBugseeSDK <NSObject>
/// The status by NAME: `stopped`, `launching`, `launched`, `stopping` (never the enum's number).
- (NSString *)statusName;
/// `started` gets whether the SDK reports it launched (YES also when the launch was only
/// deferred until the app is active, or when it was already running).
- (void)launchWithToken:(NSString *)token
                options:(NSDictionary<NSString *, id> *)options
                started:(void (^)(BOOL success))started;
- (void)stop:(void (^)(void))done;
- (NSDictionary<NSString *, id> *)launchOptionsHostOnly:(BOOL)hostOnly;
@end

/// The real SDK.
@interface BGSFlutterRealBugsee : NSObject <BGSFlutterBugseeSDK>
@end

/// Launch, stop and status decisions (workbook Part 8, 4.6), with the SDK behind the seam above.
///
/// iOS has no auto-init, but an app may launch the SDK natively before Dart runs, and a launch
/// made while the app is in the background is deferred by the SDK (it answers `started:` YES at
/// once with nothing launched). A launch of an SDK that is already Launching or Launched is
/// answered `started:` YES and its options are dropped, indistinguishable from a real launch; so
/// the status is read FIRST, and again when the SDK says YES.
@interface BGSFlutterLaunchOps : NSObject

/// The strings of `LaunchOutcomeMessage`; `test/launch_drift_test.dart` compares them with Dart.
@property(class, readonly) NSString *launched;
@property(class, readonly) NSString *alreadyRunning;
@property(class, readonly) NSString *deferred;
@property(class, readonly) NSString *refused;
@property(class, readonly) NSString *invalidToken;
@property(class, readonly) NSString *stopping;
@property(class, readonly) NSString *failed;
@property(class, readonly) NSString *errorCode;

/// The flat map from Dart as the SDK's dictionary launch options. Android and iOS share one option
/// namespace, so nothing is renamed, and the SDK takes enum options as their
/// internal number, as Dart sends them. Only string keys with a string or number value are kept.
+ (NSDictionary<NSString *, id> *)sdkOptionsFromFlat:(nullable NSDictionary *)flat;

/// Exactly one of `outcome` or `error` is set. An exception the SDK throws is the error.
+ (void)launchWithSdk:(id<BGSFlutterBugseeSDK>)sdk
                token:(nullable NSString *)token
              options:(nullable NSDictionary *)flat
           completion:(void (^)(NSString *_Nullable outcome, NSString *_Nullable reason, NSError *_Nullable error))completion;

/// Marks a stop as requested. Call it SYNCHRONOUSLY when the request arrives, before dispatching
/// `stopWithSdk:done:` to the main queue: the SDK itself only moves to Stopping a main-queue hop
/// later (`+[Bugsee stop:]` dispatches to main before setting the state), so a launch that arrives
/// in between would still read `launched`, answer already-running and then be stopped. While a stop
/// is marked, a launch is refused as `stopping` (Android sets STOPPING synchronously, so it has no
/// such window). Cleared when `stopWithSdk:done:` completes.
+ (void)beginStop;

/// `done(error)` when the SDK has stopped (at once when it already is), or with the SDK's exception.
+ (void)stopWithSdk:(id<BGSFlutterBugseeSDK>)sdk done:(void (^)(NSError *_Nullable error))done;

/// The options the SDK reports as values the channel carries, the same on both platforms: nothing
/// null, floats as doubles, only strings and numbers.
+ (NSDictionary<NSString *, id> *)reportedOptionsFromSdk:(nullable NSDictionary *)sdk;

+ (NSError *)errorFromException:(NSException *)exception;

@end

NS_ASSUME_NONNULL_END
