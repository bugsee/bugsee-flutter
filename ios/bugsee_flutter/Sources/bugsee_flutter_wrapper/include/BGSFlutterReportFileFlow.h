#import <Foundation/Foundation.h>

#import "BGSFlutterCreatedReportOps.h"
#import "BGSFlutterCreatedReports.h"
#import "BGSFlutterReportFiles.h"
#import "BGSFlutterReportHandlerPipeline.h"

NS_ASSUME_NONNULL_BEGIN

/// The reply codes of `createReport` (PlatformException codes; Dart: `ReportWire`).
FOUNDATION_EXPORT NSString *const BGSFlutterCreateBusy;
FOUNDATION_EXPORT NSString *const BGSFlutterCreateTimeout;
FOUNDATION_EXPORT NSString *const BGSFlutterCreateRateLimited;
/// The SDK did not say, in time, whether it took the uploaded report; it may still send it.
FOUNDATION_EXPORT NSString *const BGSFlutterUploadTimeout;
/// A created report that is not (or no longer) live: uploaded, discarded, expired or released.
FOUNDATION_EXPORT NSString *const BGSFlutterFlowNotLive;
FOUNDATION_EXPORT const int64_t BGSFlutterUploadTimeoutMs;
/// How many created-report operations may wait at once (the worker's queue holds 64; the rest is kept for the upload).
FOUNDATION_EXPORT const NSInteger BGSFlutterCreatedOpsLimit;
/// The facade's codes, for an argument or an SDK fault (`BGSFlutterFacadeOps`).
FOUNDATION_EXPORT NSString *const BGSFlutterFlowInvalidArgument;
FOUNDATION_EXPORT NSString *const BGSFlutterFlowSdkError;
/// How long the SDK may take to answer `createReport`: it runs no handler first on iOS, but the
/// auto-captured screenshot is read asynchronously.
FOUNDATION_EXPORT const int64_t BGSFlutterCreateTimeoutMs;

/// What a flow operation answers: a value (nil for "done") or an error code with a message. Delivered on
/// the platform (main) thread.
typedef void (^BGSFlutterFlowReply)(id _Nullable value, NSString *_Nullable errorCode, NSString *_Nullable errorMessage);

/// The SDK's entry points for a created report: a seam for XCTest.
@protocol BGSFlutterCreatedReportSdk <NSObject>
/// The SDK's completion may run on any thread; it runs on every path, with nil when none was made.
- (void)createReportWithCompletion:(void (^)(id _Nullable report))completion;
/// `completion` runs once the report has been handed off for processing (main thread).
- (void)uploadReport:(id)report completion:(void (^)(void))completion;
@end

@interface BGSFlutterRealCreatedReportSdk : NSObject <BGSFlutterCreatedReportSdk>
@end

/// A queue the flow runs file work on, in order. Returns NO when it has no room.
typedef BOOL (^BGSFlutterFlowWorker)(dispatch_block_t task);
/// Posts to the platform (main) thread, never inline when called from elsewhere.
typedef void (^BGSFlutterFlowMain)(dispatch_block_t task);

/// The file operations on a report and the `createReport` flow (Phase 6), with every collaborator
/// injected so the rules are XCTested without Flutter.
///
/// THREADS. Pigeon calls a host method on the main queue. A handler report's file operation (a copy, a
/// move, an image decode) costs I/O proportional to the file, which the SDK says not to do on the UI
/// thread, so it is queued on the worker (one serial queue, in call order) and the reply is posted back
/// to main. The report is CLAIMED first (`-acquireHandle:`): a handle that is live when the call is made
/// stays valid for the operation, and the SDK's completion waits for the claim to end instead of racing
/// it. A created report (`BugseeExtendedReport`) is unsynchronised and the SDK hands it out and takes it
/// back on main, so what touches the object runs on main; the file read and the image decode run before that,
/// on a second serial worker (so a slow handler copy never holds a created report up, and no read or decode
/// freezes the UI), in the order Dart called.
@interface BGSFlutterReportFileFlow : NSObject

+ (instancetype)shared;
- (instancetype)initWithPipeline:(BGSFlutterReportHandlerPipeline *)pipeline
                         created:(BGSFlutterCreatedReports *)created
                          worker:(BGSFlutterFlowWorker)worker
                   createdWorker:(BGSFlutterFlowWorker)createdWorker
                            main:(BGSFlutterFlowMain)main
                             sdk:(id<BGSFlutterCreatedReportSdk>)sdk
                       scheduler:(BGSFlutterCreatedScheduler)scheduler
                          cancel:(BGSFlutterCreatedCancel)cancel
                createTimeoutMs:(int64_t)createTimeoutMs
                  uploadTimeoutMs:(int64_t)uploadTimeoutMs NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// ---- A handler's report. The reply value is nil (done) or the failure code string. ----
- (void)handlerAddFile:(NSString *)handle
                  path:(NSString *)path
                  name:(NSString *)name
              mimeType:(nullable NSString *)mimeType
                  move:(BOOL)move
                 reply:(BGSFlutterFlowReply)reply;
- (void)handlerAddData:(NSString *)handle
                  data:(NSData *)data
                  name:(NSString *)name
              mimeType:(nullable NSString *)mimeType
                 reply:(BGSFlutterFlowReply)reply;
- (void)handlerClearAttachments:(NSString *)handle reply:(BGSFlutterFlowReply)reply;
- (void)handlerSetScreenshot:(NSString *)handle
                        path:(NSString *)path
                   displayId:(int64_t)displayId
                   annotated:(BOOL)annotated
                       reply:(BGSFlutterFlowReply)reply;
- (void)handlerRemoveScreenshot:(NSString *)handle displayId:(int64_t)displayId reply:(BGSFlutterFlowReply)reply;

// ---- createReport ----
/// Replies with the handle (nil when the SDK made none), or an error code (`create-busy` and
/// `create-rate-limited` on the calling thread, `create-timeout`, `sdk-error`). `owner` is the engine
/// asking; only `-resetOwner:` for the same one releases the report.
- (void)createForOwner:(id)owner ttlMs:(int64_t)ttlMs reply:(BGSFlutterFlowReply)reply;
- (nullable BGSFlutterCreatedReportSnapshot *)readCreated:(NSString *)handle;
/// NO when the handle is not live; the message is set (and nothing applied) for a bad field.
- (BOOL)applyToCreated:(NSString *)handle patch:(BGSFlutterCreatedReportPatch *)patch message:(NSString *_Nullable *_Nullable)message;
- (void)createdAddFile:(NSString *)handle
                  path:(NSString *)path
                  name:(NSString *)name
              mimeType:(nullable NSString *)mimeType
                 reply:(BGSFlutterFlowReply)reply;
- (void)createdAddData:(NSString *)handle
                  data:(NSData *)data
                  name:(NSString *)name
              mimeType:(nullable NSString *)mimeType
                 reply:(BGSFlutterFlowReply)reply;
- (void)createdClearAttachments:(NSString *)handle reply:(BGSFlutterFlowReply)reply;
- (void)createdSetScreenshot:(NSString *)handle path:(NSString *)path annotated:(BOOL)annotated reply:(BGSFlutterFlowReply)reply;
/// Replies with an NSNumber bool: whether the SDK handed the report off (NO: it declined). A handle that is
/// not live is the error `not-live`; an SDK that does not answer in time is `upload-timeout`.
- (void)uploadCreated:(NSString *)handle reply:(BGSFlutterFlowReply)reply;
- (void)discardCreated:(NSString *)handle;
/// The engine's Dart isolate is new (a hot restart) or gone: only ITS created report is released now.
- (void)resetOwner:(id)owner;

@end

NS_ASSUME_NONNULL_END
