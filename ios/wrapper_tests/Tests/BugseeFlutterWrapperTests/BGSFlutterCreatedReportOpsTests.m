#import <XCTest/XCTest.h>

@import Bugsee;

#import "BGSFlutterCreatedReportOps.h"

/// On a real `BugseeExtendedReport` (what `+[Bugsee createReportWithCompletion:]` hands out).
@interface BGSFlutterCreatedReportOpsTests : XCTestCase
@end

@implementation BGSFlutterCreatedReportOpsTests {
  BugseeExtendedReport *_report;
  NSString *_dir;
}

- (void)setUp {
  _report = [BugseeExtendedReport new];
  _dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  [NSFileManager.defaultManager createDirectoryAtPath:_dir withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown {
  [NSFileManager.defaultManager removeItemAtPath:_dir error:NULL];
}

- (NSString *)fileOfSize:(NSUInteger)size named:(NSString *)name {
  NSString *path = [_dir stringByAppendingPathComponent:name];
  [[NSMutableData dataWithLength:size] writeToFile:path atomically:YES];
  return path;
}

- (UIImage *)onePixel {
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1, 1)];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [[UIColor redColor] setFill];
    [context fillRect:CGRectMake(0, 0, 1, 1)];
  }];
}

- (void)testReadsTheFields {
  [_report setSummary:@"sum"];
  [_report setDescription:@"desc"];
  [_report setSeverity:BugseeSeverityCritical];
  _report.labels = @[ @"a", @"b" ];
  [_report setAttribute:@"k" withValue:@"v"];
  [_report setScreenshot:[self onePixel]];
  [_report setAttachment:[BugseeAttachment attachmentWithName:@"note.txt" filename:@"note.txt" data:[@"hi" dataUsingEncoding:NSUTF8StringEncoding]]];
  BGSFlutterCreatedReportSnapshot *s = [BGSFlutterCreatedReportOps readReport:_report];
  XCTAssertEqualObjects(s.summary, @"sum");
  XCTAssertEqualObjects(s.reportDescription, @"desc");
  XCTAssertEqualObjects(s.severity, @4);
  XCTAssertEqualObjects(s.labels, (@[ @"a", @"b" ]));
  XCTAssertEqualObjects(s.attributes, @{@"k" : @"v"});
  XCTAssertEqualObjects(s.attachmentNames, @[ @"note.txt" ]);
  XCTAssertEqualObjects(s.screenshotDisplayIds, @[ @0 ]);
}

- (void)testAnEmptyReportHasNoScreenshotDisplays {
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps readReport:_report].screenshotDisplayIds, @[]);
}

- (void)testASummaryOfNilClearsItAndAnAbsentOneLeavesIt {
  [_report setSummary:@"old"];
  [_report setDescription:@"old d"];
  BGSFlutterCreatedReportPatch *p = [BGSFlutterCreatedReportPatch new];
  p.setSummary = YES;
  XCTAssertNil([BGSFlutterCreatedReportOps applyPatch:p toReport:_report]);
  XCTAssertNil(_report.summary);
  XCTAssertEqualObjects(_report.reportDescription, @"old d");
}

- (void)testSeverityByValueAndLabelsReplaced {
  _report.labels = @[ @"old" ];
  BGSFlutterCreatedReportPatch *p = [BGSFlutterCreatedReportPatch new];
  p.severity = @4;
  p.labels = @[ @"a", @"b" ];
  XCTAssertNil([BGSFlutterCreatedReportOps applyPatch:p toReport:_report]);
  XCTAssertEqual(_report.severity, BugseeSeverityCritical);
  XCTAssertEqualObjects(_report.labels, (@[ @"a", @"b" ]));
}

/// A patch that would change the summary, plus one field of the kind being tested.
- (BGSFlutterCreatedReportPatch *)patchWithSummaryPlus:(void (^)(BGSFlutterCreatedReportPatch *p))mutate {
  BGSFlutterCreatedReportPatch *p = [BGSFlutterCreatedReportPatch new];
  p.setSummary = YES;
  p.summary = @"new";
  mutate(p);
  return p;
}

- (void)testOneBadFieldChangesNothingAtAll {
  [_report setSummary:@"old"];
  _report.labels = @[ @"keep" ];
  [_report setAttribute:@"k" withValue:@"v"];
  NSArray<BGSFlutterCreatedReportPatch *> *bad = @[
    [self patchWithSummaryPlus:^(BGSFlutterCreatedReportPatch *p) { p.severity = @9; }],
    [self patchWithSummaryPlus:^(BGSFlutterCreatedReportPatch *p) { p.labels = @[ @"ok", @3 ]; }],
    [self patchWithSummaryPlus:^(BGSFlutterCreatedReportPatch *p) { p.attributes = @{@"fine" : @1, @"bad" : @(NAN)}; }],
    [self patchWithSummaryPlus:^(BGSFlutterCreatedReportPatch *p) { p.removeAttributes = @[ @"x", @"" ]; }],
  ];
  for (BGSFlutterCreatedReportPatch *p in bad) {
    XCTAssertNotNil([BGSFlutterCreatedReportOps applyPatch:p toReport:_report]);
    XCTAssertEqualObjects(_report.summary, @"old");
    XCTAssertEqualObjects(_report.labels, (@[ @"keep" ]));
    XCTAssertEqualObjects(_report.attributes[@"k"], @"v");
  }
}

- (void)testAttributesAreClearedThenSetThenRemoved {
  [_report setAttribute:@"old" withValue:@"x"];
  [_report setAttribute:@"gone" withValue:@"y"];
  BGSFlutterCreatedReportPatch *p = [BGSFlutterCreatedReportPatch new];
  p.clearAttributes = YES;
  p.attributes = @{@"a" : @1, @"b" : @"two", @"gone" : @YES};
  p.removeAttributes = @[ @"gone" ];
  XCTAssertNil([BGSFlutterCreatedReportOps applyPatch:p toReport:_report]);
  XCTAssertEqualObjects(_report.attributes, (@{@"a" : @1, @"b" : @"two"}));
}

#pragma mark - Attachments (the legacy rules)

- (void)testAFileIsCopiedIntoMemoryWithItsBaseNameAndTheSourceIsLeftAlone {
  NSString *path = [self fileOfSize:5 named:@"data.bin"];
  BGSFlutterFileOutcome *o = [BGSFlutterCreatedReportOps addFileAtPath:path name:@"Data" mimeType:@"application/octet-stream" onReport:_report];
  XCTAssertNil(o.code);
  XCTAssertNil(o.argumentError);
  BugseeAttachment *a = _report.attachments.firstObject;
  XCTAssertEqualObjects(a.name, @"Data");
  XCTAssertEqualObjects(a.filename, @"data.bin");
  XCTAssertEqual(a.data.length, 5u);
  // The app's file may change; what the report will upload must not.
  [@"changed!!" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
  XCTAssertEqual(a.data.length, 5u);
  XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testTheThreeAttachmentLimitIsNamedNotSilentlyDropped {
  for (int i = 0; i < 3; i++) {
    NSString *name = [NSString stringWithFormat:@"n%d", i];
    BGSFlutterFileOutcome *outcome = [BGSFlutterCreatedReportOps addData:[NSData dataWithBytes:"x" length:1]
                                                                    name:name
                                                                mimeType:nil
                                                                onReport:_report];
    XCTAssertNil(outcome.code);
  }
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addData:[NSData dataWithBytes:"x" length:1] name:@"4th" mimeType:nil onReport:_report].code,
                        BGSFlutterFileLimit);
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addFileAtPath:[self fileOfSize:1 named:@"f"] name:@"4th" mimeType:nil onReport:_report].code,
                        BGSFlutterFileLimit);
  XCTAssertEqual(_report.attachments.count, 3u);
  XCTAssertEqual(BGSFlutterCreatedReportMaxAttachments, 3u);
}

- (void)testTheThreeMebibyteLimitIsNamedAndEmptyIsRefused {
  XCTAssertEqual(BGSFlutterCreatedReportMaxAttachmentBytes, 3u * 1024u * 1024u);
  NSString *max = [self fileOfSize:BGSFlutterCreatedReportMaxAttachmentBytes named:@"max"];
  NSString *over = [self fileOfSize:BGSFlutterCreatedReportMaxAttachmentBytes + 1 named:@"over"];
  NSString *empty = [self fileOfSize:0 named:@"empty"];
  XCTAssertNil([BGSFlutterCreatedReportOps addFileAtPath:max name:@"max" mimeType:nil onReport:_report].code);
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addFileAtPath:over name:@"over" mimeType:nil onReport:_report].code, BGSFlutterFileTooLarge);
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addFileAtPath:empty name:@"empty" mimeType:nil onReport:_report].code, BGSFlutterFileTooLarge,
                        @"iOS drops empty data at upload, so it is refused here");
  XCTAssertEqual(_report.attachments.count, 1u);
}

- (void)testASizeCheckFollowsALinkToItsTarget {
  NSString *big = [self fileOfSize:BGSFlutterCreatedReportMaxAttachmentBytes + 1 named:@"big"];
  NSString *link = [_dir stringByAppendingPathComponent:@"link"];
  [NSFileManager.defaultManager createSymbolicLinkAtPath:link withDestinationPath:big error:NULL];
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addFileAtPath:link name:@"l" mimeType:nil onReport:_report].code, BGSFlutterFileTooLarge,
                        @"a short link must not admit a target over the limit");
}

- (void)testMissingDirectoryAndBadArgumentsAreNamedBeforeAnythingIsRead {
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addFileAtPath:[_dir stringByAppendingPathComponent:@"nope"] name:@"n" mimeType:nil onReport:_report].code,
                        BGSFlutterFileNotFound);
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addFileAtPath:_dir name:@"n" mimeType:nil onReport:_report].code, BGSFlutterFileNotAFile);
  XCTAssertNotNil([BGSFlutterCreatedReportOps addFileAtPath:@"relative" name:@"n" mimeType:nil onReport:_report].argumentError);
  XCTAssertNotNil([BGSFlutterCreatedReportOps addFileAtPath:[self fileOfSize:1 named:@"f"] name:@"../n" mimeType:nil onReport:_report].argumentError);
  XCTAssertNotNil([BGSFlutterCreatedReportOps addFileAtPath:[self fileOfSize:1 named:@"g"] name:@"n" mimeType:@"bad" onReport:_report].argumentError);
  XCTAssertEqual(_report.attachments.count, 0u);
}

- (void)testBytesUpToTheCapAreAttachedWithTheNameAsFileName {
  XCTAssertNil([BGSFlutterCreatedReportOps addData:[NSData dataWithBytes:"abc" length:3] name:@"b.txt" mimeType:@"text/plain" onReport:_report].code);
  XCTAssertEqualObjects(_report.attachments.firstObject.filename, @"b.txt");
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addData:[NSMutableData dataWithLength:BGSFlutterMaxAttachmentBytes + 1] name:@"big" mimeType:nil onReport:_report].code,
                        BGSFlutterFileTooLarge);
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps addData:[NSData data] name:@"empty" mimeType:nil onReport:_report].code, BGSFlutterFileTooLarge);
  XCTAssertNotNil([BGSFlutterCreatedReportOps addData:nil name:@"n" mimeType:nil onReport:_report].argumentError);
}

- (void)testClearRemovesEveryAttachment {
  [BGSFlutterCreatedReportOps addData:[NSData dataWithBytes:"x" length:1] name:@"a" mimeType:nil onReport:_report];
  XCTAssertNil([BGSFlutterCreatedReportOps clearAttachmentsOnReport:_report].code);
  XCTAssertEqual(_report.attachments.count, 0u);
}

#pragma mark - Screenshot

- (void)testAScreenshotFileReplacesTheReportsAndAnAnnotatedOneIsUnsupported {
  NSString *png = [_dir stringByAppendingPathComponent:@"s.png"];
  [UIImagePNGRepresentation([self onePixel]) writeToFile:png atomically:YES];
  XCTAssertNil([BGSFlutterCreatedReportOps setScreenshotAtPath:png annotated:NO onReport:_report].code);
  XCTAssertNotNil(_report.screenshot);
  BugseeExtendedReport *fresh = [BugseeExtendedReport new];
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps setScreenshotAtPath:png annotated:YES onReport:fresh].code, BGSFlutterFileUnsupported);
  XCTAssertNil(fresh.screenshot, @"an unsupported request changes nothing");
}

- (void)testScreenshotFailuresAreNamed {
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps setScreenshotAtPath:[self fileOfSize:4 named:@"junk.png"] annotated:NO onReport:_report].code,
                        BGSFlutterFileImageUndecodable);
  XCTAssertEqualObjects([BGSFlutterCreatedReportOps setScreenshotAtPath:[_dir stringByAppendingPathComponent:@"no.png"] annotated:NO onReport:_report].code,
                        BGSFlutterFileNotFound);
  XCTAssertNotNil([BGSFlutterCreatedReportOps setScreenshotAtPath:@"x.png" annotated:NO onReport:_report].argumentError);
  XCTAssertNil(_report.screenshot);
}

@end
