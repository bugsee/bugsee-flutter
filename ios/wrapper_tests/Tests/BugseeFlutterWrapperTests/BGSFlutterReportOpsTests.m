#import <XCTest/XCTest.h>

#import "BGSFlutterFakeReport.h"
#import "BGSFlutterReportOps.h"

@interface BGSFlutterReportOpsTests : XCTestCase
@end

@implementation BGSFlutterReportOpsTests {
  BGSFlutterFakeReport *_report;
}

- (void)setUp {
  _report = [[BGSFlutterFakeReport alloc] init];
}

- (void)assertRefused:(BOOL (^)(NSError **error))change {
  NSError *error = nil;
  XCTAssertFalse(change(&error));
  XCTAssertNotNil(error);
  XCTAssertEqualObjects(error.domain, BGSFlutterReportOpsErrorDomain);
  XCTAssertEqualObjects(_report.mutations, (@[]), @"a refused change touches nothing");
}

- (void)testSeverityCrossesByValue {
  for (int64_t wire = 1; wire <= 5; wire++) {
    NSError *error = nil;
    XCTAssertTrue([BGSFlutterReportOps setSeverity:wire onReport:_report error:&error]);
    XCTAssertEqual((int64_t)_report.fakeSeverity, wire);
  }
  [BGSFlutterReportOps setSeverity:4 onReport:_report error:NULL];
  XCTAssertEqual(_report.fakeSeverity, BugseeSeverityCritical);
}

/// The SDK's setter ignores these and keeps the old value, silently: success from its point of
/// view, which would look like an applied edit from ours.
- (void)testSeverityOutsideTheSdkRangeIsRefusedNotSilentlyIgnored {
  _report.fakeSeverity = BugseeSeverityHigh;
  for (NSNumber *wire in @[ @0, @-1, @6, @100, @(INT64_MAX), @(INT64_MIN) ]) {
    [self assertRefused:^BOOL(NSError **error) {
      return [BGSFlutterReportOps setSeverity:wire.longLongValue onReport:self->_report error:error];
    }];
  }
  XCTAssertEqual(_report.fakeSeverity, BugseeSeverityHigh);
}

/// Compared with the SDK's own enum (the shipped header of the pinned version), not a copy.
- (void)testSeverityRangeIsExactlyTheSdksValues {
  XCTAssertEqual(BugseeSeverityLow, 1);
  XCTAssertEqual(BugseeSeverityMedium, 2);
  XCTAssertEqual(BugseeSeverityHigh, 3);
  XCTAssertEqual(BugseeSeverityCritical, 4);
  XCTAssertEqual(BugseeSeverityBlocker, 5);
  XCTAssertEqual([BGSFlutterReportOps minSeverity], (NSInteger)BugseeSeverityLow);
  XCTAssertEqual([BGSFlutterReportOps maxSeverity], (NSInteger)BugseeSeverityBlocker);
}

/// The fixture is extracted from the SDKs' SOURCE (`scripts/extract_report_enums.dart`); this
/// compares it with the enum the pinned framework actually compiles, so a stale fixture or a
/// renumbered SDK is seen. By value, never by ordinal or name (workbook 7.4.2, 7.4.3).
- (void)testTheFixtureIsTheSdksRealEnum {
  NSString *path = [[[@(__FILE__) stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"../../../../test/fixtures/report_enums.json"]
      stringByStandardizingPath];
  NSData *data = [NSData dataWithContentsOfFile:path];
  XCTAssertNotNil(data, @"%@", path);
  NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  NSDictionary *severity = fixture[@"ios"][@"BugseeSeverityLevel"];
  XCTAssertEqualObjects(severity, (@{
    @"BugseeSeverityLow" : @(BugseeSeverityLow),
    @"BugseeSeverityMedium" : @(BugseeSeverityMedium),
    @"BugseeSeverityHigh" : @(BugseeSeverityHigh),
    @"BugseeSeverityCritical" : @(BugseeSeverityCritical),
    @"BugseeSeverityBlocker" : @(BugseeSeverityBlocker),
  }));
  // The iOS type strings the fixture records are what a real report states.
  BGSFlutterFakeReport *r = [[BGSFlutterFakeReport alloc] init];
  NSMutableArray *types = [NSMutableArray array];
  for (NSString *t in fixture[@"ios"][@"issueTypeStrings"]) {
    r.fakeType = t;
    [types addObject:[BGSFlutterReportOps typeOfReport:r]];
  }
  XCTAssertEqualObjects(types, (@[ @"bug", @"crash", @"error" ]));
}

- (void)testANeverSetSeverityReadsAsNilNotALevel {
  _report.fakeSeverity = (BugseeSeverityLevel)0;
  XCTAssertNil([BGSFlutterReportOps readReport:_report].severity);
  _report.fakeSeverity = BugseeSeverityBlocker;
  XCTAssertEqualObjects([BGSFlutterReportOps readReport:_report].severity, @5);
}

- (void)testReplacingLabelsIsOneAtomicCall {
  [_report.fakeLabels addObject:@"old"];
  XCTAssertTrue(([BGSFlutterReportOps replaceLabels:@[ @"a", @"b" ] onReport:_report error:NULL]));
  XCTAssertEqualObjects(_report.fakeLabels, (@[ @"a", @"b" ]));
  // clear-then-add would expose a label-less report between the two calls.
  XCTAssertEqualObjects(_report.mutations, (@[ @"replaceLabels:" ]));
}

- (void)testAListThatIsNotAllStringsChangesNothing {
  [_report.fakeLabels addObject:@"keep"];
  [self assertRefused:^BOOL(NSError **e) { return [BGSFlutterReportOps replaceLabels:@[ @"a", @3 ] onReport:self->_report error:e]; }];
  [self assertRefused:^BOOL(NSError **e) { return [BGSFlutterReportOps replaceLabels:@[ @"a", NSNull.null ] onReport:self->_report error:e]; }];
  [self assertRefused:^BOOL(NSError **e) { return [BGSFlutterReportOps addLabels:@[ @1.5 ] onReport:self->_report error:e]; }];
  [self assertRefused:^BOOL(NSError **e) { return [BGSFlutterReportOps replaceLabels:nil onReport:self->_report error:e]; }];
  XCTAssertEqualObjects(_report.fakeLabels, (@[ @"keep" ]));
}

- (void)testAttributesTakeOnlyWhatBothSdksCarry {
  for (id value in @[ @"text", @YES, @7, @(7000000000LL), @1.5 ]) {
    XCTAssertTrue([BGSFlutterReportOps setAttribute:value name:@"k" onReport:_report error:NULL]);
  }
  XCTAssertEqual(_report.mutations.count, 5u);
  [_report.mutations removeAllObjects];
  for (id bad in @[ @(NAN), @(INFINITY), @[ @"x" ], @{@"a" : @1}, NSNull.null, [NSObject new], [NSSet setWithObject:@"x"] ]) {
    [self assertRefused:^BOOL(NSError **e) { return [BGSFlutterReportOps setAttribute:bad name:@"k" onReport:self->_report error:e]; }];
  }
  [self assertRefused:^BOOL(NSError **e) { return [BGSFlutterReportOps setAttribute:@"v" name:@"" onReport:self->_report error:e]; }];
  [self assertRefused:^BOOL(NSError **e) { return [BGSFlutterReportOps setAttribute:@"v" name:nil onReport:self->_report error:e]; }];
  [self assertRefused:^BOOL(NSError **e) { return [BGSFlutterReportOps setAttribute:nil name:@"k" onReport:self->_report error:e]; }];
}

/// Dart's bool arrives as a boolean NSNumber; it must stay a bool, not become 1.
- (void)testABoolIsKeptAsABool {
  [BGSFlutterReportOps setAttribute:@YES name:@"b" onReport:_report error:NULL];
  XCTAssertTrue([BGSFlutterReportOps isAllowedAttributeValue:@YES]);
  XCTAssertTrue([BGSFlutterReportOps isAllowedAttributeValue:@0]);
  XCTAssertEqual(CFGetTypeID((__bridge CFTypeRef)_report.fakeAttributes[@"b"]), CFBooleanGetTypeID());
}

- (void)testReadReturnsTheLiveReportAndLeavesUnsupportedAttributesOut {
  _report.fakeSummary = @"s";
  _report.fakeDescription = @"d";
  _report.fakeEmail = @"e@x";
  _report.fakeSeverity = BugseeSeverityBlocker;
  [_report.fakeLabels addObjectsFromArray:@[ @"l1", @"l2" ]];
  _report.fakeAttributes[@"ok"] = @"v";
  _report.fakeAttributes[@"set"] = [NSSet setWithObject:@"a"];
  _report.fakeAttributes[@"nan"] = @(NAN);
  _report.fakeType = @"crash";
  BGSFlutterReportSnapshot *s = [BGSFlutterReportOps readReport:_report];
  XCTAssertEqualObjects(s.reportId, @"report-1");
  XCTAssertEqualObjects(s.type, @"crash");
  XCTAssertEqualObjects(s.summary, @"s");
  XCTAssertEqualObjects(s.reportDescription, @"d");
  XCTAssertEqualObjects(s.email, @"e@x");
  XCTAssertEqualObjects(s.severity, @5);
  XCTAssertEqualObjects(s.labels, (@[ @"l1", @"l2" ]));
  XCTAssertEqualObjects(s.attributes, (@{@"ok" : @"v"}));
}

- (void)testSimpleFieldsPassThrough {
  [BGSFlutterReportOps setSummary:@"s" onReport:_report];
  [BGSFlutterReportOps setDescription:@"d" onReport:_report];
  [BGSFlutterReportOps setEmail:@"e" onReport:_report];
  [BGSFlutterReportOps setSummary:nil onReport:_report];
  XCTAssertNil(_report.fakeSummary);
  XCTAssertEqualObjects(_report.fakeDescription, @"d");
  XCTAssertEqualObjects(_report.fakeEmail, @"e");
  [BGSFlutterReportOps clearLabelsOnReport:_report];
  [BGSFlutterReportOps removeAttribute:@"x" onReport:_report];
  [BGSFlutterReportOps clearAttributesOnReport:_report];
}

@end
