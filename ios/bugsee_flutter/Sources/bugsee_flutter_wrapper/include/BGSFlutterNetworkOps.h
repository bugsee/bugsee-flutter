#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The SDK entry points network injection uses (Phase 5b); the real ones are
/// `BGSFlutterRealNetworkSdk`. A seam so a unit test can see what reaches the SDK (the Android twin
/// is `NetworkOps.Sdk`). The event is a `BugseeNetworkEvent`, typed `id` so this header needs no SDK
/// import. Every method is called on the platform (main) thread.
@protocol BGSFlutterNetworkSDK <NSObject>
/// The SDK is `Launched` and `capture.network` is on.
- (BOOL)acceptsNetworkEvents;
/// Epoch milliseconds on the clock the SDK validates against (`BugseeGetCurrentTimeStampMs`).
- (NSTimeInterval)currentTimestampMs;
/// `channel.addNetworkEvent:requiresFiltering:YES`; NO when the wrapper holds no channel.
- (BOOL)submitNetworkEvent:(id)event;
@end

/// The real SDK.
@interface BGSFlutterRealNetworkSdk : NSObject <BGSFlutterNetworkSDK>
@end

/// The SDK's `BGSWrapperChannel` for the CURRENT wrapper registration, process-wide. The SDK
/// hands a new channel to `-[BGSBugseeWrapper onWrapperChannelAvailable:]` for each registration
/// and makes the previous one inert; the wrapper object is replaced when Dart refines the identity,
/// so the channel cannot live in it. The newest delivery wins.
@interface BGSFlutterNetworkChannel : NSObject
+ (instancetype)shared;
@property(atomic, strong, nullable) id channel;
@end

/// Network events the Dart capture hands to the SDK (Phase 5b). Dart's `dart:io` stack is invisible
/// to the SDK's own interception, so the wrapper captures it in Dart and injects the events.
///
/// What the SDK would drop is not sent (iOS 7.0.0-beta7 source): `+[Bugsee addNetworkEvent:...]`
/// takes events only while `Launched` (not `Launching`: the channel's own header says so), and
/// `BGSCaptureDataProviderNetwork` only runs with `capture.network` on. Filtering is ALWAYS
/// required (`requiresFiltering:YES`): the SDK's default sanitizer and the app's native filter see
/// injected events as intercepted ones; `NO` skips both. The body limits (`body-size-limit`,
/// `body-without-type`) are enforced by the SDK on whatever arrives; Dart withholds a body the SDK
/// would drop, so this only defends against a message that did not come from this Dart.
///
/// The iOS 7.0.0-beta7 exchange factory answers nil for `createNetworkEvent` ("not wired"), so the
/// event is a `BugseeNetworkEvent` built directly. Network events carry no source attribution at
/// this version (only `log` does): `mechanism` (`dart:io`) says where an event came from.
@interface BGSFlutterNetworkOps : NSObject

/// The wire stage names Dart sends (the SDK's own, except iOS spells `abort` `cancel`).
@property(class, readonly) NSArray<NSString *> *stageNames;
/// Compared with Dart's `NetworkWire.maxAgeMs` by the drift guard.
@property(class, readonly) int64_t maxAgeMs;

/// The SDK's `bugseeNetworkEventType` for a wire stage, or nil for one iOS has no stage for
/// (`redirect`: iOS carries a redirect as `redirectedFromURL` on the final event) or does not know.
+ (nullable NSString *)sdkStageForWire:(nullable NSString *)wire;

/// Hands each event (a dictionary with the keys of Dart's `NetworkEventMessage`) to the SDK, in
/// order, and returns how many it took. Never throws: an SDK or filter exception for one event is
/// caught (the app's filter runs on the calling thread; an escaping `NSException` would crash
/// Swift) and that event is dropped, fail closed.
+ (NSInteger)addEventsWithSdk:(id<BGSFlutterNetworkSDK>)sdk
                       events:(nullable NSArray<NSDictionary<NSString *, id> *> *)events
    NS_SWIFT_NAME(addEvents(sdk:events:));

/// One event (the gate is `addEventsWithSdk`'s). YES when handed to the SDK.
+ (BOOL)addEventWithSdk:(id<BGSFlutterNetworkSDK>)sdk
                  event:(nullable NSDictionary<NSString *, id> *)event
    NS_SWIFT_NAME(addEvent(sdk:event:));

@end

NS_ASSUME_NONNULL_END
