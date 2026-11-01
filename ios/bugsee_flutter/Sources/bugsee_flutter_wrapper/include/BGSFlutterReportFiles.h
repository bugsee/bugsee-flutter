#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The failure codes of a file operation's reply (Dart: `ReportWire`). Repeated in Java
// (`ReportOps`); `test/report_attachments_drift_test.dart` compares the three copies.
FOUNDATION_EXPORT NSString *const BGSFlutterFileNotLive;
FOUNDATION_EXPORT NSString *const BGSFlutterFileNotFound;
FOUNDATION_EXPORT NSString *const BGSFlutterFileNotAFile;
FOUNDATION_EXPORT NSString *const BGSFlutterFileUnreadable;
FOUNDATION_EXPORT NSString *const BGSFlutterFileTooLarge;
FOUNDATION_EXPORT NSString *const BGSFlutterFileLimit;
FOUNDATION_EXPORT NSString *const BGSFlutterFileRejected;
FOUNDATION_EXPORT NSString *const BGSFlutterFileBusy;
FOUNDATION_EXPORT NSString *const BGSFlutterFileUnsupported;
FOUNDATION_EXPORT NSString *const BGSFlutterFileImageUndecodable;
FOUNDATION_EXPORT NSString *const BGSFlutterFileImageTooLarge;

/// The numbers repeated from Dart (`attachments.dart`) and Java (`ReportOps`).
FOUNDATION_EXPORT const NSUInteger BGSFlutterMaxAttachmentBytes;
FOUNDATION_EXPORT const unsigned long long BGSFlutterMaxAttachmentFileBytes;
FOUNDATION_EXPORT const NSUInteger BGSFlutterMaxAttachmentNameLength;
FOUNDATION_EXPORT const NSUInteger BGSFlutterMaxMimeTypeLength;
FOUNDATION_EXPORT const NSUInteger BGSFlutterMaxPathLength;
FOUNDATION_EXPORT const unsigned long long BGSFlutterMaxScreenshotPixels;
/// `kBGSMaxReportAttachments` in the SDK (`BGSReport.m`): the 1001st is refused.
FOUNDATION_EXPORT const NSUInteger BGSFlutterMaxReportAttachments;

/// What a file operation did: finished (both nil), was refused with a reply code (`code`), or was
/// given an argument it cannot take (`argumentError`: nothing was done).
@interface BGSFlutterFileOutcome : NSObject
@property(nonatomic, copy, readonly, nullable) NSString *code;
@property(nonatomic, copy, readonly, nullable) NSString *argumentError;
+ (instancetype)done;
+ (instancetype)refusedWithCode:(NSString *)code;
+ (instancetype)badArgument:(NSString *)message;
@end

/// Argument rules, shared by the handler report and the created report. Dart validates first;
/// these are the second line, and are the same rules.
@interface BGSFlutterReportFiles : NSObject

/// Nil when the argument is fine, else the message. Never contains the value.
+ (nullable NSString *)problemWithPath:(nullable NSString *)path;
+ (nullable NSString *)problemWithName:(nullable NSString *)name;
+ (nullable NSString *)problemWithMimeType:(nullable NSString *)mimeType;
+ (nullable NSString *)problemWithDisplayId:(int64_t)displayId;

/// Whether `s` is blank: only code points of one explicit set shared with Dart and Java (not each language's own trim).
+ (BOOL)isBlank:(NSString *)s;

/// Says why the file at an (already validated) path cannot be attached, in the order a developer
/// would fix it: nothing there, not a regular file, not readable. A symbolic link is followed (the
/// SDK copies its content). Nil: it can.
+ (nullable NSString *)codeForUnreadableFileAtPath:(NSString *)path;

/// Decodes the image at `path` natively, refusing one over `BGSFlutterMaxScreenshotPixels` before
/// any pixel is allocated. On refusal returns nil and sets `*code`.
+ (nullable UIImage *)imageAtPath:(NSString *)path code:(NSString *_Nullable *_Nullable)code;

// ---- A handler's report (`id<BGSReportContract>`, as `id` so this header needs no SDK import) ----

/// The SDK copies (`move` NO) or moves the file into storage the report owns before this returns,
/// and answers nil for everything it declines (the report is no longer live, the cap, a failed copy);
/// a refusal never consumes the source. The reasons the SDK does not name are checked first.
+ (BGSFlutterFileOutcome *)addFileAtPath:(nullable NSString *)path
                                    name:(nullable NSString *)name
                                mimeType:(nullable NSString *)mimeType
                                    move:(BOOL)move
                                onReport:(id)report;
+ (BGSFlutterFileOutcome *)addData:(nullable NSData *)data
                              name:(nullable NSString *)name
                          mimeType:(nullable NSString *)mimeType
                          onReport:(id)report;
+ (BGSFlutterFileOutcome *)clearAttachmentsOnReport:(id)report;
+ (BGSFlutterFileOutcome *)setScreenshotAtPath:(nullable NSString *)path
                                     displayId:(int64_t)displayId
                                     annotated:(BOOL)annotated
                                      onReport:(id)report;
+ (BGSFlutterFileOutcome *)removeScreenshotWithDisplayId:(int64_t)displayId onReport:(id)report;

@end

NS_ASSUME_NONNULL_END
