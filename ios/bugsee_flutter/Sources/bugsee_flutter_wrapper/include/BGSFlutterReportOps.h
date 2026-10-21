#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const BGSFlutterReportOpsErrorDomain;

/// What a read returns; plain, so the Swift side builds the Pigeon message.
@interface BGSFlutterReportSnapshot : NSObject
@property(nonatomic, copy) NSString *reportId;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, copy, nullable) NSString *summary;
@property(nonatomic, copy, nullable) NSString *reportDescription;
@property(nonatomic, copy, nullable) NSString *email;
/// The SDK's internal value (1..5), or nil when the SDK reads 0 ("never set"), which must
/// not become a level.
@property(nonatomic, strong, nullable) NSNumber *severity;
@property(nonatomic, copy) NSArray<NSString *> *labels;
/// Strings, bools and finite numbers only: what both SDKs carry.
@property(nonatomic, copy) NSDictionary<NSString *, id> *attributes;
@end

/// The operations the Dart report proxy performs on the SDK's `BGSReportContract` (workbook
/// 7.3), as plain Objective-C so every rule is XCTested without Flutter. Whether the report
/// is still live is not decided here (see `BGSFlutterReportHandlerPipeline`); what this owns is
/// what the SDK would otherwise take silently and get wrong: a severity outside 1..5 (the SDK
/// ignores it and keeps the old one, logging), an attribute value the backend cannot carry, a
/// label that is not a string.
///
/// Attachments and screenshots are NOT here (Phase 6, path-first, workbook 7.3.3).
@interface BGSFlutterReportOps : NSObject

/// The severity range the SDKs accept (`BugseeSeverityLow`..`BugseeSeverityBlocker`). Repeated
/// in Dart (`ReportSeverity`) and Java (`ReportOps`); `test/report_enum_parity_test.dart`
/// compares the copies, and the XCTest compares them to the SDK's enum.
+ (NSInteger)minSeverity;
+ (NSInteger)maxSeverity;

/// `report.type` (`bug`, `crash`, `error`), or "" if unreadable. Never throws.
+ (NSString *)typeOfReport:(id)report;
+ (BGSFlutterReportSnapshot *)readReport:(id)report;

+ (void)setSummary:(nullable NSString *)summary onReport:(id)report;
+ (void)setDescription:(nullable NSString *)description onReport:(id)report;
+ (void)setEmail:(nullable NSString *)email onReport:(id)report;
+ (void)clearLabelsOnReport:(id)report;
+ (void)removeAttribute:(NSString *)name onReport:(id)report;
+ (void)clearAttributesOnReport:(id)report;

+ (BOOL)setSeverity:(int64_t)wire onReport:(id)report error:(NSError *_Nullable *_Nullable)error;
+ (BOOL)replaceLabels:(nullable id)labels onReport:(id)report error:(NSError *_Nullable *_Nullable)error;
+ (BOOL)addLabels:(nullable id)labels onReport:(id)report error:(NSError *_Nullable *_Nullable)error;
+ (BOOL)setAttribute:(nullable id)value
                name:(nullable NSString *)name
            onReport:(id)report
               error:(NSError *_Nullable *_Nullable)error;
/// String, bool, or a finite number. A bool is an `NSNumber` of boolean type; any other
/// object (dictionary, array, null) is refused.
+ (BOOL)isAllowedAttributeValue:(nullable id)value;

@end

NS_ASSUME_NONNULL_END
