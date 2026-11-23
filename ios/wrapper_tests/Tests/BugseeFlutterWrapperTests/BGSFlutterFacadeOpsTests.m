#import <XCTest/XCTest.h>

#import "BGSFlutterFacadeOps.h"

@import Bugsee.SPI;

/// A fake SDK behind the seam: records every call; stores attributes like the real one (an
/// oversized string is ignored, and the call still "succeeds").
@interface BGSFakeFacadeSdk : NSObject <BGSFlutterFacadeSDK>
@property(nonatomic, strong) NSMutableArray<NSString *> *calls;
@property(nonatomic, strong) NSMutableDictionary *attributes;
@property(nonatomic) NSInteger dropStringsLongerThan;
@property(nonatomic, strong) NSException *throwsOn;
@property(nonatomic, copy) NSString *userIdentifier;
@property(nonatomic, copy) NSString *traceName;
@property(nonatomic, strong) id traceValue;
@property(nonatomic, copy) NSString *eventName;
@property(nonatomic, copy) NSDictionary *eventParams;
@property(nonatomic) BOOL eventSeen;
@property(nonatomic) NSInteger logLevel;
@property(nonatomic, copy) NSString *logMessage_;
@property(nonatomic, copy) NSArray *notify;
@property(nonatomic) NSInteger notifySeverity;
@property(nonatomic, copy) NSDictionary *notifyFields;
@property(nonatomic) BOOL notifyUrgent;
@property(nonatomic) BOOL crumbAccepted;
@property(nonatomic) BOOL running;
/// Mimics the SDK's total-size overflow: the key being overwritten is removed, then the value dropped.
@property(nonatomic) BOOL removeKeyOnReject;
@property(nonatomic) NSInteger crumbLevel;
@property(nonatomic, copy) NSDictionary *crumbData;
@property(nonatomic) BOOL blackout;
@property(nonatomic) NSInteger reportSeverity;
@property(nonatomic, copy) NSArray *reportLabels;
@property(nonatomic, copy) NSArray *reportText;
@end

@implementation BGSFakeFacadeSdk
- (instancetype)init {
  if ((self = [super init])) {
    _calls = [NSMutableArray array];
    _attributes = [NSMutableDictionary dictionary];
    _dropStringsLongerThan = NSIntegerMax;
    _crumbAccepted = YES;
    _running = YES;
  }
  return self;
}
- (void)record:(NSString *)call {
  [_calls addObject:call];
  if (_throwsOn) @throw _throwsOn;
}
- (void)setAttribute:(NSString *)name value:(id)value {
  [self record:@"setAttribute"];
  if ([value isKindOfClass:[NSString class]] && (NSInteger)[value length] > _dropStringsLongerThan) {
    if (_removeKeyOnReject) [_attributes removeObjectForKey:name];
    return;
  }
  _attributes[name] = value;
}
- (id)getAttribute:(NSString *)name {
  [self record:@"getAttribute"];
  return _attributes[name];
}
- (NSDictionary *)getAllAttributes {
  [self record:@"getAllAttributes"];
  return _attributes.count > 0 ? [_attributes copy] : nil;
}
- (void)clearAttribute:(NSString *)name {
  [self record:@"clearAttribute"];
  [_attributes removeObjectForKey:name];
}
- (void)clearAllAttributes {
  [self record:@"clearAllAttributes"];
  [_attributes removeAllObjects];
}
- (void)setUserIdentifier:(NSString *)identifier {
  [self record:@"setUserIdentifier"];
  _userIdentifier = identifier;
}
- (NSString *)getUserIdentifier {
  [self record:@"getUserIdentifier"];
  return _userIdentifier;
}
- (void)traceName:(NSString *)name value:(id)value {
  [self record:@"trace"];
  _traceName = name;
  _traceValue = value;
}
- (void)eventName:(NSString *)name params:(NSDictionary *)params {
  [self record:@"event"];
  _eventName = name;
  _eventParams = params;
  _eventSeen = YES;
}
- (void)logMessage:(NSString *)message level:(NSInteger)level {
  [self record:@"log"];
  _logMessage_ = message;
  _logLevel = level;
}
- (void)notifyTitle:(NSString *)title
               body:(NSString *)body
           severity:(NSInteger)severity
             fields:(NSDictionary *)fields
             urgent:(BOOL)urgent {
  [self record:@"notify"];
  _notify = @[ title, body ?: [NSNull null] ];
  _notifySeverity = severity;
  _notifyFields = fields;
  _notifyUrgent = urgent;
}
- (BOOL)isLaunchedOrLaunching {
  [_calls addObject:@"isLaunchedOrLaunching"];
  return _running;
}
- (BOOL)addBreadcrumbCategory:(NSString *)category
                        level:(NSInteger)level
                      message:(NSString *)message
                         type:(NSString *)type
                         data:(NSDictionary *)data {
  [self record:@"addBreadcrumb"];
  _crumbLevel = level;
  _crumbData = data;
  return _crumbAccepted;
}
- (void)startBlackout {
  [self record:@"startBlackout"];
  _blackout = YES;
}
- (void)endBlackout {
  [self record:@"endBlackout"];
  _blackout = NO;
}
- (BOOL)isBlackout {
  [self record:@"isBlackout"];
  return _blackout;
}
- (void)captureViewHierarchy {
  [self record:@"captureViewHierarchy"];
}
- (void)showReportDialogSummary:(NSString *)summary
                    description:(NSString *)description
                       severity:(NSInteger)severity
                         labels:(NSArray<NSString *> *)labels {
  [self record:@"showReportDialog"];
  _reportText = @[ summary ?: [NSNull null], description ?: [NSNull null] ];
  _reportSeverity = severity;
  _reportLabels = labels;
}
- (void)uploadSummary:(NSString *)summary
          description:(NSString *)description
             severity:(NSInteger)severity
               labels:(NSArray<NSString *> *)labels {
  [self record:@"upload"];
  _reportText = @[ summary, description ];
  _reportSeverity = severity;
  _reportLabels = labels;
}
@end

@interface BGSFlutterFacadeOpsTests : XCTestCase
@end

@implementation BGSFlutterFacadeOpsTests {
  BGSFakeFacadeSdk *_sdk;
}

- (void)setUp {
  _sdk = [[BGSFakeFacadeSdk alloc] init];
}

/// The operation failed with `code` and nothing reached the SDK.
- (void)assertInvalid:(BGSFlutterFacadeResult *)result {
  XCTAssertTrue(result.failed);
  XCTAssertEqualObjects(result.errorCode, BGSFlutterFacadeOps.invalidArgument);
  XCTAssertEqual(_sdk.calls.count, 0u, @"%@", _sdk.calls);
}

// ---- attributes -------------------------------------------------------------------------------

- (void)testEveryAcceptedAttributeTypeIsStoredAndReadBack {
  XCTAssertFalse([BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"s" value:@"text"].failed);
  XCTAssertFalse([BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"b" value:@YES].failed);
  XCTAssertFalse([BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"i" value:@7].failed);
  XCTAssertFalse([BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"d" value:@0.1].failed);
  XCTAssertEqualObjects([BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@"s"].value, @"text");
  id b = [BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@"b"].value;
  XCTAssertTrue(CFGetTypeID((__bridge CFTypeRef)b) == CFBooleanGetTypeID(), @"a bool stays a bool");
  XCTAssertEqualObjects([BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@"i"].value, @7);
  XCTAssertEqualObjects([BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@"d"].value, @0.1);
}

- (void)testAnAttributeTheSdkIgnoredIsRejectedAndTheOldValueStays {
  // SDK source: `BugseeSetAttribute` answers YES even when it ignores a value over its archive
  // limit (1124 bytes), so the read-back is the only signal.
  _sdk.dropStringsLongerThan = 3;
  XCTAssertFalse([BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:@"abc"].failed);
  BGSFlutterFacadeResult *r = [BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:@"abcd"];
  XCTAssertTrue(r.failed);
  XCTAssertEqualObjects(r.errorCode, BGSFlutterFacadeOps.attributeRejected);
  XCTAssertFalse([r.errorMessage containsString:@"abcd"], @"never the value");
  XCTAssertEqualObjects([BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@"k"].value, @"abc");
}

- (void)testARejectedOverwriteGivesTheOldValueBackWhenTheSdkRemovedIt {
  // iOS deletes the key it was overwriting when the new value overflows the total; the previous
  // value must survive the rejection (as it does on Android).
  _sdk.dropStringsLongerThan = 3;
  _sdk.removeKeyOnReject = YES;
  XCTAssertFalse([BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"cart" value:@"abc"].failed);
  BGSFlutterFacadeResult *r = [BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"cart" value:@"abcd"];
  XCTAssertEqualObjects(r.errorCode, BGSFlutterFacadeOps.attributeRejected);
  XCTAssertEqualObjects(_sdk.attributes[@"cart"], @"abc", @"the previous value is back");
  // A first value that is rejected leaves nothing behind.
  r = [BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"new" value:@"abcd"];
  XCTAssertTrue(r.failed);
  XCTAssertNil(_sdk.attributes[@"new"]);
}

- (void)testAStringOverTheLimitNeverReachesTheSdkAndTheLimitItselfIsAccepted {
  NSString *ok = [@"" stringByPaddingToLength:BGSFlutterFacadeOps.attributeStringMaxLength
                                   withString:@"x"
                              startingAtIndex:0];
  XCTAssertFalse([BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:ok].failed);
  [_sdk.calls removeAllObjects];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk
                                                          name:@"k"
                                                         value:[ok stringByAppendingString:@"x"]]];
}

- (void)testBadAttributeNamesAndValuesNeverReachTheSdk {
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"" value:@"v"]];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:nil value:@"v"]];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:@(NAN)]];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:@(INFINITY)]];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:@(3.4028234663852886e38)]];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:@[ @"a" ]]];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:@{}]];
  [self assertInvalid:[BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:[NSNull null]]];
  [self assertInvalid:[BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@""]];
  [self assertInvalid:[BGSFlutterFacadeOps clearAttributeWithSdk:_sdk name:@""]];
}

- (void)testAStoredValueDartCannotHoldReadsAsAbsentNotAsAString {
  XCTAssertNil([BGSFlutterFacadeOps dartValueFromStored:[NSDate date]]);
  XCTAssertNil([BGSFlutterFacadeOps dartValueFromStored:@{@"a" : @1}]);
  XCTAssertNil(([BGSFlutterFacadeOps dartValueFromStored:@[ @"a", @1 ]]));
  XCTAssertNil([BGSFlutterFacadeOps dartValueFromStored:@(NAN)]);
  XCTAssertNil([BGSFlutterFacadeOps dartValueFromStored:nil]);
  // ... and the read of a single attribute goes through the same filter.
  _sdk.attributes[@"date"] = [NSDate date];
  XCTAssertNil([BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@"date"].value);
  NSArray *strings = @[ @"a", @"b" ];
  XCTAssertEqualObjects([BGSFlutterFacadeOps dartValueFromStored:strings], strings);
}

- (void)testABoolIsNotTheNumberOneOnTheReadBack {
  XCTAssertTrue([BGSFlutterFacadeOps sentValue:@YES matchesStored:@YES]);
  XCTAssertFalse([BGSFlutterFacadeOps sentValue:@YES matchesStored:@1]);
  XCTAssertFalse([BGSFlutterFacadeOps sentValue:@1 matchesStored:@YES]);
  XCTAssertFalse([BGSFlutterFacadeOps sentValue:@"1" matchesStored:@1]);
  XCTAssertFalse([BGSFlutterFacadeOps sentValue:@"a" matchesStored:nil]);
}

- (void)testGetAllAttributesIsEmptyWhenTheSdkSaysNilAndSkipsWhatDartCannotHold {
  XCTAssertEqualObjects([BGSFlutterFacadeOps getAllAttributesWithSdk:_sdk].value, (@{}));
  _sdk.attributes[@"a"] = @"x";
  _sdk.attributes[@"date"] = [NSDate date];
  _sdk.attributes[@"list"] = @[ @"p", @"q" ];
  NSDictionary *all = [BGSFlutterFacadeOps getAllAttributesWithSdk:_sdk].value;
  XCTAssertEqualObjects(all, (@{@"a" : @"x", @"list" : @[ @"p", @"q" ]}));
}

- (void)testClearAttributeAndClearAllReachTheSdk {
  [BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"a" value:@"1"];
  [BGSFlutterFacadeOps clearAttributeWithSdk:_sdk name:@"a"];
  XCTAssertNil([BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@"a"].value);
  [BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"b" value:@"1"];
  [BGSFlutterFacadeOps clearAllAttributesWithSdk:_sdk];
  XCTAssertEqual(_sdk.attributes.count, 0u);
}

- (void)testAnSdkExceptionIsAFailureNeverAnEscapedException {
  // An NSException escaping into Swift is a crash, so every operation catches it.
  _sdk.throwsOn = [NSException exceptionWithName:@"BoomException" reason:@"secret user data" userInfo:nil];
  NSArray<BGSFlutterFacadeResult *> *all = @[
    [BGSFlutterFacadeOps setAttributeWithSdk:_sdk name:@"k" value:@"v"],
    [BGSFlutterFacadeOps getAttributeWithSdk:_sdk name:@"k"],
    [BGSFlutterFacadeOps getAllAttributesWithSdk:_sdk],
    [BGSFlutterFacadeOps clearAttributeWithSdk:_sdk name:@"k"],
    [BGSFlutterFacadeOps clearAllAttributesWithSdk:_sdk],
    [BGSFlutterFacadeOps setUserIdentifierWithSdk:_sdk identifier:@"u"],
    [BGSFlutterFacadeOps getUserIdentifierWithSdk:_sdk],
    [BGSFlutterFacadeOps traceWithSdk:_sdk name:@"t" value:@1],
    [BGSFlutterFacadeOps eventWithSdk:_sdk name:@"e" params:nil],
    [BGSFlutterFacadeOps logWithSdk:_sdk message:@"m" level:3],
    [BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"c" level:@"info" message:@"m" type:@"t" data:nil],
    [BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"T" body:nil severity:nil fields:nil urgent:NO],
    [BGSFlutterFacadeOps startBlackoutWithSdk:_sdk],
    [BGSFlutterFacadeOps endBlackoutWithSdk:_sdk],
    [BGSFlutterFacadeOps isBlackoutWithSdk:_sdk],
    [BGSFlutterFacadeOps captureViewHierarchyWithSdk:_sdk],
    [BGSFlutterFacadeOps showReportDialogWithSdk:_sdk summary:nil description:nil severity:nil labels:nil],
    [BGSFlutterFacadeOps uploadWithSdk:_sdk summary:@"s" description:@"d" severity:nil labels:nil],
  ];
  for (BGSFlutterFacadeResult *r in all) {
    XCTAssertTrue(r.failed);
    XCTAssertEqualObjects(r.errorCode, BGSFlutterFacadeOps.sdkError);
    XCTAssertFalse([r.errorMessage containsString:@"secret"], @"the name only, never the reason");
    XCTAssertTrue([r.errorMessage containsString:@"BoomException"]);
  }
}

// ---- user identifier --------------------------------------------------------------------------

- (void)testAnEmptyOrNilIdentifierClearsInsteadOfStoringAnEmptyString {
  [BGSFlutterFacadeOps setUserIdentifierWithSdk:_sdk identifier:@"u1"];
  XCTAssertEqualObjects([BGSFlutterFacadeOps getUserIdentifierWithSdk:_sdk].value, @"u1");
  [BGSFlutterFacadeOps setUserIdentifierWithSdk:_sdk identifier:@""];
  XCTAssertNil(_sdk.userIdentifier, @"the SDK got nil, not an empty string");
  XCTAssertNil([BGSFlutterFacadeOps getUserIdentifierWithSdk:_sdk].value);
  [BGSFlutterFacadeOps setUserIdentifierWithSdk:_sdk identifier:@"u2"];
  [BGSFlutterFacadeOps setUserIdentifierWithSdk:_sdk identifier:nil];
  XCTAssertNil(_sdk.userIdentifier);
}

- (void)testAnEmptyStoredIdentifierReadsAsNone {
  _sdk.userIdentifier = @"";
  XCTAssertNil([BGSFlutterFacadeOps getUserIdentifierWithSdk:_sdk].value);
}

// ---- events, traces, logs ---------------------------------------------------------------------

- (void)testATraceCarriesItsTypeToTheSdk {
  [BGSFlutterFacadeOps traceWithSdk:_sdk name:@"t" value:@"s"];
  XCTAssertEqualObjects(_sdk.traceValue, @"s");
  [BGSFlutterFacadeOps traceWithSdk:_sdk name:@"t" value:@YES];
  XCTAssertTrue(CFGetTypeID((__bridge CFTypeRef)_sdk.traceValue) == CFBooleanGetTypeID());
  [BGSFlutterFacadeOps traceWithSdk:_sdk name:@"t" value:@1.5];
  XCTAssertEqualObjects(_sdk.traceValue, @1.5);
  XCTAssertEqualObjects(_sdk.traceName, @"t");
}

- (void)testBadTracesNeverReachTheSdk {
  [self assertInvalid:[BGSFlutterFacadeOps traceWithSdk:_sdk name:@"" value:@1]];
  [self assertInvalid:[BGSFlutterFacadeOps traceWithSdk:_sdk name:nil value:@1]];
  [self assertInvalid:[BGSFlutterFacadeOps traceWithSdk:_sdk name:@"t" value:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps traceWithSdk:_sdk name:@"t" value:@[]]];
}

- (void)testAnEventWithoutParamsAndOneWithNestedParamsKeepingNull {
  [BGSFlutterFacadeOps eventWithSdk:_sdk name:@"e" params:nil];
  XCTAssertEqualObjects(_sdk.eventName, @"e");
  XCTAssertNil(_sdk.eventParams);
  NSDictionary *params = @{@"a" : [NSNull null], @"list" : @[ @1, @"x", [NSNull null] ], @"map" : @{@"zip" : @"1"}};
  [BGSFlutterFacadeOps eventWithSdk:_sdk name:@"e" params:params];
  XCTAssertEqualObjects(_sdk.eventParams, params);
  XCTAssertEqualObjects(_sdk.eventParams[@"a"], [NSNull null], @"a null member stays null");
}

- (void)testBadEventsNeverReachTheSdk {
  [self assertInvalid:[BGSFlutterFacadeOps eventWithSdk:_sdk name:@"" params:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps eventWithSdk:_sdk name:nil params:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps eventWithSdk:_sdk name:@"e" params:@{@1 : @"x"}]];
  [self assertInvalid:[BGSFlutterFacadeOps eventWithSdk:_sdk name:@"e" params:@[ @1 ]]];
}

- (void)testLogCrossesByTheSdksLevelValueNeverTheOrdinal {
  XCTAssertEqual(BugseeLogLevelError, 1);
  XCTAssertEqual(BugseeLogLevelWarning, 2);
  XCTAssertEqual(BugseeLogLevelInfo, 3);
  XCTAssertEqual(BugseeLogLevelDebug, 4);
  XCTAssertEqual(BugseeLogLevelVerbose, 5);
  for (int64_t level = 1; level <= 5; level++) {
    [BGSFlutterFacadeOps logWithSdk:_sdk message:@"m" level:level];
    XCTAssertEqual(_sdk.logLevel, level);
  }
  XCTAssertEqualObjects(_sdk.logMessage_, @"m");
}

- (void)testALogLevelTheSdkDoesNotHaveIsRefused {
  for (NSNumber *bad in @[ @0, @-1, @6, @99, @(INT64_MAX), @(INT64_MIN) ]) {
    [self assertInvalid:[BGSFlutterFacadeOps logWithSdk:_sdk message:@"m" level:bad.longLongValue]];
  }
  [self assertInvalid:[BGSFlutterFacadeOps logWithSdk:_sdk message:nil level:3]];
}

// ---- breadcrumbs, notifications ---------------------------------------------------------------

- (void)testBreadcrumbLevelNamesMapToTheSdksLevelsAndFatalIsError {
  XCTAssertEqual([BGSFlutterFacadeOps breadcrumbLevelForName:@"debug"], BugseeLogLevelDebug);
  XCTAssertEqual([BGSFlutterFacadeOps breadcrumbLevelForName:@"info"], BugseeLogLevelInfo);
  XCTAssertEqual([BGSFlutterFacadeOps breadcrumbLevelForName:@"warning"], BugseeLogLevelWarning);
  XCTAssertEqual([BGSFlutterFacadeOps breadcrumbLevelForName:@"error"], BugseeLogLevelError);
  // iOS has no fatal rung; the bundle records it as error.
  XCTAssertEqual([BGSFlutterFacadeOps breadcrumbLevelForName:@"fatal"], BugseeLogLevelError);
  XCTAssertEqual([BGSFlutterFacadeOps breadcrumbLevelForName:@"verbose"], -1);
  XCTAssertEqual([BGSFlutterFacadeOps breadcrumbLevelForName:@"3"], -1);
  XCTAssertEqual([BGSFlutterFacadeOps breadcrumbLevelForName:nil], -1);
}

- (void)testABreadcrumbReportsWhetherTheSdkTookIt {
  BGSFlutterFacadeResult *r = [BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"nav" level:@"warning" message:@"m" type:@"t" data:nil];
  XCTAssertEqualObjects(r.value, @YES);
  XCTAssertEqual(_sdk.crumbLevel, BugseeLogLevelWarning);
  XCTAssertNil(_sdk.crumbData, @"no data stays unset");
  _sdk.crumbAccepted = NO;
  r = [BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"nav" level:@"info" message:@"m" type:@"t" data:@{@"k" : @"v"}];
  XCTAssertFalse([r.value boolValue]);
  XCTAssertEqualObjects(_sdk.crumbData[@"k"], @"v");
}

- (void)testABreadcrumbIsNotHandedOverWhenTheSdkIsNotRunning {
  // iOS +addBreadcrumb: has no launch gate; after stop (or before launch) nothing would record it.
  _sdk.running = NO;
  BGSFlutterFacadeResult *r = [BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"c" level:@"info" message:@"m" type:@"t" data:nil];
  XCTAssertEqualObjects(r.value, @NO);
  XCTAssertFalse([_sdk.calls containsObject:@"addBreadcrumb"]);
  _sdk.running = YES;
  XCTAssertEqualObjects([BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"c" level:@"info" message:@"m" type:@"t" data:nil].value, @YES);
}

- (void)testBadBreadcrumbsNeverReachTheSdk {
  [self assertInvalid:[BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"c" level:@"loud" message:@"m" type:@"t" data:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:nil level:@"info" message:@"m" type:@"t" data:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"c" level:@"info" message:nil type:@"t" data:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"c" level:@"info" message:@"m" type:nil data:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps addBreadcrumbWithSdk:_sdk category:@"c" level:@"info" message:@"m" type:@"t" data:@{@1 : @2}]];
}

- (void)testANotificationMapsTheSeverityByValueAndBuildsTheFields {
  [BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"T" body:@"B" severity:@4 fields:@[ @"z", @"1", @"a", @"2" ] urgent:YES];
  XCTAssertEqualObjects(_sdk.notify, (@[ @"T", @"B" ]));
  XCTAssertEqual(_sdk.notifySeverity, BugseeSeverityCritical);
  XCTAssertEqualObjects(_sdk.notifyFields, (@{@"z" : @"1", @"a" : @"2"}));
  XCTAssertTrue(_sdk.notifyUrgent);
  [BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"T" body:nil severity:nil fields:nil urgent:NO];
  XCTAssertEqual(_sdk.notifySeverity, 0, @"0 is the SDK's unset");
  XCTAssertNil(_sdk.notifyFields);
  XCTAssertFalse(_sdk.notifyUrgent);
}

- (void)testBadNotificationsNeverReachTheSdk {
  [self assertInvalid:[BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"" body:nil severity:nil fields:nil urgent:NO]];
  [self assertInvalid:[BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"  " body:nil severity:nil fields:nil urgent:NO]];
  [self assertInvalid:[BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:nil body:nil severity:nil fields:nil urgent:NO]];
  [self assertInvalid:[BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"T" body:nil severity:@0 fields:nil urgent:NO]];
  [self assertInvalid:[BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"T" body:nil severity:@6 fields:nil urgent:NO]];
  [self assertInvalid:[BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"T" body:nil severity:nil fields:@[ @"k" ] urgent:NO]];
  [self assertInvalid:[BGSFlutterFacadeOps relayNotificationWithSdk:_sdk title:@"T" body:nil severity:nil fields:@[ @"k", @1 ] urgent:NO]];
}

// ---- view hierarchy ---------------------------------------------------------------------------

- (void)testCaptureViewHierarchyIsPassedStraightToTheSdk {
  // SDK source (BGSCaptureDataProviderViewHierarchy.m): a pass only while its provider runs; the
  // wrapper adds nothing and has no launch gate of its own.
  BGSFlutterFacadeResult *result = [BGSFlutterFacadeOps captureViewHierarchyWithSdk:_sdk];
  XCTAssertFalse(result.failed);
  XCTAssertEqualObjects(_sdk.calls, (@[ @"captureViewHierarchy" ]));
}

// ---- blackout ---------------------------------------------------------------------------------

- (void)testBlackoutIsPassedThroughAndReadBackFromTheSdk {
  // SDK source (Bugsee.m startBlackout): deliberately NOT gated on launch; the flag is read live
  // when a recording starts. The wrapper adds nothing.
  XCTAssertEqualObjects([BGSFlutterFacadeOps isBlackoutWithSdk:_sdk].value, @NO);
  [BGSFlutterFacadeOps startBlackoutWithSdk:_sdk];
  XCTAssertEqualObjects([BGSFlutterFacadeOps isBlackoutWithSdk:_sdk].value, @YES);
  [BGSFlutterFacadeOps endBlackoutWithSdk:_sdk];
  XCTAssertEqualObjects([BGSFlutterFacadeOps isBlackoutWithSdk:_sdk].value, @NO);
  NSArray *expected = @[ @"isBlackout", @"startBlackout", @"isBlackout", @"endBlackout", @"isBlackout" ];
  XCTAssertEqualObjects(_sdk.calls, expected);
}

// ---- reports ----------------------------------------------------------------------------------

- (void)testUploadAndTheDialogMapSeverityByValueAndKeepUnsetAsZero {
  XCTAssertEqual(BugseeSeverityBlocker, 5);
  [BGSFlutterFacadeOps uploadWithSdk:_sdk summary:@"s" description:@"d" severity:@5 labels:@[ @"x", @"y" ]];
  XCTAssertEqual(_sdk.reportSeverity, BugseeSeverityBlocker);
  XCTAssertEqualObjects(_sdk.reportLabels, (@[ @"x", @"y" ]));
  [BGSFlutterFacadeOps uploadWithSdk:_sdk summary:@"s" description:@"d" severity:nil labels:nil];
  XCTAssertEqual(_sdk.reportSeverity, 0, @"0 lets the real facade pick the SDK's two-argument form");
  XCTAssertNil(_sdk.reportLabels);
  [BGSFlutterFacadeOps showReportDialogWithSdk:_sdk summary:nil description:nil severity:nil labels:nil];
  XCTAssertEqualObjects(_sdk.reportText[0], [NSNull null]);
  [BGSFlutterFacadeOps showReportDialogWithSdk:_sdk summary:@"s" description:@"d" severity:@1 labels:@[ @"l" ]];
  XCTAssertEqual(_sdk.reportSeverity, BugseeSeverityLow);
}

- (void)testBadReportArgumentsNeverReachTheSdk {
  [self assertInvalid:[BGSFlutterFacadeOps uploadWithSdk:_sdk summary:nil description:@"d" severity:nil labels:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps uploadWithSdk:_sdk summary:@"s" description:nil severity:nil labels:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps uploadWithSdk:_sdk summary:@"s" description:@"d" severity:@0 labels:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps uploadWithSdk:_sdk summary:@"s" description:@"d" severity:@6 labels:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps uploadWithSdk:_sdk summary:@"s" description:@"d" severity:nil labels:@[ @"ok", @1 ]]];
  [self assertInvalid:[BGSFlutterFacadeOps showReportDialogWithSdk:_sdk summary:@"s" description:@"d" severity:@9 labels:nil]];
  [self assertInvalid:[BGSFlutterFacadeOps showReportDialogWithSdk:_sdk summary:@"s" description:@"d" severity:nil labels:@[ [NSNull null] ]]];
}

@end
