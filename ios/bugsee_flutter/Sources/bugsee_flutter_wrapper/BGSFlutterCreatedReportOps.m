#import "BGSFlutterCreatedReportOps.h"

#import "BGSFlutterReportOps.h"

@import Bugsee;

// `ATTACHMENTS_LIMIT` and `MAX_SIZE_ATTACHMENT` in `BGSAttachment.h` (nextgen).
const NSUInteger BGSFlutterCreatedReportMaxAttachments = 3;
const NSUInteger BGSFlutterCreatedReportMaxAttachmentBytes = 3u * 1024u * 1024u;

@implementation BGSFlutterCreatedReportSnapshot
@end
@implementation BGSFlutterCreatedReportPatch
@end
@implementation BGSFlutterPreparedFile
@end

@implementation BGSFlutterCreatedReportOps

+ (BGSFlutterCreatedReportSnapshot *)readReport:(BugseeExtendedReport *)report {
  BGSFlutterCreatedReportSnapshot *s = [[BGSFlutterCreatedReportSnapshot alloc] init];
  s.summary = report.summary;
  s.reportDescription = report.reportDescription;
  const NSInteger severity = (NSInteger)report.severity;
  s.severity = (severity >= BGSFlutterReportOps.minSeverity && severity <= BGSFlutterReportOps.maxSeverity) ? @(severity) : nil;
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (id label in report.labels) {
    if ([label isKindOfClass:[NSString class]]) {
      [labels addObject:label];
    }
  }
  s.labels = labels;
  NSMutableDictionary<NSString *, id> *attributes = [NSMutableDictionary dictionary];
  [report.attributes enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
    if ([key isKindOfClass:[NSString class]] && [BGSFlutterReportOps isAllowedAttributeValue:value]) {
      attributes[key] = value;
    }
  }];
  s.attributes = attributes;
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (BugseeAttachment *attachment in report.attachments) {
    if ([attachment.name isKindOfClass:[NSString class]]) {
      [names addObject:attachment.name];
    }
  }
  s.attachmentNames = names;
  s.screenshotDisplayIds = report.screenshot != nil ? @[ @0 ] : @[];
  return s;
}

+ (NSString *)applyPatch:(BGSFlutterCreatedReportPatch *)patch toReport:(BugseeExtendedReport *)report {
  // Everything is checked before anything is applied.
  if (patch.severity != nil) {
    const long long v = patch.severity.longLongValue;
    if (v < BGSFlutterReportOps.minSeverity || v > BGSFlutterReportOps.maxSeverity) {
      return @"severity must be an SDK severity value (1..5)";
    }
  }
  if (patch.labels != nil) {
    if (![patch.labels isKindOfClass:[NSArray class]]) {
      return @"labels must be a list of strings";
    }
    for (id label in patch.labels) {
      if (![label isKindOfClass:[NSString class]]) {
        return @"labels must be a list of strings";
      }
    }
  }
  for (id name in patch.removeAttributes) {
    if (![name isKindOfClass:[NSString class]] || [(NSString *)name length] == 0) {
      return @"an attribute needs a non-empty name";
    }
  }
  for (id name in patch.attributes) {
    if (![name isKindOfClass:[NSString class]] || [(NSString *)name length] == 0) {
      return @"an attribute needs a non-empty name";
    }
    if (![BGSFlutterReportOps isAllowedAttributeValue:patch.attributes[name]]) {
      return @"an attribute value must be a string, a bool or a finite number";
    }
  }

  if (patch.setSummary) {
    [report setSummary:patch.summary];
  }
  if (patch.setDescription) {
    [report setDescription:patch.reportDescription];
  }
  if (patch.severity != nil) {
    [report setSeverity:(BugseeSeverityLevel)patch.severity.integerValue];
  }
  if (patch.labels != nil) {
    // Assignment replaces; there is no clear-then-add on this class.
    report.labels = patch.labels;
  }
  if (patch.clearAttributes) {
    [report clearAllAttributes];
  }
  [patch.attributes enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
    [report setAttribute:key withValue:value];
  }];
  for (NSString *name in patch.removeAttributes) {
    [report clearAttribute:name];
  }
  return nil;
}

#pragma mark - Attachments

/// The legacy report's own attachment rules, refused here rather than dropped silently at upload.
+ (nullable NSString *)codeForRoomOnReport:(BugseeExtendedReport *)report {
  return report.attachments.count >= BGSFlutterCreatedReportMaxAttachments ? BGSFlutterFileLimit : nil;
}

+ (BGSFlutterFileOutcome *)attach:(NSData *)data
                             name:(NSString *)name
                         fileName:(NSString *)fileName
                         onReport:(BugseeExtendedReport *)report {
  if (data.length == 0) {
    return [BGSFlutterFileOutcome badArgument:@"a created-report attachment must not be empty"];
  }
  if (data.length > BGSFlutterCreatedReportMaxAttachmentBytes) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileTooLarge];
  }
  BugseeAttachment *attachment = [BugseeAttachment attachmentWithName:name filename:fileName data:data];
  if (attachment == nil) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileRejected];
  }
  [report setAttachment:attachment];
  return [BGSFlutterFileOutcome done];
}

+ (BGSFlutterFileOutcome *)addFileAtPath:(NSString *)path
                                    name:(NSString *)name
                                mimeType:(NSString *)mimeType
                                onReport:(BugseeExtendedReport *)report {
  return [self applyPreparedFile:[self prepareFileAtPath:path name:name mimeType:mimeType] name:name onReport:report];
}

+ (BGSFlutterPreparedFile *)prepareFileAtPath:(NSString *)path name:(NSString *)name mimeType:(NSString *)mimeType {
  BGSFlutterPreparedFile *prepared = [[BGSFlutterPreparedFile alloc] init];
  // The MIME type is validated like everywhere, and then not kept: `BugseeAttachment` has none.
  NSString *problem = [BGSFlutterReportFiles problemWithPath:path] ?: [BGSFlutterReportFiles problemWithName:name]
                      ?: [BGSFlutterReportFiles problemWithMimeType:mimeType];
  if (problem != nil) {
    prepared.failure = [BGSFlutterFileOutcome badArgument:problem];
    return prepared;
  }
  NSString *code = [BGSFlutterReportFiles codeForUnreadableFileAtPath:path];
  if (code != nil) {
    prepared.failure = [BGSFlutterFileOutcome refusedWithCode:code];
    return prepared;
  }
  // The size of what the link points at, not of the link, and a read that cannot exceed the cap: the
  // size can grow between the stat and the read.
  NSString *resolved = path.stringByResolvingSymlinksInPath;
  NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:resolved error:NULL];
  if (attributes == nil) {
    prepared.failure = [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileUnreadable];
    return prepared;
  }
  // iOS drops an empty attachment at upload, so neither platform takes one (Android's flow refuses too).
  if ([attributes[NSFileSize] unsignedLongLongValue] == 0) {
    prepared.failure = [BGSFlutterFileOutcome badArgument:@"a created-report attachment must not be empty"];
    return prepared;
  }
  if ([attributes[NSFileSize] unsignedLongLongValue] > BGSFlutterCreatedReportMaxAttachmentBytes) {
    prepared.failure = [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileTooLarge];
    return prepared;
  }
  NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:resolved];
  if (handle == nil) {
    prepared.failure = [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileUnreadable];
    return prepared;
  }
  NSData *read = nil;
  @try {
    read = [handle readDataOfLength:BGSFlutterCreatedReportMaxAttachmentBytes + 1];
  } @catch (NSException *exception) {
    read = nil;
  }
  [handle closeFile];
  if (read == nil) {
    prepared.failure = [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileUnreadable];
    return prepared;
  }
  // Own the bytes: the file belongs to the app, and overwriting it later must not change what the
  // report will upload.
  prepared.data = [NSData dataWithBytes:read.bytes length:read.length];
  prepared.fileName = path.lastPathComponent;
  return prepared;
}

+ (BGSFlutterFileOutcome *)applyPreparedFile:(BGSFlutterPreparedFile *)prepared
                                        name:(NSString *)name
                                    onReport:(BugseeExtendedReport *)report {
  if (prepared.failure != nil) {
    return prepared.failure;
  }
  NSString *code = [self codeForRoomOnReport:report];
  if (code != nil) {
    return [BGSFlutterFileOutcome refusedWithCode:code];
  }
  return [self attach:prepared.data name:name fileName:prepared.fileName onReport:report];
}

+ (BGSFlutterFileOutcome *)addData:(NSData *)data
                              name:(NSString *)name
                          mimeType:(NSString *)mimeType
                          onReport:(BugseeExtendedReport *)report {
  NSString *problem = [BGSFlutterReportFiles problemWithName:name] ?: [BGSFlutterReportFiles problemWithMimeType:mimeType];
  if (problem != nil) {
    return [BGSFlutterFileOutcome badArgument:problem];
  }
  if (![data isKindOfClass:[NSData class]]) {
    return [BGSFlutterFileOutcome badArgument:@"attachment data must not be null"];
  }
  if (data.length > BGSFlutterMaxAttachmentBytes) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileTooLarge];
  }
  NSString *code = [self codeForRoomOnReport:report];
  if (code != nil) {
    return [BGSFlutterFileOutcome refusedWithCode:code];
  }
  return [self attach:[NSData dataWithData:data] name:name fileName:name onReport:report];
}

+ (BGSFlutterFileOutcome *)clearAttachmentsOnReport:(BugseeExtendedReport *)report {
  [report clearAllAttachments];
  return [BGSFlutterFileOutcome done];
}

+ (BGSFlutterFileOutcome *)setScreenshotAtPath:(NSString *)path
                                     annotated:(BOOL)annotated
                                      onReport:(BugseeExtendedReport *)report {
  return [self applyPreparedScreenshot:[self prepareScreenshotAtPath:path annotated:annotated] onReport:report];
}

+ (BGSFlutterPreparedFile *)prepareScreenshotAtPath:(NSString *)path annotated:(BOOL)annotated {
  BGSFlutterPreparedFile *prepared = [[BGSFlutterPreparedFile alloc] init];
  NSString *problem = [BGSFlutterReportFiles problemWithPath:path];
  if (problem != nil) {
    prepared.failure = [BGSFlutterFileOutcome badArgument:problem];
    return prepared;
  }
  if (annotated) {
    prepared.failure = [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileUnsupported];
    return prepared;
  }
  NSString *code = [BGSFlutterReportFiles codeForUnreadableFileAtPath:path];
  if (code != nil) {
    prepared.failure = [BGSFlutterFileOutcome refusedWithCode:code];
    return prepared;
  }
  UIImage *image = [BGSFlutterReportFiles imageAtPath:path code:&code];
  if (image == nil) {
    prepared.failure = [BGSFlutterFileOutcome refusedWithCode:code ?: BGSFlutterFileImageUndecodable];
    return prepared;
  }
  prepared.image = image;
  return prepared;
}

+ (BGSFlutterFileOutcome *)applyPreparedScreenshot:(BGSFlutterPreparedFile *)prepared onReport:(BugseeExtendedReport *)report {
  if (prepared.failure != nil) {
    return prepared.failure;
  }
  [report setScreenshot:prepared.image];
  return [BGSFlutterFileOutcome done];
}

@end
