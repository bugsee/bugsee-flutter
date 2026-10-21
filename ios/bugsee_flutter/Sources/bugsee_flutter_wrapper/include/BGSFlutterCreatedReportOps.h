#import <Foundation/Foundation.h>

#import "BGSFlutterReportFiles.h"

NS_ASSUME_NONNULL_BEGIN

/// The legacy rules of `BugseeExtendedReport` attachments, which the SDK applies at upload and
/// answers by silently dropping (`BugseeReport.m`, `bgs_appendAppAttachment:`): at most 3 attachments,
/// each 1 byte to 3 MiB. Refused here instead, so the app hears about it.
FOUNDATION_EXPORT const NSUInteger BGSFlutterCreatedReportMaxAttachments;
FOUNDATION_EXPORT const NSUInteger BGSFlutterCreatedReportMaxAttachmentBytes;

/// What a read returns; plain so the Swift side builds the Pigeon message.
@interface BGSFlutterCreatedReportSnapshot : NSObject
@property(nonatomic, copy, nullable) NSString *summary;
@property(nonatomic, copy, nullable) NSString *reportDescription;
/// The SDK's value (1..5), or nil when it is outside it.
@property(nonatomic, strong, nullable) NSNumber *severity;
@property(nonatomic, copy) NSArray<NSString *> *labels;
@property(nonatomic, copy) NSDictionary<NSString *, id> *attributes;
@property(nonatomic, copy) NSArray<NSString *> *attachmentNames;
/// `@[@0]` when the report holds a screenshot, else empty (one display).
@property(nonatomic, copy) NSArray<NSNumber *> *screenshotDisplayIds;
@end

/// The edits of one apply; a `set...` flag makes a nil a clear.
@interface BGSFlutterCreatedReportPatch : NSObject
@property(nonatomic) BOOL setSummary;
@property(nonatomic, copy, nullable) NSString *summary;
@property(nonatomic) BOOL setDescription;
@property(nonatomic, copy, nullable) NSString *reportDescription;
@property(nonatomic, strong, nullable) NSNumber *severity;
@property(nonatomic, copy, nullable) NSArray *labels;
@property(nonatomic) BOOL clearAttributes;
@property(nonatomic, copy, nullable) NSDictionary *attributes;
@property(nonatomic, copy, nullable) NSArray *removeAttributes;
@end

/// What the Dart `CreatedReport` does to the `BugseeExtendedReport` that
/// `+[Bugsee createReportWithCompletion:]` hands out (`report` is typed `id` so this header needs no
/// SDK import). iOS gives the app a different, smaller object than Android: no id, type or e-mail, one
/// screenshot (display 0) with no annotated flag, attachments that are in-memory `BugseeAttachment`s
/// (name, file name and data; no MIME type) applied to the real report at upload. The object is
/// unsynchronised, and the SDK hands it out and takes it back on the main queue: call these there.
@interface BGSFlutterCreatedReportOps : NSObject

+ (BGSFlutterCreatedReportSnapshot *)readReport:(id)report;

/// Validates every field FIRST, then applies: a patch with one bad field changes nothing. Returns the
/// message of the first bad field, or nil when it was applied.
+ (nullable NSString *)applyPatch:(BGSFlutterCreatedReportPatch *)patch toReport:(id)report;

/// Copies the file's bytes (at most 3 MiB, read capped) into the report, as the legacy attachment
/// the SDK takes: the attachment is the app's own copy, so overwriting the file later changes nothing.
+ (BGSFlutterFileOutcome *)addFileAtPath:(nullable NSString *)path
                                    name:(nullable NSString *)name
                                mimeType:(nullable NSString *)mimeType
                                onReport:(id)report;
+ (BGSFlutterFileOutcome *)addData:(nullable NSData *)data
                              name:(nullable NSString *)name
                          mimeType:(nullable NSString *)mimeType
                          onReport:(id)report;
+ (BGSFlutterFileOutcome *)clearAttachmentsOnReport:(id)report;
/// `annotated` is `unsupported`: the legacy report has no flag, and the screenshot reaches the real
/// report as not annotated.
+ (BGSFlutterFileOutcome *)setScreenshotAtPath:(nullable NSString *)path
                                     annotated:(BOOL)annotated
                                      onReport:(id)report;

@end

NS_ASSUME_NONNULL_END
