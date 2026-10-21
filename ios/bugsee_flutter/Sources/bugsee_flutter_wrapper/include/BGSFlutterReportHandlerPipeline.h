#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The SDK's report-handler phases.
typedef NS_ENUM(NSInteger, BGSFlutterReportPhase) {
  BGSFlutterReportPhaseBefore = 0,
  BGSFlutterReportPhaseAfter = 1,
};

/// How long Dart gets, per path. Ours is the SDK's budget LESS A MARGIN of a third of it (at most
/// 10 s), never more (workbook 7.3.5). From the iOS SDK (`origin/nextgen`,
/// `BGSIssueReportingCoordinator.{h,m}`, `BGSContracts.h` `BGSReportHandler`):
///
/// - LIVE (a report raised by the running app): handlers are called on the MAIN thread, one
///   after another, and each completion is waited for, up to `reportHandlerCallbackTimeout`
///   (30 s; iOS has no option for it) per handler and `reportHandlerChainTimeout` (60 s) for
///   the chain. The SDK starts that timer when it QUEUES the handler (`timedCallbackWithContinuation`,
///   before the hop to main); ours starts when the handler is entered, and the wait in between (main busy)
///   cannot be observed, so the margin absorbs it: a handler that waited for main longer than the margin
///   can still overrun the SDK's deadline, and an edit then is accepted here although the SDK has moved
///   on. Ours is 20 s of the 30 s.
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
/// The margin kept under an SDK budget: a third of it, at most 10 s.
FOUNDATION_EXPORT int64_t BGSFlutterReportMarginMs(int64_t sdkMs);
/// What is left of `budgetMs` once `elapsedMs` has passed; never negative. Zero means "already over":
/// complete the SDK's callback instead of asking Dart.
FOUNDATION_EXPORT int64_t BGSFlutterReportRemainingMs(int64_t budgetMs, int64_t elapsedMs);

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
/// Milliseconds on a monotonic clock; injectable so a test controls time.
typedef int64_t (^BGSFlutterReportClock)(void);

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

/// A claim on a live report for an operation that must not run under the handle's lock (a file copy
/// takes as long as the disk does). While it is held the report stays valid for the operation even if
/// the handle completes, and the SDK's completion waits for `-end`: nothing here blocks a thread for it.
@interface BGSFlutterReportLease : NSObject
@property(nonatomic, strong, readonly) id report;
/// Idempotent. Runs the SDK's completion if the handle completed meanwhile and this was the last claim.
- (void)end;
@end

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
/// THE WINDOW: the SDK's budget less a margin, measured from the handler's entry. What is observable
/// of the SDK's wait, the time between entry and the platform thread taking the request, is deducted
/// before Dart is asked (`BGSFlutterReportRequest.deadlineMs` is what is LEFT), and a window already
/// over is completed instead of offered. What is not observable (the SDK's own queueing before entry)
/// is the margin's job.
///
/// CHECK AND APPLY ARE ONE STEP: an edit holds the handle's lock across "is it live" and the change,
/// and finishing flips `done` under the same lock, so an edit reported as applied landed BEFORE the
/// SDK's completion ran. The SDK's completion, Dart and the scheduler are never called with a lock held.
///
/// A LATE EDIT: the proxy is live only until the completion runs (7.3.4). `-editHandle:` and
/// `-reportForHandle:` refuse from then on, and the Dart side raises an error for it.
@interface BGSFlutterReportHandlerPipeline : NSObject

+ (instancetype)shared;

/// Everything injected, for tests.
- (instancetype)initWithScheduler:(BGSFlutterReportScheduler)scheduler
                           cancel:(BGSFlutterReportCancel)cancel
                     platformPost:(BGSFlutterReportPlatformPost)platformPost
                              log:(BGSFlutterReportLog)log;
- (instancetype)initWithScheduler:(BGSFlutterReportScheduler)scheduler
                           cancel:(BGSFlutterReportCancel)cancel
                     platformPost:(BGSFlutterReportPlatformPost)platformPost
                              log:(BGSFlutterReportLog)log
                            clock:(BGSFlutterReportClock)clock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Attaches one engine's Dart end. It registers no phase until `-setPhasesForOwner:...`.
/// Returns the owner token the other calls take.
- (id)attachSink:(BGSFlutterReportSink)sink;
- (void)setPhasesForOwner:(id)owner before:(BOOL)before after:(BOOL)after;
/// A new Dart isolate is up on this engine (a hot restart): completes the deliveries handed to the
/// previous one (nothing in the new one knows them) and forgets which phases had a handler.
- (void)resetOwner:(id)owner;
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
/// Claims the live report behind `handle` for a long operation, or nil (nothing claimed) when it is
/// not live (7.3.4).
- (nullable BGSFlutterReportLease *)acquireHandle:(nullable NSString *)handle;
- (BGSFlutterReportEditResult)editHandle:(nullable NSString *)handle
                                    edit:(BGSFlutterReportEdit)edit
                                   error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
