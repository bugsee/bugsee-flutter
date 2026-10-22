#import <XCTest/XCTest.h>

@import BugseeFlutterFeedbackWrapper;
@import Bugsee;
@import BugseeFeedback;

/// The add-on's module: records what reaches it.
@interface FakeFeedbackSdk : NSObject <BGSFlutterFeedbackSDK>
@property(nonatomic) BOOL registered;
@property(nonatomic, strong, nullable) NSException *raise;
@property(nonatomic, strong) NSMutableArray<NSString *> *calls;
@property(nonatomic, strong, nullable) id<BGSFlutterFeedbackListener> installed;
@end

@implementation FakeFeedbackSdk
- (instancetype)init {
  if (self = [super init]) {
    _registered = YES;
    _calls = [NSMutableArray array];
  }
  return self;
}
- (BOOL)isRegistered {
  return self.registered;
}
- (BOOL)registerIfMissing {
  return NO;
}
- (void)record:(NSString *)call {
  [self.calls addObject:call];
  if (self.raise) @throw self.raise;
}
- (void)showFeedbackUI {
  [self record:@"show"];
}
- (void)setGreeting:(NSString *)greeting {
  [self record:[NSString stringWithFormat:@"greeting:%@", greeting ?: @"(nil)"]];
}
- (void)setListener:(id<BGSFlutterFeedbackListener>)listener {
  [self record:listener ? @"listener:set" : @"listener:nil"];
  self.installed = listener;
}
@end

@interface BGSFlutterFeedbackOpsTests : XCTestCase
@property(nonatomic, strong) FakeFeedbackSdk *sdk;
@property(nonatomic, strong) NSMutableArray<NSArray<NSString *> *> *received;
@property(nonatomic, strong) NSMutableArray<NSString *> *sent;
@property(nonatomic, strong) BGSFlutterFeedbackOps *ops;
@end

@implementation BGSFlutterFeedbackOpsTests

- (BGSFlutterFeedbackOps *)opsOn:(FakeFeedbackSdk *)sdk
                        received:(NSMutableArray *)received
                            sent:(NSMutableArray *)sent {
  return [[BGSFlutterFeedbackOps alloc]
      initWithSdk:sdk
         received:^(NSArray<NSString *> *messages) {
           [received addObject:messages];
         }
             sent:^(NSString *message) {
               [sent addObject:message];
             }];
}

- (void)setUp {
  [BGSFlutterFeedbackOps resetSlotForTesting];
  self.sdk = [FakeFeedbackSdk new];
  self.received = [NSMutableArray array];
  self.sent = [NSMutableArray array];
  self.ops = [self opsOn:self.sdk received:self.received sent:self.sent];
}

// ---- show / greeting ----

- (void)testShowReachesTheSdk {
  XCTAssertFalse([self.ops show].failed);
  XCTAssertEqualObjects(self.sdk.calls, @[ @"show" ]);
}

- (void)testGreetingIsPassedOnAsIsAndNilClears {
  [self.ops setGreeting:@"How can we help?"];
  [self.ops setGreeting:nil];
  [self.ops setGreeting:@""];
  NSArray *expected = @[ @"greeting:How can we help?", @"greeting:(nil)", @"greeting:" ];
  XCTAssertEqualObjects(self.sdk.calls, expected);
}

- (void)testAMissingModuleIsNotRegistered {
  self.sdk.registered = NO;
  XCTAssertEqualObjects([self.ops show].errorCode, @"not-registered");
  XCTAssertEqualObjects([self.ops setGreeting:@"x"].errorCode, @"not-registered");
  XCTAssertEqualObjects([self.ops setListenerEnabled:YES].errorCode, @"not-registered");
  XCTAssertEqual(self.sdk.calls.count, 0u);
}

- (void)testAnSdkExceptionIsAnSdkErrorThatNeverQuotesTheReason {
  self.sdk.raise = [NSException exceptionWithName:@"BoomException"
                                           reason:@"secret chat text"
                                         userInfo:nil];
  BGSFlutterFeedbackResult *result = [self.ops show];
  XCTAssertEqualObjects(result.errorCode, @"sdk-error");
  XCTAssertTrue([result.errorMessage containsString:@"BoomException"]);
  XCTAssertFalse([result.errorMessage containsString:@"secret"]);
}

- (void)testAttachSaysWhetherTheModuleIsRegistered {
  XCTAssertTrue([self.ops attach]);
  self.sdk.registered = NO;
  XCTAssertFalse([self.ops attach]);
}

- (void)testTheWireCodesAreTheOnesDartMaps {
  XCTAssertEqualObjects([BGSFlutterFeedbackOps notRegisteredCode], @"not-registered");
  XCTAssertEqualObjects([BGSFlutterFeedbackOps sdkErrorCode], @"sdk-error");
}

// ---- listener ----

- (void)testReceivedMessagesGoToTheSinkInOrder {
  [self.ops setListenerEnabled:YES];
  XCTAssertNotNil(self.sdk.installed);
  [self.sdk.installed onNewMessagesReceived:@[ @"a", @"b" ]];
  XCTAssertEqualObjects(self.received, @[ (@[ @"a", @"b" ]) ]);
}

- (void)testNonStringEntriesAreOmittedAndAnEmptyBatchIsNotDelivered {
  [self.ops setListenerEnabled:YES];
  [self.sdk.installed onNewMessagesReceived:(NSArray<NSString *> *)@[ @"a", [NSNull null], @"b" ]];
  [self.sdk.installed onNewMessagesReceived:(NSArray<NSString *> *)@[ [NSNull null] ]];
  [self.sdk.installed onNewMessagesReceived:@[]];
  XCTAssertEqualObjects(self.received, @[ (@[ @"a", @"b" ]) ]);
}

- (void)testSentMessagesGoToTheSink {
  [self.ops setListenerEnabled:YES];
  [self.sdk.installed onNewMessageSent:@"hello"];
  XCTAssertEqualObjects(self.sent, @[ @"hello" ]);
}

- (void)testACallbackFromAnotherThreadIsDeliveredOnTheMainThread {
  [self.ops setListenerEnabled:YES];
  XCTestExpectation *delivered = [self expectationWithDescription:@"delivered"];
  __block BOOL onMain = NO;
  BGSFlutterFeedbackOps *ops = [[BGSFlutterFeedbackOps alloc]
      initWithSdk:self.sdk
         received:^(NSArray<NSString *> *m) {
         }
             sent:^(NSString *message) {
               onMain = [NSThread isMainThread];
               [delivered fulfill];
             }];
  [ops setListenerEnabled:YES];
  id<BGSFlutterFeedbackListener> listener = self.sdk.installed;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    [listener onNewMessageSent:@"bg"];
  });
  [self waitForExpectations:@[ delivered ] timeout:5];
  XCTAssertTrue(onMain);
}

- (void)testDisablingRemovesTheSdkListenerAndDropsStragglers {
  [self.ops setListenerEnabled:YES];
  id<BGSFlutterFeedbackListener> installed = self.sdk.installed;
  [self.ops setListenerEnabled:NO];
  XCTAssertNil(self.sdk.installed);
  [installed onNewMessageSent:@"after"];
  [installed onNewMessagesReceived:@[ @"after" ]];
  XCTAssertEqual(self.sent.count, 0u);
  XCTAssertEqual(self.received.count, 0u);
}

- (void)testANewerEnginesListenerIsNotSilencedByTheOlderOnesDetach {
  NSMutableArray *receivedB = [NSMutableArray array];
  NSMutableArray *sentB = [NSMutableArray array];
  BGSFlutterFeedbackOps *b = [self opsOn:self.sdk received:receivedB sent:sentB];
  [self.ops setListenerEnabled:YES];
  [b setListenerEnabled:YES];
  id<BGSFlutterFeedbackListener> bs = self.sdk.installed;
  [self.ops detach];
  XCTAssertTrue(self.sdk.installed == bs, @"the older engine must not clear the newer one's listener");
  [bs onNewMessageSent:@"x"];
  XCTAssertEqualObjects(sentB, @[ @"x" ]);
  XCTAssertEqual(self.sent.count, 0u);
  [b detach];
  XCTAssertNil(self.sdk.installed);
}

- (void)testAttachForgetsAListenerAPreviousIsolateLeft {
  [self.ops setListenerEnabled:YES];
  id<BGSFlutterFeedbackListener> stale = self.sdk.installed;
  XCTAssertTrue([self.ops attach]);
  XCTAssertNil(self.sdk.installed);
  [stale onNewMessageSent:@"from the old isolate"];
  XCTAssertEqual(self.sent.count, 0u);
}

- (void)testAFailedInstallLeavesNothingInstalled {
  self.sdk.registered = NO;
  XCTAssertTrue([self.ops setListenerEnabled:YES].failed);
  XCTAssertNil(self.sdk.installed);
}

// ---- the real add-on ----

- (void)testTheRealAddOnRegistersWithTheSdkAndRegistrationIsIdempotent {
  // The plugin's +load / ensureRegistered path, then the explicit one the add-on documents.
  [BGSFlutterFeedbackRegistrar ensureRegistered];
  [BugseeFeedback register];
  BGSFlutterRealFeedback *real = [BGSFlutterRealFeedback new];
  XCTAssertTrue([real isRegistered]);
  XCTAssertFalse([real registerIfMissing], @"nothing was missing");
  XCTAssertTrue([Bugsee ext:[BugseeFeedback class]] == [BugseeFeedback shared]);
}

- (void)testTheRealAddOnTakesAndDropsAListenerWithoutRaising {
  // The SDK's own slot is weak and not readable, so that the adapter outlives setListener: is
  // not observable here; this only shows the real path installs and removes without a failure.
  BGSFlutterRealFeedback *real = [BGSFlutterRealFeedback new];
  BGSFlutterFeedbackOps *ops = [[BGSFlutterFeedbackOps alloc]
      initWithSdk:real
         received:^(NSArray<NSString *> *m) {
         }
             sent:^(NSString *m) {
             }];
  [BGSFlutterFeedbackRegistrar ensureRegistered];
  XCTAssertFalse([ops setListenerEnabled:YES].failed);
  XCTAssertFalse([ops setListenerEnabled:NO].failed);
}

@end
