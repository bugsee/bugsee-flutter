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

/// A listener that records the sent messages.
@interface FeedbackCollector : NSObject <BGSFlutterFeedbackListener>
- (instancetype)initInto:(NSMutableArray *)into;
@end

@implementation FeedbackCollector {
  NSMutableArray *_into;
}
- (instancetype)initInto:(NSMutableArray *)into {
  if (self = [super init]) _into = into;
  return self;
}
- (void)onNewMessagesReceived:(NSArray<NSString *> *)messages {
}
- (void)onNewMessageSent:(NSString *)message {
  [_into addObject:message];
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

- (void)testACallbackQueuedBeforeTheDisableIsDropped {
  [self.ops setListenerEnabled:YES];
  id<BGSFlutterFeedbackListener> installed = self.sdk.installed;
  // From a background thread, while the main thread is not draining its queue: the callback is
  // queued to the main thread, and only then is the listener disabled.
  dispatch_semaphore_t queued = dispatch_semaphore_create(0);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    [installed onNewMessageSent:@"queued"];
    [installed onNewMessagesReceived:@[ @"queued" ]];
    dispatch_semaphore_signal(queued);
  });
  dispatch_semaphore_wait(queued, DISPATCH_TIME_FOREVER);
  [self.ops setListenerEnabled:NO];
  XCTestExpectation *drained = [self expectationWithDescription:@"main queue drained"];
  dispatch_async(dispatch_get_main_queue(), ^{
    [drained fulfill];
  });
  [self waitForExpectations:@[ drained ] timeout:5];
  XCTAssertEqual(self.sent.count, 0u);
  XCTAssertEqual(self.received.count, 0u);
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

- (void)testEveryListeningEngineGetsTheEventsAndOneDetachingSilencesNoOther {
  NSMutableArray *receivedB = [NSMutableArray array];
  NSMutableArray *sentB = [NSMutableArray array];
  BGSFlutterFeedbackOps *b = [self opsOn:self.sdk received:receivedB sent:sentB];
  [self.ops setListenerEnabled:YES];
  [b setListenerEnabled:YES];
  id<BGSFlutterFeedbackListener> shared = self.sdk.installed;
  [shared onNewMessageSent:@"one"];
  [shared onNewMessagesReceived:@[ @"in" ]];
  XCTAssertEqualObjects(self.sent, @[ @"one" ]);
  XCTAssertEqualObjects(sentB, @[ @"one" ]);
  XCTAssertEqual(self.received.count, 1u);
  XCTAssertEqual(receivedB.count, 1u);
  // The older engine goes: the newer keeps receiving, and the SDK slot is not released.
  [self.ops detach];
  XCTAssertTrue(self.sdk.installed == shared, @"the slot still holds the fan-out");
  [shared onNewMessageSent:@"two"];
  XCTAssertEqualObjects(self.sent, @[ @"one" ]);
  XCTAssertEqualObjects((sentB), (@[ @"one", @"two" ]));
  // The newer goes too: nobody listens, so the slot is released.
  [b detach];
  XCTAssertNil(self.sdk.installed);
}

- (void)testTheNewerEngineDetachingDoesNotSilenceTheOlder {
  NSMutableArray *receivedB = [NSMutableArray array];
  NSMutableArray *sentB = [NSMutableArray array];
  BGSFlutterFeedbackOps *b = [self opsOn:self.sdk received:receivedB sent:sentB];
  [self.ops setListenerEnabled:YES];
  [b setListenerEnabled:YES];
  [b detach];
  XCTAssertNotNil(self.sdk.installed);
  [self.sdk.installed onNewMessageSent:@"x"];
  XCTAssertEqualObjects(self.sent, @[ @"x" ]);
  XCTAssertEqual(sentB.count, 0u);
}

- (void)testEnablingAgainReplacesThisEnginesRelayWithoutADuplicate {
  [self.ops setListenerEnabled:YES];
  [self.ops setListenerEnabled:YES];
  [self.sdk.installed onNewMessageSent:@"once"];
  XCTAssertEqualObjects(self.sent, @[ @"once" ]);
}

- (void)testAttachForgetsAListenerAPreviousIsolateLeft {
  [self.ops setListenerEnabled:YES];
  id<BGSFlutterFeedbackListener> stale = self.sdk.installed;
  XCTAssertTrue([self.ops attach]);
  XCTAssertNil(self.sdk.installed);
  [stale onNewMessageSent:@"from the old isolate"];
  XCTAssertEqual(self.sent.count, 0u);
}

- (void)testAFailedReinstallSilencesTheListenerThisEngineHadBefore {
  [self.ops setListenerEnabled:YES];
  id<BGSFlutterFeedbackListener> first = self.sdk.installed;
  self.sdk.registered = NO;
  XCTAssertTrue([self.ops setListenerEnabled:YES].failed);
  [first onNewMessageSent:@"late"];
  XCTAssertEqual(self.sent.count, 0u);
}

- (void)testAFailedInstallLeavesNothingInstalled {
  self.sdk.registered = NO;
  XCTAssertTrue([self.ops setListenerEnabled:YES].failed);
  XCTAssertNil(self.sdk.installed);
}

// ---- the add-on's listener slot ----

- (void)testTheAdapterSlotTellsTheSdkOnceAndNeverWithNil {
  NSMutableArray *installs = [NSMutableArray array];
  BGSFlutterFeedbackAdapterSlot *slot = [[BGSFlutterFeedbackAdapterSlot alloc]
      initWithInstaller:^(id adapter) {
        [installs addObject:adapter ?: [NSNull null]];
      }];
  NSMutableArray *first = [NSMutableArray array];
  NSMutableArray *second = [NSMutableArray array];
  [slot installListener:nil];
  XCTAssertEqual(installs.count, 0u, @"nobody listens: the add-on is not told anything");
  // A quick on, off, on: the add-on orders two changes it is given no better than a coin flip.
  id<BGSFlutterFeedbackListener> one = (id<BGSFlutterFeedbackListener>)[self collectorInto:first];
  id<BGSFlutterFeedbackListener> two = (id<BGSFlutterFeedbackListener>)[self collectorInto:second];
  [slot installListener:one];
  [slot installListener:nil];
  [slot installListener:two];
  XCTAssertEqual(installs.count, 1u, @"once, with the adapter, never with nil");
  XCTAssertTrue(installs[0] == slot.adapter);
  [(id<BGSFlutterFeedbackListener>)slot.adapter onNewMessageSent:@"x"];
  XCTAssertEqual(first.count, 0u);
  XCTAssertEqualObjects(second, @[ @"x" ]);
  [slot installListener:nil];
  [(id<BGSFlutterFeedbackListener>)slot.adapter onNewMessageSent:@"y"];
  XCTAssertEqualObjects(second, @[ @"x" ], @"nobody listens: dropped");
  XCTAssertEqual(installs.count, 1u);
}

- (id)collectorInto:(NSMutableArray *)into {
  return [[FeedbackCollector alloc] initInto:into];
}

// ---- the real add-on ----

/// Runs first (XCTest orders methods by name): nothing has called register yet, so it was a
/// `+load` that registered the add-on. Which one is not told apart here: the add-on's own shim
/// (`BugseeFeedbackAutoRegister`) is linked into this test host too, so removing the plugin's
/// `+load` does not fail this test (checked); that the plugin's own `+load`, `ensureRegistered`
/// and the Swift reference are in place is guarded by test/feedback_package_drift_test.dart.
- (void)testAAddOnIsRegisteredByLoadBeforeAnyTestRegistersIt {
  XCTAssertTrue([[BGSFlutterRealFeedback new] isRegistered]);
}

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
