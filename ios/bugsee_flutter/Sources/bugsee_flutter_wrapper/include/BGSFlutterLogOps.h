#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The SDK entry points log injection uses (Phase 5d); the real ones are `BGSFlutterRealLogSdk`. A
/// seam so a unit test can see what reaches the SDK (the Android twin is `LogOps.Sdk`). Every method
/// is called on the plugin's serial background queue (the Pigeon method has a task queue: the app's
/// log filter runs on the calling thread).
@protocol BGSFlutterLogSDK <NSObject>
/// The SDK is `Launching` or `Launched` and `capture.logs` is on.
- (BOOL)acceptsLogs;
/// `channel.logWithTag:message:level:source:` with the wrapper's source (`Custom`); NO when the
/// wrapper holds no channel.
- (BOOL)submitLogWithTag:(nullable NSString *)tag message:(NSString *)message level:(NSInteger)level;
@end

/// The real SDK. The channel is the one `BGSFlutterNetworkChannel` holds (the SDK hands the wrapper
/// ONE channel per registration; network events and logs share it).
@interface BGSFlutterRealLogSdk : NSObject <BGSFlutterLogSDK>
@end

/// Log lines the Dart capture hands to the SDK (Phase 5d: `print`, `debugPrint`, `Bugsee.forwardLog`).
///
/// What the SDK would drop is not sent (iOS 7.0.0-beta7 source, `BGSWrapperChannelImpl.m`): the
/// channel takes lines while `Launching` or `Launched` (`bugseeAvailableForUserDumps`) and drops them
/// with `capture.logs` off ("forwarded host output is automatic capture"). The source is ALWAYS
/// `BGSLogEventSourceCustom` ("the host runtime's own logs"): the channel accepts five wrapper
/// sources and records every other as `Custom`, so claiming only `Custom` never depends on the
/// coercion and never triggers its once-per-process notice; it is never `Bugsee` (the app's own
/// `+[Bugsee log:]`). The channel always runs the app's log filter (`requiresFiltering:YES` inside).
/// `capture.logs.level` is applied by the SDK on these lines too; Dart applies it as well (Android
/// does not apply it to channel lines). `tag` is accepted by the channel and dropped: iOS log events
/// have no tag. Neither SDK takes a timestamp on the channel: a line is stamped when it arrives.
@interface BGSFlutterLogOps : NSObject

/// The SDK's `BugseeLogLevel` range (1 error .. 5 verbose); compared with Dart's `LogWire` by the
/// drift guard.
@property(class, readonly) NSInteger minLevel;
@property(class, readonly) NSInteger maxLevel;
/// The source claimed, as the SDK's `BGSLogEventSource` integer (`Custom`, 98).
@property(class, readonly) NSInteger wrapperSource;

/// Hands each line (a dictionary with the keys of Dart's `LogLineMessage`) to the SDK, in order, and
/// returns how many it took. Never throws: an SDK or filter exception for one line is caught (the
/// app's filter runs on the calling thread; an escaping `NSException` would crash Swift) and that
/// line is dropped, fail closed.
+ (NSInteger)addLinesWithSdk:(id<BGSFlutterLogSDK>)sdk
                       lines:(nullable NSArray<NSDictionary<NSString *, id> *> *)lines
    NS_SWIFT_NAME(addLines(sdk:lines:));

/// One line (the gate is `addLinesWithSdk`'s). YES when handed to the SDK.
+ (BOOL)addLineWithSdk:(id<BGSFlutterLogSDK>)sdk
                  line:(nullable NSDictionary<NSString *, id> *)line
    NS_SWIFT_NAME(addLine(sdk:line:));

@end

NS_ASSUME_NONNULL_END
