#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The two callbacks of the SDK's listener, in this package's own protocol so no header here has
/// to import the add-on's Swift module (the real adapter in the .m does).
@protocol BGSFlutterFeedbackListener <NSObject>
- (void)onNewMessagesReceived:(NSArray<NSString *> *)messages;
- (void)onNewMessageSent:(NSString *)message;
@end

/// What the plugin needs from the add-on's `BugseeFeedback`: a seam so a unit test can see what
/// reaches it (the Android twin is `FeedbackSdk`). Called on the main thread.
@protocol BGSFlutterFeedbackSDK <NSObject>
/// Whether `Bugsee.ext(BugseeFeedback.self)` has an instance.
- (BOOL)isRegistered;
/// Registers the add-on if the SDK has none; YES when it had to. Never throws.
- (BOOL)registerIfMissing;
- (void)showFeedbackUI;
- (void)setGreeting:(nullable NSString *)greeting;
/// The SDK holds its listener WEAKLY; the real implementation keeps the adapter alive itself.
- (void)setListener:(nullable id<BGSFlutterFeedbackListener>)listener;
@end

/// The real add-on.
@interface BGSFlutterRealFeedback : NSObject <BGSFlutterFeedbackSDK>
@end

/// Registers the add-on with the SDK at image load and on demand. The add-on's own Objective-C
/// shim (`BugseeFeedbackAutoRegister`, `+load`) does the same, but a static link can drop a
/// translation unit nothing references; this class is referenced by the plugin's Swift code, so
/// its `+load` is linked, and it needs the add-on whatever the shim did. Idempotent.
@interface BGSFlutterFeedbackRegistrar : NSObject
+ (void)ensureRegistered;
@end

/// What an operation answers: a failure with the bridge's code, or nothing. An SDK exception (an
/// `NSException` would crash Swift) is a failure, never an escape.
@interface BGSFlutterFeedbackResult : NSObject
@property(nonatomic, copy, nullable) NSString *errorCode;
@property(nonatomic, copy, nullable) NSString *errorMessage;
@property(nonatomic, readonly) BOOL failed;
@end

/// Where events go; called on the main thread.
typedef void (^BGSFlutterFeedbackReceivedBlock)(NSArray<NSString *> *messages);
typedef void (^BGSFlutterFeedbackSentBlock)(NSString *message);

/// What the Dart facade asks of the feedback module, with the SDK behind `BGSFlutterFeedbackSDK`.
/// One per Flutter engine.
///
/// The SDK has ONE listener slot per process. An instance installs its own listener and clears the
/// slot only while the slot still holds it, so a newer engine's listener is never silenced by an
/// older one's detach (the most recently enabled engine wins).
@interface BGSFlutterFeedbackOps : NSObject
- (instancetype)initWithSdk:(id<BGSFlutterFeedbackSDK>)sdk
                   received:(BGSFlutterFeedbackReceivedBlock)received
                       sent:(BGSFlutterFeedbackSentBlock)sent NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Forgets a listener a previous isolate of this engine installed; whether the module is there.
- (BOOL)attach;
- (BGSFlutterFeedbackResult *)show;
- (BGSFlutterFeedbackResult *)setGreeting:(nullable NSString *)greeting;
- (BGSFlutterFeedbackResult *)setListenerEnabled:(BOOL)enabled;
/// The engine is gone: stop emitting and release the SDK slot if it is still ours.
- (void)detach;

/// The wire codes (a FlutterError's code), repeated in lib/src/errors.dart (FeedbackWire).
+ (NSString *)notRegisteredCode;
+ (NSString *)sdkErrorCode;

/// For tests: forget the process-wide slot.
+ (void)resetSlotForTesting;
@end

NS_ASSUME_NONNULL_END
