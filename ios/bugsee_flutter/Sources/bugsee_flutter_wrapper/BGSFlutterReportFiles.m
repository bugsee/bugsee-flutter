#import "BGSFlutterReportFiles.h"

#import <ImageIO/ImageIO.h>

@import Bugsee;

NSString *const BGSFlutterFileNotLive = @"not-live";
NSString *const BGSFlutterFileNotFound = @"file-not-found";
NSString *const BGSFlutterFileNotAFile = @"not-a-file";
NSString *const BGSFlutterFileUnreadable = @"unreadable";
NSString *const BGSFlutterFileTooLarge = @"too-large";
NSString *const BGSFlutterFileLimit = @"limit";
NSString *const BGSFlutterFileRejected = @"rejected";
NSString *const BGSFlutterFileBusy = @"busy";
NSString *const BGSFlutterFileUnsupported = @"unsupported";
NSString *const BGSFlutterFileImageUndecodable = @"image-undecodable";
NSString *const BGSFlutterFileImageTooLarge = @"image-too-large";

const NSUInteger BGSFlutterMaxAttachmentBytes = 1024 * 1024;
// The soft limit of ONE attached file: 20 MiB (see Dart `maxAttachmentFileBytes`).
const unsigned long long BGSFlutterMaxAttachmentFileBytes = 20ULL * 1024ULL * 1024ULL;
const NSUInteger BGSFlutterMaxAttachmentNameLength = 255;
const NSUInteger BGSFlutterMaxMimeTypeLength = 255;
const NSUInteger BGSFlutterMaxPathLength = 4096;
const unsigned long long BGSFlutterMaxScreenshotPixels = 4096ULL * 4096ULL;
const NSUInteger BGSFlutterMaxReportAttachments = 1000;

@implementation BGSFlutterFileOutcome
- (instancetype)initWithCode:(NSString *)code argumentError:(NSString *)argumentError {
  self = [super init];
  if (self) {
    _code = [code copy];
    _argumentError = [argumentError copy];
  }
  return self;
}
+ (instancetype)done {
  return [[self alloc] initWithCode:nil argumentError:nil];
}
+ (instancetype)refusedWithCode:(NSString *)code {
  return [[self alloc] initWithCode:code argumentError:nil];
}
+ (instancetype)badArgument:(NSString *)message {
  return [[self alloc] initWithCode:nil argumentError:message];
}
@end

static BOOL HasControl(NSString *s) {
  for (NSUInteger i = 0; i < s.length; i++) {
    const unichar c = [s characterAtIndex:i];
    if (c < 0x20 || c == 0x7f) {
      return YES;
    }
  }
  return NO;
}

// The code points that make a name blank: the same explicit set in Dart (`_blankRanges`) and Java
// (`ReportOps.BLANK_RANGES`); a drift guard compares them.
static const unichar kBlankRanges[][2] = {
    {0x09, 0x0D}, {0x20, 0x20}, {0x85, 0x85}, {0xA0, 0xA0}, {0x1680, 0x1680}, {0x2000, 0x200A},
    {0x2028, 0x2029}, {0x202F, 0x202F}, {0x205F, 0x205F}, {0x3000, 0x3000},
};

static NSRegularExpression *MimeExpression(void) {
  static NSRegularExpression *expression;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    expression = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z0-9][A-Za-z0-9!#$&^_.+\\-]{0,126}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+\\-]{0,126}$"
                             options:0
                               error:NULL];
  });
  return expression;
}

@implementation BGSFlutterReportFiles

#pragma mark - Arguments

+ (NSString *)problemWithPath:(NSString *)path {
  if (![path isKindOfClass:[NSString class]] || path.length == 0 || path.length > BGSFlutterMaxPathLength ||
      HasControl(path)) {
    return @"a file path must be 1..4096 characters without control characters";
  }
  // A URL names no file for the SDKs, which take a path: `file://...` would fail inside the SDK
  // as "not a regular file", and a `content:` URI has no meaning on iOS at all.
  NSRegularExpression *scheme = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z][A-Za-z0-9+.\\-]*:"
                                                                          options:0
                                                                            error:NULL];
  if ([scheme firstMatchInString:path options:0 range:NSMakeRange(0, path.length)] != nil) {
    return @"pass a file system path, not a URL such as file: or content:";
  }
  if (![path hasPrefix:@"/"]) {
    return @"a file path must be absolute";
  }
  return nil;
}

+ (BOOL)isBlank:(NSString *)s {
  for (NSUInteger i = 0; i < s.length; i++) {
    const unichar c = [s characterAtIndex:i];
    BOOL blank = NO;
    for (size_t r = 0; r < sizeof(kBlankRanges) / sizeof(kBlankRanges[0]); r++) {
      if (c >= kBlankRanges[r][0] && c <= kBlankRanges[r][1]) {
        blank = YES;
        break;
      }
    }
    if (!blank) {
      return NO;
    }
  }
  return YES;
}

+ (NSString *)problemWithName:(NSString *)name {
  if (![name isKindOfClass:[NSString class]] ||
      [self isBlank:name] ||
      name.length > BGSFlutterMaxAttachmentNameLength || HasControl(name) ||
      [name containsString:@"/"] || [name containsString:@"\\"]) {
    return @"an attachment name must be 1..255 characters without control characters or a path separator";
  }
  return nil;
}

+ (NSString *)problemWithMimeType:(NSString *)mimeType {
  if (mimeType == nil) {
    return nil;
  }
  // `$` matches before a final line break in ICU, so a trailing newline would pass the expression.
  if (![mimeType isKindOfClass:[NSString class]] || mimeType.length > BGSFlutterMaxMimeTypeLength || HasControl(mimeType) ||
      [MimeExpression() firstMatchInString:mimeType options:0 range:NSMakeRange(0, mimeType.length)] == nil) {
    return @"a MIME type must look like type/subtype, without parameters";
  }
  return nil;
}

+ (NSString *)problemWithDisplayId:(int64_t)displayId {
  if (displayId < 0 || displayId > INT32_MAX) {
    return @"a display id must be between 0 and 2147483647";
  }
  return nil;
}

#pragma mark - Files

+ (NSString *)codeForUnreadableFileAtPath:(NSString *)path {
  NSFileManager *fileManager = NSFileManager.defaultManager;
  BOOL isDirectory = NO;
  // Follows a symbolic link; a dangling one is "not there".
  if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
    return BGSFlutterFileNotFound;
  }
  if (isDirectory) {
    return BGSFlutterFileNotAFile;
  }
  NSDictionary *attributes = [fileManager attributesOfItemAtPath:path.stringByResolvingSymlinksInPath error:NULL];
  if (attributes != nil && ![attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
    return BGSFlutterFileNotAFile;
  }
  if (![fileManager isReadableFileAtPath:path]) {
    return BGSFlutterFileUnreadable;
  }
  return nil;
}

+ (UIImage *)imageAtPath:(NSString *)path code:(NSString **)code {
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (source == NULL) {
    if (code) *code = BGSFlutterFileImageUndecodable;
    return nil;
  }
  NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
  CFRelease(source);
  const unsigned long long width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
  const unsigned long long height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
  if (width == 0 || height == 0) {
    if (code) *code = BGSFlutterFileImageUndecodable;
    return nil;
  }
  // The bounds first: an image over the cap is refused before a pixel is allocated.
  if (width * height > BGSFlutterMaxScreenshotPixels) {
    if (code) *code = BGSFlutterFileImageTooLarge;
    return nil;
  }
  UIImage *image = [UIImage imageWithContentsOfFile:path];
  if (image == nil) {
    if (code) *code = BGSFlutterFileImageUndecodable;
    return nil;
  }
  return image;
}

#pragma mark - A handler's report

+ (BGSFlutterFileOutcome *)addFileAtPath:(NSString *)path
                                    name:(NSString *)name
                                mimeType:(NSString *)mimeType
                                    move:(BOOL)move
                                onReport:(id<BGSReportContract>)report {
  NSString *problem = [self problemWithPath:path] ?: [self problemWithName:name] ?: [self problemWithMimeType:mimeType];
  if (problem != nil) {
    return [BGSFlutterFileOutcome badArgument:problem];
  }
  NSString *code = [self codeForUnreadableFileAtPath:path];
  if (code != nil) {
    return [BGSFlutterFileOutcome refusedWithCode:code];
  }
  NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path.stringByResolvingSymlinksInPath error:NULL];
  if ([attributes[NSFileSize] unsignedLongLongValue] > BGSFlutterMaxAttachmentFileBytes) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileTooLarge];
  }
  if (report.attachments.count >= BGSFlutterMaxReportAttachments) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileLimit];
  }
  if ([report addAttachmentWithFilePath:path name:name mimeType:mimeType move:move] == nil) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileRejected];
  }
  return [BGSFlutterFileOutcome done];
}

+ (BGSFlutterFileOutcome *)addData:(NSData *)data
                              name:(NSString *)name
                          mimeType:(NSString *)mimeType
                          onReport:(id<BGSReportContract>)report {
  NSString *problem = [self problemWithName:name] ?: [self problemWithMimeType:mimeType];
  if (problem != nil) {
    return [BGSFlutterFileOutcome badArgument:problem];
  }
  if (![data isKindOfClass:[NSData class]]) {
    return [BGSFlutterFileOutcome badArgument:@"attachment data must not be null"];
  }
  if (data.length > BGSFlutterMaxAttachmentBytes) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileTooLarge];
  }
  if (report.attachments.count >= BGSFlutterMaxReportAttachments) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileLimit];
  }
  if ([report addAttachmentWithData:data name:name mimeType:mimeType] == nil) {
    return [BGSFlutterFileOutcome refusedWithCode:BGSFlutterFileRejected];
  }
  return [BGSFlutterFileOutcome done];
}

+ (BGSFlutterFileOutcome *)clearAttachmentsOnReport:(id<BGSReportContract>)report {
  [report clearAttachments];
  return [BGSFlutterFileOutcome done];
}

+ (BGSFlutterFileOutcome *)setScreenshotAtPath:(NSString *)path
                                     displayId:(int64_t)displayId
                                     annotated:(BOOL)annotated
                                      onReport:(id<BGSReportContract>)report {
  NSString *problem = [self problemWithPath:path] ?: [self problemWithDisplayId:displayId];
  if (problem != nil) {
    return [BGSFlutterFileOutcome badArgument:problem];
  }
  NSString *code = [self codeForUnreadableFileAtPath:path];
  if (code != nil) {
    return [BGSFlutterFileOutcome refusedWithCode:code];
  }
  UIImage *image = [self imageAtPath:path code:&code];
  if (image == nil) {
    return [BGSFlutterFileOutcome refusedWithCode:code ?: BGSFlutterFileImageUndecodable];
  }
  // The un-annotated form clears the flag with the replaced picture; the annotated one sets it.
  [report setScreenshot:image displayId:(NSInteger)displayId annotated:annotated];
  return [BGSFlutterFileOutcome done];
}

+ (BGSFlutterFileOutcome *)removeScreenshotWithDisplayId:(int64_t)displayId onReport:(id<BGSReportContract>)report {
  NSString *problem = [self problemWithDisplayId:displayId];
  if (problem != nil) {
    return [BGSFlutterFileOutcome badArgument:problem];
  }
  // nil removes the screenshot and its attributes (the flag goes with it).
  [report setScreenshot:nil displayId:(NSInteger)displayId annotated:NO];
  return [BGSFlutterFileOutcome done];
}

@end
