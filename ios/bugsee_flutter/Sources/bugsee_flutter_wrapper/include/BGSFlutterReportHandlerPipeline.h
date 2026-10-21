#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The SDK's report-handler phases.
typedef NS_ENUM(NSInteger, BGSFlutterReportPhase) {
  BGSFlutterReportPhaseBefore = 0,
  BGSFlutterReportPhaseAfter = 1,
};

/// How long Dart gets, per path. From the iOS SDK (`origin/nextgen`,
/// `BGSIssueReportingCoordinator.{h,m}`, `BGSContracts.h` `BGSReportHandler`):
///
/// - LIVE (a report raised by the running app): handlers are called on the MAIN thread, one
///   after another, and each completion is waited for, up to `reportHandlerCallbackTimeout`
///   (30 s; iOS has no option for it) per handler and `reportHandlerChainTimeout` (60 s) for
///   the chain. Ours is 25 s, inside the 30 s.
/// - RECOVERY (next launch): handlers are called on a GCD worker, NEVER main, the caller
///   waits at most `boundedReportHandlerCap` (3 s) for the handler to RETURN, and the
///   completion is not waited for; one that arrives later re-persists the report, until the
///   bundle is assembled. Ours is 2 s, inside the 3 s.
/// - TERMINATING (`isTerminating = YES`): no producer exists on iOS today; if one appears
///   the process dies when the handler returns. Never reaches Dart.
///
/// The SDK does not say which of the first two it is except by the thread (`BGSContracts.h`),
/// so that is the signal, used for the time budget and nothing else: never passed to Dart and
/// never read as "this is a recovered crash" (workbook 7.2.3).
FOUNDATION_EXPORT const int64_t BGSFlutterReportLiveDeadlineMs;
FOUNDATION_EXPORT const int64_t BGSFlutterReportRecoveryDeadlineMs;
/// The SDK's own limits the two above sit inside; repeated here so a test can compare them.
FOUNDATION_EXPORT const int64_t BGSFlutterReportSdkLiveHandlerTimeoutMs;
FOUNDATION_EXPORT const int64_t BGSFlutterReportSdkBoundedCapMs;

/// The deadline for a dispatch on the main thread (live) or off it (recovery).
FOUNDATION_EXPORT int64_t BGSFlutterReportDeadlineMs(BOOL onMainThread);

/// What reaches Dart for one delivery.
@interface BGSFlutterReportRequest : NSObject
/// Unique per delivery and opaque.
@property(nonatomic, copy, readonly) NSString *handle;
/// STABLE for the same report and phase (`before:<reportId>` / `after:<reportId>`), so Dart
/// can recognise a re-delivery. Unique (never shared) when the id could not be read.
@property(nonatomic, copy, readonly) NSString *deliveryId;
@property(nonatomic, readonly) BOOL after;
@property(nonatomic, copy, readonly) NSString *reportId;
@property(nonatomic, copy, readonly) NSString *type;
@property(nonatomic, readonly) int64_t deadlineMs;
@end

/// Sends a delivery to one engine's Dart isolate. Runs on the platform (main) thread.
/// `unreachable` must run when Dart cannot be reached (an error reply).
typedef void (^BGSFlutterReportSink)(BGSFlutterReportRequest *request,
                                     dispatch_block_t unreachable);
/// Arms a deadline; returns a token for the cancel block.
typedef id _Nullable (^BGSFlutterReportScheduler)(dispatch_block_t task, int64_t delayMs);
typedef void (^BGSFlutterReportCancel)(id token);
/// Runs a block on the platform (main) thread, never inline.
typedef void (^BGSFlutterReportPlatformPost)(dispatch_block_t task);
typedef void (^BGSFlutterReportLog)(NSString *line);

/// One change to a live report. Return NO with `*error` set to refuse the argument
/// (nothing may have changed).
typedef BOOL (^BGSFlutterReportEdit)(id report, NSError *_Nullable *_Nullable error);

typedef NS_ENUM(NSInteger, BGSFlutterReportEditResult) {
  BGSFlutterReportEditApplied = 0,
  /// The handle is not live (the completion already ran, or it is unknown): nothing changed.
  BGSFlutterReportEditNotLive,
  /// The argument cannot be taken; nothing changed. `error` says why.
  BGSFlutterReportEditRefused,
};

/// Routes the SDK's report-handler callbacks to Dart and back (workbook Part 7), through a
/// table of opaque handles.
///
/// THE INVARIANT: every dispatch ends in exactly ONE run of the SDK's completion, whichever
/// gets there first: Dart completing the handle, its deadline, the engine detaching, a failure
/// to reach Dart, or an error in here (7.1.2). Nothing in here throws into the SDK.
///
/// WHY NOTHING HERE EVER WAITS (the deadlock): on the LIVE path the SDK calls the handler on
/// the MAIN thread, and Dart's reply is delivered by the main thread. A handler that blocked
/// for the reply would deadlock on the very thread that must deliver it. So `dispatch...`
/// registers the handle, arms the deadline, posts the request to the main queue and RETURNS;
/// the SDK is already waiting for the completion on its own timer. The completion runs later,
/// on whichever thread finishes the handle.
///
/// WHEN DART IS NOT ASKED: `isTerminating` (the process dies when this returns and the Dart
/// runtime may be gone; nothing is even read from the report), no registered Dart handler for
/// the phase (no waiting), or no attached Dart: the completion runs at once.
///
/// A LATE EDIT: the proxy is live only until the completion runs (7.3.4). `-editHandle:` and
/// `-reportForHandle:` refuse from then on, and the Dart side raises an error for it.
@interface BGSFlutterReportHandlerPipeline : NSObject

+ (instancetype)shared;

/// Everything injected, for tests.
- (instancetype)initWithScheduler:(BGSFlutterReportScheduler)scheduler
                           cancel:(BGSFlutterReportCancel)cancel
                     platformPost:(BGSFlutterReportPlatformPost)platformPost
                              log:(BGSFlutterReportLog)log NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Attaches one engine's Dart end. It registers no phase until `-setPhasesForOwner:...`.
/// Returns the owner token the other calls take.
- (id)attachSink:(BGSFlutterReportSink)sink;
- (void)setPhasesForOwner:(id)owner before:(BOOL)before after:(BOOL)after;
/// The engine is gone: completes every handle emitted to it (nothing else knows them).
- (void)detachOwner:(id)owner;

/// The SDK's entry point (`id<BGSReportContract>` as `id`, so this header needs no SDK
/// import). `onMainThread` is `NSThread.isMainThread` at the call, read by the caller so a
/// test can choose. Returns promptly on every path, never blocks, never throws, and arranges for
/// `completion` to run exactly once.
- (void)dispatchPhase:(BGSFlutterReportPhase)phase
               report:(nullable id)report
        isTerminating:(BOOL)isTerminating
         onMainThread:(BOOL)onMainThread
           completion:(nullable dispatch_block_t)completion;

/// Dart completed the handle. Returns whether THIS call ran the SDK's completion.
- (BOOL)completeHandle:(NSString *)handle;
/// The live report behind `handle`, or nil once it is completed or unknown.
- (nullable id)reportForHandle:(nullable NSString *)handle;
- (BGSFlutterReportEditResult)editHandle:(nullable NSString *)handle
                                    edit:(BGSFlutterReportEdit)edit
                                   error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
