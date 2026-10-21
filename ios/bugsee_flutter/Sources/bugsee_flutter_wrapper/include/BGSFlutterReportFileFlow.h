#import <Foundation/Foundation.h>

#import "BGSFlutterCreatedReportOps.h"
#import "BGSFlutterCreatedReports.h"
#import "BGSFlutterReportFiles.h"
#import "BGSFlutterReportHandlerPipeline.h"

NS_ASSUME_NONNULL_BEGIN

/// The reply codes of `createReport` (PlatformException codes; Dart: `ReportWire`).
FOUNDATION_EXPORT NSString *const BGSFlutterCreateBusy;
FOUNDATION_EXPORT NSString *const BGSFlutterCreateTimeout;
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
/// back on main, so its operations run on main (they are bounded: 3 attachments of 3 MiB).
@interface BGSFlutterReportFileFlow : NSObject

+ (instancetype)shared;
- (instancetype)initWithPipeline:(BGSFlutterReportHandlerPipeline *)pipeline
                         created:(BGSFlutterCreatedReports *)created
                          worker:(BGSFlutterFlowWorker)worker
                            main:(BGSFlutterFlowMain)main
                             sdk:(id<BGSFlutterCreatedReportSdk>)sdk
                createTimeoutMs:(int64_t)createTimeoutMs NS_DESIGNATED_INITIALIZER;
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
/// Replies with the handle (nil when the SDK made none), or an error code (`create-busy` on the calling
/// thread, `create-timeout`, `sdk-error`).
- (void)createWithTtlMs:(int64_t)ttlMs reply:(BGSFlutterFlowReply)reply;
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
/// Replies with an NSNumber bool: whether the SDK handed the report off. NO for a handle that is not live.
- (void)uploadCreated:(NSString *)handle reply:(BGSFlutterFlowReply)reply;
- (void)discardCreated:(NSString *)handle;
/// A new Dart isolate: the old one's created report is released now, not at its deadline.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
