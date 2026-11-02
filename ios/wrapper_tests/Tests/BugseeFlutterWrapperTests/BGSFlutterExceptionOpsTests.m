#import <XCTest/XCTest.h>

#import "BGSFlutterExceptionOps.h"

@import Bugsee.SPI;

/// A fake SDK behind the seam: records which entry point was called, with what.
@interface BGSFakeExceptionSdk : NSObject <BGSFlutterExceptionSDK>
@property(nonatomic, strong) NSMutableArray<NSString *> *calls;
@property(nonatomic) BOOL running;
@property(nonatomic, strong) NSException *throwsOn;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *reason;
@property(nonatomic, copy) NSString *domain;
@property(nonatomic) NSInteger skipFrames;
@end

@implementation BGSFakeExceptionSdk
- (instancetype)init {
  if ((self = [super init])) {
    _calls = [NSMutableArray array];
    _running = YES;
    _skipFrames = -1;
  }
  return self;
}
- (BOOL)isLaunchedOrLaunching {
  return _running;
}
- (void)logHandledName:(NSString *)name
                reason:(NSString *)reason
                domain:(NSString *)domain
            skipFrames:(NSInteger)skipFrames {
  [_calls addObject:@"handled"];
  _name = name;
  _reason = reason;
  _domain = domain;
  _skipFrames = skipFrames;
  if (_throwsOn) @throw _throwsOn;
}
- (void)logUnhandledName:(NSString *)name reason:(NSString *)reason {
  [_calls addObject:@"unhandled"];
  _name = name;
  _reason = reason;
  _domain = nil;
  if (_throwsOn) @throw _throwsOn;
}
@end

@interface BGSFlutterExceptionOpsTests : XCTestCase
@end

static NSString *const kDoc = @"{\"internalType\":\"FlutterManagedException\",\"name\":\"StateError\"}";

static NSString *Repeat(NSString *s, NSInteger n) {
  return [@"" stringByPaddingToLength:(NSUInteger)n withString:s startingAtIndex:0];
}

@implementation BGSFlutterExceptionOpsTests

- (void)testHandledGoesToLogExceptionNamedForTheBackendWithTheDocumentAsReason {
  BGSFakeExceptionSdk *sdk = [BGSFakeExceptionSdk new];
  BGSFlutterFacadeResult *r = [BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:YES domain:@"checkout"];
  XCTAssertFalse(r.failed);
  XCTAssertEqualObjects(r.value, @YES);
  XCTAssertEqualObjects(sdk.calls, @[ @"handled" ]);
  // The backend routes on this name and reads the JSON out of the reason.
  XCTAssertEqualObjects(sdk.name, @"FlutterManagedException");
  XCTAssertEqualObjects(sdk.reason, kDoc);
  XCTAssertEqualObjects(sdk.domain, @"checkout");
  // The recorded stack is the platform thread's, not the app's: nothing to skip.
  XCTAssertEqual(sdk.skipFrames, 0);
}

- (void)testUnhandledGoesToLogUnhandledExceptionAndNeverToLogException {
  BGSFakeExceptionSdk *sdk = [BGSFakeExceptionSdk new];
  BGSFlutterFacadeResult *r = [BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:NO domain:@"checkout"];
  XCTAssertEqualObjects(r.value, @YES);
  XCTAssertEqualObjects(sdk.calls, @[ @"unhandled" ]);
  XCTAssertEqualObjects(sdk.name, @"FlutterManagedException");
  XCTAssertEqualObjects(sdk.reason, kDoc);
  // The SDK has no domain on this path.
  XCTAssertNil(sdk.domain);
}

- (void)testNotLaunchedIsNotHandedToTheSdkAndTheAnswerSaysSo {
  BGSFakeExceptionSdk *sdk = [BGSFakeExceptionSdk new];
  sdk.running = NO;
  XCTAssertEqualObjects([BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:YES domain:nil].value, @NO);
  XCTAssertEqualObjects([BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:NO domain:nil].value, @NO);
  XCTAssertEqual(sdk.calls.count, 0u);
}

- (void)testAnEmptyOrMissingDocumentIsRefusedBeforeTheSdk {
  BGSFakeExceptionSdk *sdk = [BGSFakeExceptionSdk new];
  XCTAssertEqualObjects([BGSFlutterExceptionOps logWithSdk:sdk payload:@"" handled:YES domain:nil].errorCode,
                        BGSFlutterFacadeOps.invalidArgument);
  XCTAssertEqualObjects([BGSFlutterExceptionOps logWithSdk:sdk payload:nil handled:NO domain:nil].errorCode,
                        BGSFlutterFacadeOps.invalidArgument);
  XCTAssertEqual(sdk.calls.count, 0u);
}

- (void)testTheLimitOfTheDocumentIsInclusive {
  BGSFakeExceptionSdk *sdk = [BGSFakeExceptionSdk new];
  NSInteger limit = BGSFlutterExceptionOps.maxPayloadLength;
  XCTAssertFalse([BGSFlutterExceptionOps logWithSdk:sdk payload:Repeat(@"a", limit) handled:YES domain:nil].failed);
  XCTAssertEqualObjects(
      [BGSFlutterExceptionOps logWithSdk:sdk payload:Repeat(@"a", limit + 1) handled:YES domain:nil].errorCode,
      BGSFlutterFacadeOps.invalidArgument);
  XCTAssertEqual(sdk.calls.count, 1u);
}

- (void)testABadDomainIsRefusedBeforeTheSdk {
  BGSFakeExceptionSdk *sdk = [BGSFakeExceptionSdk new];
  XCTAssertEqualObjects([BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:YES domain:@""].errorCode,
                        BGSFlutterFacadeOps.invalidArgument);
  NSInteger limit = BGSFlutterExceptionOps.maxDomainLength;
  XCTAssertEqualObjects(
      [BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:NO domain:Repeat(@"d", limit + 1)].errorCode,
      BGSFlutterFacadeOps.invalidArgument);
  XCTAssertEqual(sdk.calls.count, 0u);
  XCTAssertFalse([BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:YES domain:Repeat(@"d", limit)].failed);
}

- (void)testAnSdkExceptionIsAFailureNamingOnlyItsName {
  BGSFakeExceptionSdk *sdk = [BGSFakeExceptionSdk new];
  sdk.throwsOn = [NSException exceptionWithName:@"BugseeBoom" reason:kDoc userInfo:nil];
  BGSFlutterFacadeResult *r = [BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:NO domain:nil];
  XCTAssertEqualObjects(r.errorCode, BGSFlutterFacadeOps.sdkError);
  XCTAssertTrue([r.errorMessage containsString:@"BugseeBoom"]);
  XCTAssertFalse([r.errorMessage containsString:@"internalType"]);
}

- (void)testUnicodeDocumentsPassUntouched {
  BGSFakeExceptionSdk *sdk = [BGSFakeExceptionSdk new];
  NSString *doc = @"{\"reason\":\"café \U0001F600 line\\nbreak\"}";
  [BGSFlutterExceptionOps logWithSdk:sdk payload:doc handled:YES domain:nil];
  XCTAssertEqualObjects(sdk.reason, doc);
}

/// The real SDK, not launched: the seam's real implementation answers "not launched" without
/// touching anything, so a call before launch is gated by the wrapper on both paths.
- (void)testTheRealSdkIsNotLaunchedInATest {
  BGSFlutterRealExceptionSdk *sdk = [BGSFlutterRealExceptionSdk new];
  XCTAssertFalse([sdk isLaunchedOrLaunching]);
  XCTAssertEqualObjects([BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:NO domain:nil].value, @NO);
  XCTAssertEqualObjects([BGSFlutterExceptionOps logWithSdk:sdk payload:kDoc handled:YES domain:nil].value, @NO);
}

@end
