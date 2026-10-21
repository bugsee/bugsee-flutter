#import <XCTest/XCTest.h>

#import "BGSFlutterLaunchOps.h"

@import Bugsee;

/// A fake SDK behind the seam: records what reaches it and answers as scripted.
@interface BGSFakeBugsee : NSObject <BGSFlutterBugseeSDK>
@property(nonatomic, copy) NSString *status;
/// What `started:` is told; nil = never called.
@property(nonatomic, strong) NSNumber *startedWith;
/// The status the SDK is in when it calls `started:`.
@property(nonatomic, copy) NSString *statusAtStarted;
@property(nonatomic, strong) NSException *launchThrows;
@property(nonatomic, strong) NSException *stopThrows;
@property(nonatomic, strong) NSMutableArray<NSString *> *launches;
@property(nonatomic, copy) NSDictionary *launchedWith;
@property(nonatomic) NSInteger stops;
@property(nonatomic, strong) NSDictionary *options;
@property(nonatomic, strong) NSNumber *lastHostOnly;
@end

@implementation BGSFakeBugsee
- (instancetype)init {
  if ((self = [super init])) {
    _status = @"stopped";
    _startedWith = @YES;
    _statusAtStarted = @"launched";
    _launches = [NSMutableArray array];
    _options = @{};
  }
  return self;
}
- (NSString *)statusName {
  return _status;
}
- (void)launchWithToken:(NSString *)token
                options:(NSDictionary<NSString *, id> *)options
                started:(void (^)(BOOL))started {
  if (_launchThrows) @throw _launchThrows;
  [_launches addObject:token];
  _launchedWith = options;
  if (_startedWith) {
    _status = _statusAtStarted;
    started(_startedWith.boolValue);
  }
}
- (void)stop:(void (^)(void))done {
  if (_stopThrows) @throw _stopThrows;
  _stops++;
  done();
}
- (NSDictionary<NSString *, id> *)launchOptionsHostOnly:(BOOL)hostOnly {
  _lastHostOnly = @(hostOnly);
  return _options;
}
@end

@interface BGSFlutterLaunchOpsTests : XCTestCase
@end

@implementation BGSFlutterLaunchOpsTests

/// What a launch answered: @[outcome, reason] or @[NSNull, NSNull, error].
- (NSArray *)launch:(BGSFakeBugsee *)sdk token:(NSString *)token options:(NSDictionary *)options {
  __block NSArray *answer = nil;
  __block NSInteger calls = 0;
  [BGSFlutterLaunchOps launchWithSdk:sdk
                               token:token
                             options:options
                          completion:^(NSString *outcome, NSString *reason, NSError *error) {
                            calls++;
                            answer = @[ outcome ?: [NSNull null], reason ?: [NSNull null], error ?: [NSNull null] ];
                          }];
  XCTAssertEqual(calls, 1, @"answered exactly once");
  return answer;
}

- (void)testAStoppedSdkLaunchesWithTheOptionsAsDartSentThemAndAnswersLaunched {
  BGSFakeBugsee *sdk = [[BGSFakeBugsee alloc] init];
  NSArray *a = [self launch:sdk
                      token:@"tok"
                    options:@{
                      @"com.bugsee.option.capture.logs.level" : @2,
                      @"com.bugsee.option.capture.video.scale" : @0.5,
                      @"com.bugsee.option.capture.logs" : @NO,
                    }];
  XCTAssertEqualObjects(a[0], BGSFlutterLaunchOps.launched);
  XCTAssertEqualObjects(sdk.launches, (@[ @"tok" ]));
  XCTAssertEqualObjects(sdk.launchedWith[@"com.bugsee.option.capture.logs.level"], @2,
                        @"iOS takes the internal value as it is");
  XCTAssertEqualObjects(sdk.launchedWith[@"com.bugsee.option.capture.video.scale"], @0.5);
}

- (void)testABackgroundLaunchTheSdkDefersIsReportedAsDeferred {
  // SDK source: in the background it answers started: YES at once with nothing launched.
  BGSFakeBugsee *sdk = [[BGSFakeBugsee alloc] init];
  sdk.statusAtStarted = @"stopped";
  XCTAssertEqualObjects([self launch:sdk token:@"tok" options:nil][0], BGSFlutterLaunchOps.deferred);
}

- (void)testAnSdkAlreadyLaunchingOrLaunchedIsNotLaunchedAgain {
  // SDK source: it answers started: YES and drops the options, which looks like a real launch.
  for (NSString *running in @[ @"launching", @"launched" ]) {
    BGSFakeBugsee *sdk = [[BGSFakeBugsee alloc] init];
    sdk.status = running;
    NSArray *a = [self launch:sdk token:@"tok" options:@{@"com.bugsee.option.capture.logs" : @NO}];
    XCTAssertEqualObjects(a[0], BGSFlutterLaunchOps.alreadyRunning, @"%@", running);
    XCTAssertEqual(sdk.launches.count, 0u);
  }
}

- (void)testALaunchDuringAStopIsRefused {
  BGSFakeBugsee *sdk = [[BGSFakeBugsee alloc] init];
  sdk.status = @"stopping";
  NSArray *a = [self launch:sdk token:@"tok" options:nil];
  XCTAssertEqualObjects(a[0], BGSFlutterLaunchOps.refused);
  XCTAssertEqualObjects(a[1], BGSFlutterLaunchOps.stopping);
  XCTAssertEqual(sdk.launches.count, 0u);
}

- (void)testABlankTokenNeverReachesTheSdk {
  for (id token in @[ [NSNull null], @"", @"  \n" ]) {
    BGSFakeBugsee *sdk = [[BGSFakeBugsee alloc] init];
    NSArray *a = [self launch:sdk token:token == [NSNull null] ? nil : token options:nil];
    XCTAssertEqualObjects(a[0], BGSFlutterLaunchOps.refused);
    XCTAssertEqualObjects(a[1], BGSFlutterLaunchOps.invalidToken);
    XCTAssertEqual(sdk.launches.count, 0u);
  }
}

- (void)testAnSdkThatDeclinesIsRefusedAsFailed {
  BGSFakeBugsee *sdk = [[BGSFakeBugsee alloc] init];
  sdk.startedWith = @NO;
  NSArray *a = [self launch:sdk token:@"tok" options:nil];
  XCTAssertEqualObjects(a[0], BGSFlutterLaunchOps.refused);
  XCTAssertEqualObjects(a[1], BGSFlutterLaunchOps.failed);
}

- (void)testAnExceptionFromTheSdkIsAnErrorAndNeverAnOutcome {
  BGSFakeBugsee *sdk = [[BGSFakeBugsee alloc] init];
  sdk.launchThrows = [NSException exceptionWithName:@"BugseeBoom" reason:@"it broke" userInfo:nil];
  NSArray *a = [self launch:sdk token:@"secret-token" options:nil];
  XCTAssertEqualObjects(a[0], [NSNull null]);
  NSError *error = a[2];
  XCTAssertEqualObjects(error.localizedDescription, @"BugseeBoom: it broke");
  XCTAssertFalse([error.localizedDescription containsString:@"secret-token"]);
}

- (void)testStopAnswersWhenTheSdkHasStoppedAndReportsAnException {
  BGSFakeBugsee *sdk = [[BGSFakeBugsee alloc] init];
  __block NSInteger done = 0;
  __block NSError *error = nil;
  [BGSFlutterLaunchOps stopWithSdk:sdk done:^(NSError *e) { done++; error = e; }];
  XCTAssertEqual(sdk.stops, 1);
  XCTAssertEqual(done, 1);
  XCTAssertNil(error);
  sdk.stopThrows = [NSException exceptionWithName:@"X" reason:@"y" userInfo:nil];
  [BGSFlutterLaunchOps stopWithSdk:sdk done:^(NSError *e) { done++; error = e; }];
  XCTAssertEqual(done, 2);
  XCTAssertEqualObjects(error.localizedDescription, @"X: y");
}

- (void)testTheOptionsAreFlatStringKeysWithNumberOrStringValues {
  NSDictionary *out = [BGSFlutterLaunchOps sdkOptionsFromFlat:@{
    @"com.bugsee.option.capture.logs" : @YES,
    @"com.bugsee.option.config.duration" : @45,
    @"com.bugsee.option.$$ENDPOINT" : @"https://bugsee.example.com",
    @"com.bugsee.option.nothing" : [NSNull null],
    @"com.bugsee.option.nested" : @{@"a" : @1},
    @"com.bugsee.option.list" : @[ @1 ],
    @7 : @"not a string key",
  }];
  XCTAssertEqualObjects(out, (@{
    @"com.bugsee.option.capture.logs" : @YES,
    @"com.bugsee.option.config.duration" : @45,
    @"com.bugsee.option.$$ENDPOINT" : @"https://bugsee.example.com",
  }));
  XCTAssertEqualObjects([BGSFlutterLaunchOps sdkOptionsFromFlat:nil], (@{}));
}

- (void)testTheReadBackIsPrimitivesWithFloatsAsDoubles {
  NSDictionary *out = [BGSFlutterLaunchOps reportedOptionsFromSdk:@{
    @"a" : @YES,
    @"b" : @3,
    @"c" : @0.5f,
    @"d" : @"s",
    @"e" : [NSNull null],
    @"f" : @[ @1 ],
  }];
  XCTAssertEqualObjects(out[@"a"], @YES);
  XCTAssertEqualObjects(out[@"b"], @3);
  XCTAssertEqualObjects(out[@"c"], @0.5);
  XCTAssertEqual(strcmp([out[@"c"] objCType], "d"), 0, @"a float is reported as a double");
  XCTAssertEqualObjects(out[@"d"], @"s");
  XCTAssertNil(out[@"e"]);
  XCTAssertNil(out[@"f"]);
}

- (void)testTheBridgeVocabularyIsWhatDartExpects {
  XCTAssertEqualObjects(BGSFlutterLaunchOps.launched, @"launched");
  XCTAssertEqualObjects(BGSFlutterLaunchOps.alreadyRunning, @"already-running");
  XCTAssertEqualObjects(BGSFlutterLaunchOps.deferred, @"deferred");
  XCTAssertEqualObjects(BGSFlutterLaunchOps.refused, @"refused");
  XCTAssertEqualObjects(BGSFlutterLaunchOps.invalidToken, @"invalid-token");
  XCTAssertEqualObjects(BGSFlutterLaunchOps.stopping, @"stopping");
  XCTAssertEqualObjects(BGSFlutterLaunchOps.failed, @"failed");
  XCTAssertEqualObjects(BGSFlutterLaunchOps.errorCode, @"launch-failed");
}

#pragma mark - against the REAL SDK (the pinned framework)

- (NSDictionary *)manifest {
  NSString *path = [[[@(__FILE__) stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"../../../../test/fixtures/option_manifests/ios.json"]
      stringByStandardizingPath];
  NSData *data = [NSData dataWithContentsOfFile:path];
  XCTAssertNotNil(data, @"%@", path);
  return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

/// The enums the pinned framework compiles, by value, against the manifest the SDK published: a
/// renumbered SDK or a stale manifest is seen (workbook 7.4.2, 7.4.3).
- (void)testTheManifestEnumsAreTheFrameworksRealEnums {
  NSDictionary *real = @{
    @"BugseeFrameRate" : @{@"Low" : @(BugseeFrameRateLow), @"Medium" : @(BugseeFrameRateMedium), @"High" : @(BugseeFrameRateHigh)},
    @"BugseeVideoQuality" : @{@"Default" : @(BugseeVideoQualityDefault), @"Medium" : @(BugseeVideoQualityMedium), @"High" : @(BugseeVideoQualityHigh)},
    @"BugseeSeverityLevel" : @{@"Low" : @(BugseeSeverityLow), @"Medium" : @(BugseeSeverityMedium), @"High" : @(BugseeSeverityHigh), @"Critical" : @(BugseeSeverityCritical), @"Blocker" : @(BugseeSeverityBlocker)},
    @"BugseeStyle" : @{@"Light" : @(BugseeStyleLight), @"Dusk" : @(BugseeStyleDusk), @"BasedOnStatusBar" : @(BugseeStyleBasedOnStatusBar), @"System" : @(BugseeStyleSystem)},
    @"BugseeLogLevel" : @{@"Error" : @(BugseeLogLevelError), @"Warning" : @(BugseeLogLevelWarning), @"Info" : @(BugseeLogLevelInfo), @"Debug" : @(BugseeLogLevelDebug), @"Verbose" : @(BugseeLogLevelVerbose)},
    @"BugseeDataEncryptionMode" : @{@"None" : @(BugseeDataEncryptionNone), @"OnDevice" : @(BugseeDataEncryptionOnDevice), @"EndToEnd" : @(BugseeDataEncryptionEndToEnd)},
    @"BugseeCrashHandlerType" : @{@"BSD" : @(BugseeCrashHandlerTypeBSD), @"Mach" : @(BugseeCrashHandlerTypeMach), @"MachAndBSD" : @(BugseeCrashHandlerTypeMachAndBSD)},
  };
  NSMutableSet *seen = [NSMutableSet set];
  for (NSDictionary *option in [self manifest][@"options"]) {
    NSDictionary *e = option[@"enum"];
    if (!e) continue;
    [seen addObject:e[@"name"]];
    XCTAssertEqualObjects(e[@"values"], real[e[@"name"]], @"%@", option[@"key"]);
  }
  XCTAssertEqualObjects(seen, [NSSet setWithArray:real.allKeys], @"every manifest enum is covered");
}

/// What the SDK does with the options this plugin sends: every enum option takes its internal
/// number as it is (nothing is translated on iOS), and the endpoint goes under the namespaced
/// hidden key with no version, as on Android (the workbook's 8.2 asymmetry is the 6.x SDK's).
- (void)testTheSdkAppliesTheNumbersAndTheNamespacedEndpointAsSent {
  for (NSDictionary *option in [self manifest][@"options"]) {
    NSDictionary *e = option[@"enum"];
    if (!e) continue;
    for (NSString *name in e[@"values"]) {
      NSNumber *value = e[@"values"][name];
      NSDictionary *applied = [[BugseeOptions optionsFrom:@{option[@"key"] : value}] dictionary];
      XCTAssertEqualObjects(applied[option[@"key"]], value, @"%@ = %@ (%@)", option[@"key"], value, name);
    }
  }
  NSDictionary *applied = [[BugseeOptions optionsFrom:@{
    @"com.bugsee.option.$$ENDPOINT" : @"https://bugsee.example.com",
    @"com.bugsee.option.config.duration" : @45,
  }] dictionary];
  XCTAssertEqualObjects(applied[@"com.bugsee.option.$$ENDPOINT"], @"https://bugsee.example.com");
  XCTAssertEqualObjects(applied[@"com.bugsee.option.config.duration"], @45);
}

- (void)testTheRealSdkReadsAsStoppedBeforeAnyLaunch {
  XCTAssertEqualObjects([[BGSFlutterRealBugsee alloc] init].statusName, @"stopped");
  // Defaults are reported before a launch, floats as doubles and nothing but primitives.
  NSDictionary *out = [BGSFlutterLaunchOps reportedOptionsFromSdk:[Bugsee getLaunchOptions]];
  XCTAssertEqualObjects(out[@"com.bugsee.option.config.duration"], @60);
  for (id v in out.allValues) {
    XCTAssertTrue([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]);
  }
}

@end
