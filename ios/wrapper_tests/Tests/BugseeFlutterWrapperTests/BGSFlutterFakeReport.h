@import Foundation;
@import Bugsee;
// 7.0 GA moves the wrapper contract to the Bugsee.SPI submodule (BugseeSPI.h);
// the 7.0 betas declare it in Bugsee.h.
#if __has_include(<Bugsee/BugseeSPI.h>)
#import <Bugsee/BugseeSPI.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// A `BGSReportContract` that holds the state the bridge reads and writes, and records every
/// MUTATING call by selector, in order, so a test can assert HOW the report was changed
/// (`replaceLabels:` rather than `clearLabels` + `addLabels:`), not only its end state.
///
/// A method this fake does not model raises, so a test cannot pass by accident through a call
/// the bridge was never meant to make (attachments, screenshots: Phase 6).
///
/// The severity setter behaves like the SDK's: it ignores anything outside 1..5 and keeps the
/// current value, silently. That is the refusal the wrapper's own validation exists to turn into
/// an error.
@interface BGSFlutterFakeReport : NSObject <BGSReportContract>
@property(nonatomic, copy) NSString *fakeReportId;
@property(nonatomic, copy) NSString *fakeType;
@property(nonatomic, copy, nullable) NSString *fakeSummary;
@property(nonatomic, copy, nullable) NSString *fakeDescription;
@property(nonatomic, copy, nullable) NSString *fakeEmail;
/// 0 is the SDK's "never set".
@property(nonatomic) BugseeSeverityLevel fakeSeverity;
@property(nonatomic, readonly) NSMutableArray<NSString *> *fakeLabels;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, id> *fakeAttributes;
/// Every mutating selector called, in order.
@property(nonatomic, readonly) NSMutableArray<NSString *> *mutations;
/// Run before / after the summary is stored; lets a test widen or observe the window.
@property(nonatomic, copy, nullable) dispatch_block_t beforeSetSummary;
@property(nonatomic, copy, nullable) dispatch_block_t onSummarySet;
/// How many times `reportId` / `type` were read.
@property(nonatomic) NSUInteger reads;

// ---- Attachments and screenshots: a model of what the SDK does (nextgen `BGSReport.m`) ----------
/// The attachments the report holds (`BGSFlutterFakeAttachment`s).
@property(nonatomic, readonly) NSMutableArray<id<BGSAttachmentContract>> *fakeAttachments;
/// What each add received: `@{@"path"/@"data", @"name", @"mimeType", @"move"}`.
@property(nonatomic, readonly) NSMutableArray<NSDictionary *> *adds;
/// The SDK declines every add (nil), as it does for a report that is no longer live.
@property(nonatomic) BOOL refuseAdds;
/// Where the model stores what it was given (a copy; a move also deletes the source).
@property(nonatomic, copy, nullable) NSString *storagePath;
/// displayId -> `@[UIImage, @(annotated)]`.
@property(nonatomic, readonly) NSMutableDictionary<NSNumber *, NSArray *> *fakeScreenshots;
@end

/// A `BGSAttachmentContract` with plain storage.
@interface BGSFlutterFakeAttachment : NSObject <BGSAttachmentContract>
@property(nonatomic, copy, nullable) NSString *name;
@property(nonatomic, copy, nullable) NSString *mimeType;
@property(nonatomic, copy, nullable) NSString *fileName;
@property(nonatomic, copy, nullable) NSString *filePath;
@property(nonatomic, strong, nullable) NSData *data;
@end

NS_ASSUME_NONNULL_END
