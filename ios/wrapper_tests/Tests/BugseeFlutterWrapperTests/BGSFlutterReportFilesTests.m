#import <XCTest/XCTest.h>

#import "BGSFlutterFakeReport.h"
#import "BGSFlutterReportFiles.h"
#import "BGSFlutterReportOps.h"

/// Path-first attachments and screenshots on a handler's report (workbook 7.3.3, report-contract): what
/// is validated before the SDK is asked, how a refusal is named, and that a refused add never consumes
/// the caller's file. The SDK's own file work is modelled by `BGSFlutterFakeReport`; the real SDK is
/// shown on a device by `example/integration_test/attachments_test.dart`.
@interface BGSFlutterReportFilesTests : XCTestCase
@end

@implementation BGSFlutterReportFilesTests {
  BGSFlutterFakeReport *_report;
  NSString *_dir;
  NSString *_source;
}

- (void)setUp {
  _report = [[BGSFlutterFakeReport alloc] init];
  _dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  [NSFileManager.defaultManager createDirectoryAtPath:[_dir stringByAppendingPathComponent:@"storage"]
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:NULL];
  _report.storagePath = [_dir stringByAppendingPathComponent:@"storage"];
  _source = [_dir stringByAppendingPathComponent:@"app.log"];
  [@"hello" writeToFile:_source atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtPath:_dir error:NULL];
}

- (BOOL)exists:(NSString *)path {
  return [NSFileManager.defaultManager fileExistsAtPath:path];
}

- (void)assertDone:(BGSFlutterFileOutcome *)outcome {
  XCTAssertNil(outcome.code);
  XCTAssertNil(outcome.argumentError);
}

- (void)assertRefused:(BGSFlutterFileOutcome *)outcome code:(NSString *)code {
  XCTAssertEqualObjects(outcome.code, code);
  XCTAssertNil(outcome.argumentError);
}

- (void)assertBad:(BGSFlutterFileOutcome *)outcome {
  XCTAssertNotNil(outcome.argumentError);
  XCTAssertNil(outcome.code);
}

/// A PNG of the given size, drawn with an 8-bit gray context (1 byte a pixel, cheap).
- (NSString *)imageNamed:(NSString *)name width:(size_t)width height:(size_t)height {
  CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
  CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width, space, (CGBitmapInfo)kCGImageAlphaNone);
  CGColorSpaceRelease(space);
  CGImageRef image = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  NSString *path = [_dir stringByAppendingPathComponent:name];
  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)@"public.png", 1, NULL);
  CGImageDestinationAddImage(destination, image, NULL);
  CGImageDestinationFinalize(destination);
  CFRelease(destination);
  CGImageRelease(image);
  [data writeToFile:path atomically:YES];
  return path;
}

#pragma mark - The file path

- (void)testACopyHandsTheSdkTheFileAndLeavesTheSourceAlone {
  [self assertDone:[BGSFlutterReportFiles addFileAtPath:_source name:@"Log" mimeType:@"text/plain" move:NO onReport:_report]];
  XCTAssertEqual(_report.adds.count, 1u);
  NSDictionary *add = _report.adds.firstObject;
  XCTAssertEqualObjects(add[@"path"], _source);
  XCTAssertEqualObjects(add[@"name"], @"Log");
  XCTAssertEqualObjects(add[@"mimeType"], @"text/plain");
  XCTAssertEqualObjects(add[@"move"], @NO);
  XCTAssertTrue([self exists:_source], @"a copy leaves the source");
  XCTAssertEqual(_report.fakeAttachments.count, 1u);
}

- (void)testAMoveIsPassedOnAndTheSdkConsumesTheSource {
  [self assertDone:[BGSFlutterReportFiles addFileAtPath:_source name:@"Log" mimeType:nil move:YES onReport:_report]];
  XCTAssertEqualObjects(_report.adds.firstObject[@"move"], @YES);
  XCTAssertEqualObjects(_report.adds.firstObject[@"mimeType"], NSNull.null, @"no type is passed as nil");
  XCTAssertFalse([self exists:_source], @"the move consumed the source");
}

- (void)testARefusedMoveDoesNotConsumeTheSource {
  _report.refuseAdds = YES;
  [self assertRefused:[BGSFlutterReportFiles addFileAtPath:_source name:@"Log" mimeType:nil move:YES onReport:_report]
                 code:BGSFlutterFileRejected];
  XCTAssertTrue([self exists:_source], @"the SDK declined: the source is untouched");
  XCTAssertEqual(_report.fakeAttachments.count, 0u);
}

- (void)testEveryKindOfBadPathIsRefusedBeforeTheSdkIsAsked {
  NSString *longPath = [@"/" stringByPaddingToLength:BGSFlutterMaxPathLength + 1 withString:@"a" startingAtIndex:0];
  for (id path in @[ NSNull.null, @"", @"relative/a.txt", @"a.txt", @"file:///data/a.txt", @"content://media/1",
                     @"http://x/y", @"/data/a\0b", @"/data/a\nb", longPath ]) {
    [self assertBad:[BGSFlutterReportFiles addFileAtPath:path == NSNull.null ? nil : path
                                                    name:@"n"
                                                mimeType:nil
                                                    move:NO
                                                onReport:_report]];
  }
  XCTAssertEqual(_report.adds.count, 0u, @"nothing reached the SDK");
}

- (void)testEveryKindOfBadNameAndTypeIsRefusedBeforeTheSdkIsAsked {
  NSString *tooLong = [@"" stringByPaddingToLength:BGSFlutterMaxAttachmentNameLength + 1 withString:@"n" startingAtIndex:0];
  for (id name in @[ NSNull.null, @"", @"   ", @"../x", @"a/b", @"a\\b", @"a\nb", [NSString stringWithFormat:@"a%cb", 0x7f], tooLong ]) {
    [self assertBad:[BGSFlutterReportFiles addFileAtPath:_source name:name == NSNull.null ? nil : name mimeType:nil move:NO onReport:_report]];
  }
  for (NSString *mime in @[ @"", @"text", @"text/", @"/plain", @"text/plain; charset=utf-8", @"te xt/plain", @"text/pl/ain", @"a/b\n" ]) {
    [self assertBad:[BGSFlutterReportFiles addFileAtPath:_source name:@"n" mimeType:mime move:NO onReport:_report]];
  }
  XCTAssertEqual(_report.adds.count, 0u);
}

- (void)testGoodNamesAndTypesAreAccepted {
  [self assertDone:[BGSFlutterReportFiles addFileAtPath:_source name:@"My log (1).txt" mimeType:@"application/vnd.api+json" move:NO onReport:_report]];
  [self assertDone:[BGSFlutterReportFiles addFileAtPath:_source name:@"é日本" mimeType:@"image/svg+xml" move:NO onReport:_report]];
  [self assertDone:[BGSFlutterReportFiles addFileAtPath:_source
                                                   name:[@"" stringByPaddingToLength:BGSFlutterMaxAttachmentNameLength withString:@"n" startingAtIndex:0]
                                               mimeType:nil
                                                   move:NO
                                               onReport:_report]];
  XCTAssertEqual(_report.adds.count, 3u);
}

- (void)testAMissingFileIsNamed {
  [self assertRefused:[BGSFlutterReportFiles addFileAtPath:[_dir stringByAppendingPathComponent:@"nope.txt"] name:@"n" mimeType:nil move:YES onReport:_report]
                 code:BGSFlutterFileNotFound];
  XCTAssertEqual(_report.adds.count, 0u);
}

- (void)testADirectoryIsNotAFile {
  [self assertRefused:[BGSFlutterReportFiles addFileAtPath:_dir name:@"n" mimeType:nil move:YES onReport:_report] code:BGSFlutterFileNotAFile];
  XCTAssertEqual(_report.adds.count, 0u);
}

- (void)testAnUnreadableFileIsNamedAndNotConsumed {
  NSString *secret = [_dir stringByAppendingPathComponent:@"secret.txt"];
  [@"x" writeToFile:secret atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions : @0} ofItemAtPath:secret error:NULL];
  if ([NSFileManager.defaultManager isReadableFileAtPath:secret]) {
    XCTSkip(@"file permissions do not apply to this process");
  }
  [self assertRefused:[BGSFlutterReportFiles addFileAtPath:secret name:@"n" mimeType:nil move:YES onReport:_report] code:BGSFlutterFileUnreadable];
  [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions : @0644} ofItemAtPath:secret error:NULL];
  XCTAssertTrue([self exists:secret]);
  XCTAssertEqual(_report.adds.count, 0u);
}

- (void)testASymbolicLinkToAFileIsFollowedAndItsTargetUntouched {
  NSString *link = [_dir stringByAppendingPathComponent:@"link.log"];
  [NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:_source error:NULL];
  [self assertDone:[BGSFlutterReportFiles addFileAtPath:link name:@"via link" mimeType:nil move:NO onReport:_report]];
  XCTAssertEqualObjects(_report.adds.firstObject[@"path"], link);
  XCTAssertTrue([self exists:_source]);
}

- (void)testADanglingLinkIsMissing {
  NSString *dangling = [_dir stringByAppendingPathComponent:@"dangling"];
  [NSFileManager.defaultManager createSymbolicLinkAtPath:dangling withDestinationPath:[_dir stringByAppendingPathComponent:@"gone"] error:NULL];
  [self assertRefused:[BGSFlutterReportFiles addFileAtPath:dangling name:@"n" mimeType:nil move:YES onReport:_report] code:BGSFlutterFileNotFound];
}

- (void)testTheSdksAttachmentCountIsNamedBeforeItsBareNil {
  for (NSUInteger i = 0; i < BGSFlutterMaxReportAttachments; i++) {
    [self assertDone:[BGSFlutterReportFiles addData:[NSData data] name:[NSString stringWithFormat:@"n%lu", (unsigned long)i] mimeType:nil onReport:_report]];
  }
  XCTAssertEqual(_report.fakeAttachments.count, BGSFlutterMaxReportAttachments);
  const NSUInteger before = _report.adds.count;
  [self assertRefused:[BGSFlutterReportFiles addFileAtPath:_source name:@"n" mimeType:nil move:YES onReport:_report] code:BGSFlutterFileLimit];
  [self assertRefused:[BGSFlutterReportFiles addData:[NSData dataWithBytes:"x" length:1] name:@"n" mimeType:nil onReport:_report] code:BGSFlutterFileLimit];
  XCTAssertEqual(_report.adds.count, before, @"the SDK was not asked");
  XCTAssertTrue([self exists:_source]);
  XCTAssertEqual(BGSFlutterMaxReportAttachments, 1000u);
}

#pragma mark - Bytes

- (void)testBytesAreHandedOverUpToTheCapAndEmptyIsValid {
  [self assertDone:[BGSFlutterReportFiles addData:[NSData dataWithBytes:"\1\2\3" length:3] name:@"raw.bin" mimeType:@"application/octet-stream" onReport:_report]];
  [self assertDone:[BGSFlutterReportFiles addData:[NSData data] name:@"empty" mimeType:nil onReport:_report]];
  [self assertDone:[BGSFlutterReportFiles addData:[NSMutableData dataWithLength:BGSFlutterMaxAttachmentBytes] name:@"max" mimeType:nil onReport:_report]];
  XCTAssertEqual(_report.fakeAttachments.count, 3u);
  XCTAssertEqualObjects(_report.fakeAttachments.firstObject.fileName, @"raw.bin");
}

- (void)testOneByteOverTheCapIsTooLargeAndNeverReachesTheSdk {
  [self assertRefused:[BGSFlutterReportFiles addData:[NSMutableData dataWithLength:BGSFlutterMaxAttachmentBytes + 1] name:@"big" mimeType:nil onReport:_report]
                 code:BGSFlutterFileTooLarge];
  XCTAssertEqual(_report.adds.count, 0u);
}

- (void)testNilBytesAndABadNameOrTypeAreArgumentErrors {
  [self assertBad:[BGSFlutterReportFiles addData:nil name:@"n" mimeType:nil onReport:_report]];
  [self assertBad:[BGSFlutterReportFiles addData:[NSData data] name:@"../n" mimeType:nil onReport:_report]];
  [self assertBad:[BGSFlutterReportFiles addData:[NSData data] name:@"n" mimeType:@"bad" onReport:_report]];
  XCTAssertEqual(_report.adds.count, 0u);
}

- (void)testADeclinedByteAddIsRejected {
  _report.refuseAdds = YES;
  [self assertRefused:[BGSFlutterReportFiles addData:[NSData dataWithBytes:"x" length:1] name:@"n" mimeType:nil onReport:_report] code:BGSFlutterFileRejected];
}

- (void)testClearAttachmentsReachesTheSdk {
  [BGSFlutterReportFiles addData:[NSData dataWithBytes:"x" length:1] name:@"n" mimeType:nil onReport:_report];
  [self assertDone:[BGSFlutterReportFiles clearAttachmentsOnReport:_report]];
  XCTAssertEqual(_report.fakeAttachments.count, 0u);
  XCTAssertTrue([_report.mutations containsObject:@"clearAttachments"]);
}

#pragma mark - Screenshots

- (void)testAScreenshotIsDecodedNativelyAndStoredWithItsFlag {
  NSString *png = [self imageNamed:@"s.png" width:8 height:6];
  [self assertDone:[BGSFlutterReportFiles setScreenshotAtPath:png displayId:2 annotated:YES onReport:_report]];
  NSArray *held = _report.fakeScreenshots[@2];
  XCTAssertNotNil(held);
  XCTAssertTrue([held[0] isKindOfClass:[UIImage class]]);
  XCTAssertEqualObjects(held[1], @YES);
  [self assertDone:[BGSFlutterReportFiles setScreenshotAtPath:png displayId:0 annotated:NO onReport:_report]];
  XCTAssertEqualObjects(_report.fakeScreenshots[@0][1], @NO);
  XCTAssertEqualObjects(_report.screenshotDisplayIds, (@[ @0, @2 ]));
}

- (void)testAReplacedScreenshotLosesTheAnnotatedFlag {
  NSString *png = [self imageNamed:@"s.png" width:4 height:4];
  [BGSFlutterReportFiles setScreenshotAtPath:png displayId:0 annotated:YES onReport:_report];
  [BGSFlutterReportFiles setScreenshotAtPath:png displayId:0 annotated:NO onReport:_report];
  XCTAssertEqualObjects(_report.fakeScreenshots[@0][1], @NO);
}

- (void)testAFileThatIsNotAnImageIsUndecodableAndStoresNothing {
  [self assertRefused:[BGSFlutterReportFiles setScreenshotAtPath:_source displayId:0 annotated:NO onReport:_report] code:BGSFlutterFileImageUndecodable];
  XCTAssertEqual(_report.fakeScreenshots.count, 0u);
}

- (void)testAnImageOverThePixelCapIsRefusedBeforeItIsDecoded {
  // 4097 x 4096 gray: 16 MB of pixels to draw, and over the cap by one row.
  NSString *big = [self imageNamed:@"big.png" width:4097 height:4096];
  [self assertRefused:[BGSFlutterReportFiles setScreenshotAtPath:big displayId:0 annotated:NO onReport:_report] code:BGSFlutterFileImageTooLarge];
  XCTAssertEqual(_report.fakeScreenshots.count, 0u);
  NSString *edge = [self imageNamed:@"edge.png" width:4096 height:4096];
  [self assertDone:[BGSFlutterReportFiles setScreenshotAtPath:edge displayId:0 annotated:NO onReport:_report]];
}

- (void)testABadScreenshotPathOrDisplayIsRefusedBeforeDecoding {
  NSString *png = [self imageNamed:@"s.png" width:2 height:2];
  [self assertBad:[BGSFlutterReportFiles setScreenshotAtPath:@"x.png" displayId:0 annotated:NO onReport:_report]];
  [self assertBad:[BGSFlutterReportFiles setScreenshotAtPath:@"file:///x.png" displayId:0 annotated:NO onReport:_report]];
  [self assertBad:[BGSFlutterReportFiles setScreenshotAtPath:png displayId:-1 annotated:NO onReport:_report]];
  [self assertBad:[BGSFlutterReportFiles setScreenshotAtPath:png displayId:(int64_t)INT32_MAX + 1 annotated:NO onReport:_report]];
  [self assertRefused:[BGSFlutterReportFiles setScreenshotAtPath:[_dir stringByAppendingPathComponent:@"no.png"] displayId:0 annotated:NO onReport:_report]
                 code:BGSFlutterFileNotFound];
  XCTAssertEqual(_report.fakeScreenshots.count, 0u);
}

- (void)testRemovingAScreenshotSetsNilAndAnUnknownDisplayIsHarmless {
  NSString *png = [self imageNamed:@"s.png" width:2 height:2];
  [BGSFlutterReportFiles setScreenshotAtPath:png displayId:1 annotated:YES onReport:_report];
  [self assertDone:[BGSFlutterReportFiles removeScreenshotWithDisplayId:1 onReport:_report]];
  [self assertDone:[BGSFlutterReportFiles removeScreenshotWithDisplayId:7 onReport:_report]];
  XCTAssertEqual(_report.fakeScreenshots.count, 0u);
  [self assertBad:[BGSFlutterReportFiles removeScreenshotWithDisplayId:-1 onReport:_report]];
}

#pragma mark - read

- (void)testReadListsAttachmentMetadataAndScreenshotsAscending {
  [BGSFlutterReportFiles addFileAtPath:_source name:@"Log" mimeType:@"text/plain" move:NO onReport:_report];
  [BGSFlutterReportFiles addData:[NSData dataWithBytes:"xy" length:2] name:@"raw" mimeType:nil onReport:_report];
  NSString *png = [self imageNamed:@"s.png" width:2 height:2];
  [BGSFlutterReportFiles setScreenshotAtPath:png displayId:3 annotated:NO onReport:_report];
  [BGSFlutterReportFiles setScreenshotAtPath:png displayId:0 annotated:YES onReport:_report];
  BGSFlutterReportSnapshot *s = [BGSFlutterReportOps readReport:_report];
  XCTAssertEqualObjects(s.attachments, (@[ @[ @"Log", @"text/plain", @"app.log" ], @[ @"raw", NSNull.null, @"raw" ] ]));
  XCTAssertEqualObjects(s.screenshots, (@[ @[ @0, @YES ], @[ @3, @NO ] ]));
}

- (void)testTheBridgesFailureCodesAreTheDartOnes {
  // The Dart `ReportWire` strings, repeated; test/report_attachments_drift_test.dart compares all copies.
  XCTAssertEqualObjects(BGSFlutterFileNotLive, @"not-live");
  XCTAssertEqualObjects(BGSFlutterFileNotFound, @"file-not-found");
  XCTAssertEqualObjects(BGSFlutterFileNotAFile, @"not-a-file");
  XCTAssertEqualObjects(BGSFlutterFileUnreadable, @"unreadable");
  XCTAssertEqualObjects(BGSFlutterFileTooLarge, @"too-large");
  XCTAssertEqualObjects(BGSFlutterFileLimit, @"limit");
  XCTAssertEqualObjects(BGSFlutterFileRejected, @"rejected");
  XCTAssertEqualObjects(BGSFlutterFileBusy, @"busy");
  XCTAssertEqualObjects(BGSFlutterFileUnsupported, @"unsupported");
  XCTAssertEqualObjects(BGSFlutterFileImageUndecodable, @"image-undecodable");
  XCTAssertEqualObjects(BGSFlutterFileImageTooLarge, @"image-too-large");
  XCTAssertEqual(BGSFlutterMaxAttachmentBytes, 1024u * 1024u);
}

@end
