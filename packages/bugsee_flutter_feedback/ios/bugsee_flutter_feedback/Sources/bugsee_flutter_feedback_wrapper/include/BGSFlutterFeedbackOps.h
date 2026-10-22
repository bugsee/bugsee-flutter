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

/// Where the add-on's listener is installed (the seam for the adapter slot below).
@protocol BGSFlutterFeedbackListenerSlot <NSObject>
/// `nil` means "nobody listens"; see `BGSFlutterFeedbackAdapterSlot` for what that does.
- (void)installListener:(nullable id<BGSFlutterFeedbackListener>)listener;
@end

/// The one object the add-on's listener slot ever holds, and the one place that talks to it.
///
/// The add-on (`BugseeFeedback.setListener`) hands every change to its own unstructured `Task`,
/// with no ordering between two changes. A `setListener(nil)` followed at once by a
/// `setListener(adapter)` (a hot restart, or a listen/cancel/listen) can therefore finish in the
/// other order and leave the adapter installed with its handlers cleared: events silently lost. So
/// the add-on is told exactly ONCE, with this adapter, and never with nil; "nobody listens" and
/// "somebody listens" are changes of the adapter's own target, which is ordered. The add-on holds
/// its listener weakly: this slot keeps the adapter alive.
@interface BGSFlutterFeedbackAdapterSlot : NSObject <BGSFlutterFeedbackListenerSlot>
/// `install` receives the adapter (an `id<BugseeFeedbackListener>`) the first time a listener is
/// given, and only then.
- (instancetype)initWithInstaller:(void (^)(id adapter))install NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// The adapter, for tests.
@property(nonatomic, readonly) id adapter;
@end

/// The real add-on.
@interface BGSFlutterRealFeedback : NSObject <BGSFlutterFeedbackSDK>
/// For tests: replaces the slot all instances share; `nil` restores the real one.
+ (void)useListenerSlotForTesting:(nullable id<BGSFlutterFeedbackListenerSlot>)slot;
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
/// The SDK has ONE listener slot per process. Every engine that listens gets its own relay; a single
/// process-wide fan-out listener is handed to the SDK while at least one relay exists and passes
/// every event to all of them, so one engine listening, or detaching, never silences another.
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

/// For tests: forget every relay (the process-wide state).
+ (void)resetSlotForTesting;
@end

NS_ASSUME_NONNULL_END
