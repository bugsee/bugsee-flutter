#import "BGSFlutterReportOps.h"

@import Bugsee;
// 7.0 GA moves the wrapper contract to the Bugsee.SPI submodule (BugseeSPI.h);
// the 7.0 betas declare it in Bugsee.h.
#if __has_include(<Bugsee/BugseeSPI.h>)
#import <Bugsee/BugseeSPI.h>
#endif

NSErrorDomain const BGSFlutterReportOpsErrorDomain = @"com.bugsee.flutter.report-ops";

@implementation BGSFlutterReportSnapshot
@end

static BOOL Refuse(NSError **error, NSString *message) {
  if (error != NULL) {
    *error = [NSError errorWithDomain:BGSFlutterReportOpsErrorDomain
                                 code:1
                             userInfo:@{NSLocalizedDescriptionKey : message}];
  }
  return NO;
}

/// An NSNumber that is a boolean (what Dart's `bool` arrives as), not merely 0 or 1.
static BOOL IsBoolean(NSNumber *number) {
  return CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID();
}

@implementation BGSFlutterReportOps

+ (NSInteger)minSeverity {
  return 1;
}

+ (NSInteger)maxSeverity {
  return 5;
}

+ (NSString *)typeOfReport:(id<BGSReportContract>)report {
  @try {
    NSString *type = report.type;
    return [type isKindOfClass:[NSString class]] ? type : @"";
  } @catch (NSException *exception) {
    return @"";
  }
}

+ (BGSFlutterReportSnapshot *)readReport:(id<BGSReportContract>)report {
  BGSFlutterReportSnapshot *s = [[BGSFlutterReportSnapshot alloc] init];
  s.reportId = report.reportId ?: @"";
  s.type = [self typeOfReport:report];
  s.summary = report.summary;
  s.reportDescription = report.reportDescription;
  s.email = report.email;
  // 0 is "never set" (only a report's own initializer produces it): not a level.
  const NSInteger severity = (NSInteger)report.severity;
  s.severity = (severity >= self.minSeverity && severity <= self.maxSeverity) ? @(severity) : nil;
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (id label in report.labels) {  // a snapshot, taken under the report's lock
    if ([label isKindOfClass:[NSString class]]) {
      [labels addObject:label];
    }
  }
  s.labels = labels;
  NSMutableDictionary<NSString *, id> *attributes = [NSMutableDictionary dictionary];
  [report.attributes enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
    // Only what both SDKs accept; anything else has no Dart representation, and a description
    // would read as a real value.
    if ([key isKindOfClass:[NSString class]] && [self isAllowedAttributeValue:value]) {
      attributes[key] = value;
    }
  }];
  s.attributes = attributes;
  [self readFilesOf:report into:s];
  return s;
}

/// The attachments' metadata and the screenshots' ids and flags; never content.
+ (void)readFilesOf:(id<BGSReportContract>)report into:(BGSFlutterReportSnapshot *)s {
  NSMutableArray<NSArray *> *attachments = [NSMutableArray array];
  for (id<BGSAttachmentContract> attachment in report.attachments) {  // a snapshot, under the lock
    NSString *name = attachment.name;
    NSString *mimeType = attachment.mimeType;
    NSString *fileName = attachment.fileName;
    [attachments addObject:@[
      [name isKindOfClass:[NSString class]] ? name : (id)NSNull.null,
      [mimeType isKindOfClass:[NSString class]] ? mimeType : (id)NSNull.null,
      [fileName isKindOfClass:[NSString class]] ? fileName : (id)NSNull.null,
    ]];
  }
  s.attachments = attachments;
  NSMutableArray<NSArray<NSNumber *> *> *screenshots = [NSMutableArray array];
  for (NSNumber *displayId in report.screenshotDisplayIds) {
    NSDictionary *attributes = [report screenshotAttributesForDisplayId:displayId.integerValue];
    [screenshots addObject:@[ displayId, @([attributes[@"annotated"] boolValue]) ]];
  }
  s.screenshots = screenshots;
}

+ (void)setSummary:(NSString *)summary onReport:(id<BGSReportContract>)report {
  report.summary = summary;
}

+ (void)setDescription:(NSString *)description onReport:(id<BGSReportContract>)report {
  report.reportDescription = description;
}

+ (void)setEmail:(NSString *)email onReport:(id<BGSReportContract>)report {
  report.email = email;
}

+ (void)clearLabelsOnReport:(id<BGSReportContract>)report {
  [report clearLabels];
}

+ (void)removeAttribute:(NSString *)name onReport:(id<BGSReportContract>)report {
  [report removeAttributeForName:name];
}

+ (void)clearAttributesOnReport:(id<BGSReportContract>)report {
  [report clearAllAttributes];
}

+ (BOOL)setSeverity:(int64_t)wire onReport:(id<BGSReportContract>)report error:(NSError **)error {
  // The SDK ignores a value outside Low...Blocker and keeps the old one (logging the refusal),
  // which would look like success here; refuse it instead, before it reaches the SDK.
  if (wire < self.minSeverity || wire > self.maxSeverity) {
    return Refuse(error, @"severity must be an SDK severity value (1..5)");
  }
  report.severity = (BugseeSeverityLevel)wire;
  return YES;
}

/// Strings only. A list with anything else is refused as a whole, so a partly valid list
/// changes nothing.
+ (nullable NSArray<NSString *> *)stringsFrom:(id)labels error:(NSError **)error {
  if (![labels isKindOfClass:[NSArray class]]) {
    Refuse(error, @"labels must be a list of strings");
    return nil;
  }
  for (id item in (NSArray *)labels) {
    if (![item isKindOfClass:[NSString class]]) {
      Refuse(error, @"labels must be a list of strings");
      return nil;
    }
  }
  return labels;
}

+ (BOOL)replaceLabels:(id)labels onReport:(id<BGSReportContract>)report error:(NSError **)error {
  NSArray<NSString *> *strings = [self stringsFrom:labels error:error];
  if (strings == nil) {
    return NO;
  }
  // One call: clear-then-add would expose a label-less report between the two.
  [report replaceLabels:strings];
  return YES;
}

+ (BOOL)addLabels:(id)labels onReport:(id<BGSReportContract>)report error:(NSError **)error {
  NSArray<NSString *> *strings = [self stringsFrom:labels error:error];
  if (strings == nil) {
    return NO;
  }
  [report addLabels:strings];
  return YES;
}

+ (BOOL)isAllowedAttributeValue:(id)value {
  if ([value isKindOfClass:[NSString class]]) {
    return YES;
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    NSNumber *number = value;
    if (IsBoolean(number)) {
      return YES;
    }
    const double d = number.doubleValue;
    return isfinite(d);
  }
  return NO;
}

+ (BOOL)setAttribute:(id)value
                name:(NSString *)name
            onReport:(id<BGSReportContract>)report
               error:(NSError **)error {
  if (![name isKindOfClass:[NSString class]] || name.length == 0) {
    return Refuse(error, @"an attribute needs a non-empty name");
  }
  if (![self isAllowedAttributeValue:value]) {
    return Refuse(error, @"an attribute value must be a string, a bool or a finite number");
  }
  [report setAttribute:value forName:name];
  return YES;
}

@end
