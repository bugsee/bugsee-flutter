#import <XCTest/XCTest.h>

#import "BGSFlutterLogOps.h"
#import "BGSFlutterNetworkOps.h"

@import Bugsee.SPI;

/// One recorded call to the fake SDK.
@interface BGSLogCall : NSObject
@property(nonatomic, copy, nullable) NSString *tag;
@property(nonatomic, copy) NSString *message;
@property(nonatomic) NSInteger level;
@end
@implementation BGSLogCall
@end

/// A fake SDK behind the seam: records every line handed to it.
@interface BGSFakeLogSdk : NSObject <BGSFlutterLogSDK>
@property(nonatomic) BOOL accepting;
@property(nonatomic) BOOL channelAvailable;
@property(nonatomic) BOOL acceptsThrows;
/// The message whose submit throws (an app filter that threw).
@property(nonatomic, copy) NSString *throwOnMessage;
@property(nonatomic, strong) NSMutableArray<BGSLogCall *> *submitted;
@property(nonatomic) NSInteger acceptsCalls;
@end

@implementation BGSFakeLogSdk
- (instancetype)init {
  if ((self = [super init])) {
    _accepting = YES;
    _channelAvailable = YES;
    _submitted = [NSMutableArray array];
  }
  return self;
}
- (BOOL)acceptsLogs {
  _acceptsCalls++;
  if (_acceptsThrows) @throw [NSException exceptionWithName:@"Status" reason:@"unreadable" userInfo:nil];
  return _accepting;
}
- (BOOL)submitLogWithTag:(NSString *)tag message:(NSString *)message level:(NSInteger)level {
  if (!_channelAvailable) return NO;
  if ([message isEqualToString:_throwOnMessage]) {
    @throw [NSException exceptionWithName:@"AppFilter" reason:@"the app's filter threw" userInfo:nil];
  }
  BGSLogCall *call = [[BGSLogCall alloc] init];
  call.tag = tag;
  call.message = message;
  call.level = level;
  [_submitted addObject:call];
  return YES;
}
@end

/// A channel that records what it is handed.
@interface BGSFakeLogChannel : NSObject <BGSWrapperChannel>
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *calls;
@property(nonatomic) BOOL throwing;
@end
@implementation BGSFakeLogChannel
- (instancetype)init {
  if ((self = [super init])) _calls = [NSMutableArray array];
  return self;
}
- (void)logWithTag:(NSString *)tag message:(NSString *)message level:(BugseeLogLevel)level source:(BGSLogEventSource)source {
  if (_throwing) @throw [NSException exceptionWithName:@"AppFilter" reason:@"filter bug" userInfo:nil];
  [_calls addObject:@{
    @"tag" : tag ?: [NSNull null],
    @"message" : message ?: [NSNull null],
    @"level" : @(level),
    @"source" : @(source),
  }];
}
@end

static NSDictionary *Line(NSString *message, NSInteger level, NSString *tag) {
  NSMutableDictionary *line = [@{@"message" : message ?: @"", @"level" : @(level)} mutableCopy];
  if (tag) line[@"tag"] = tag;
  return line;
}

@interface BGSFlutterLogOpsTests : XCTestCase
@end

@implementation BGSFlutterLogOpsTests

// ---- the gate ------------------------------------------------------------------------------------

- (void)testNothingIsHandedOverWhenTheSdkIsNotAccepting {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  sdk.accepting = NO;
  XCTAssertEqual([BGSFlutterLogOps addLinesWithSdk:sdk lines:(@[ Line(@"a", 3, nil), Line(@"b", 3, nil) ])], 0);
  XCTAssertEqual(sdk.submitted.count, 0u);
}

- (void)testTheGateIsReadOncePerBatch {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  [BGSFlutterLogOps addLinesWithSdk:sdk lines:@[ Line(@"a", 3, nil), Line(@"b", 3, nil), Line(@"c", 3, nil) ]];
  XCTAssertEqual(sdk.acceptsCalls, 1);
}

- (void)testAGateThatThrowsHandsNothingOverAndDoesNotCrash {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  sdk.acceptsThrows = YES;
  XCTAssertEqual([BGSFlutterLogOps addLinesWithSdk:sdk lines:(@[ Line(@"a", 3, nil) ])], 0);
  XCTAssertEqual(sdk.submitted.count, 0u);
}

- (void)testAnEmptyNilOrWrongTypeBatchIsZeroAndDoesNotReadTheGate {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  XCTAssertEqual([BGSFlutterLogOps addLinesWithSdk:sdk lines:nil], 0);
  XCTAssertEqual([BGSFlutterLogOps addLinesWithSdk:sdk lines:@[]], 0);
  XCTAssertEqual([BGSFlutterLogOps addLinesWithSdk:sdk lines:(id)@"not an array"], 0);
  XCTAssertEqual(sdk.acceptsCalls, 0);
}

// ---- what is handed over -------------------------------------------------------------------------

- (void)testLinesAreHandedOverInOrderWithTheirTagAndLevel {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  NSInteger handed = [BGSFlutterLogOps addLinesWithSdk:sdk
                                                  lines:@[ Line(@"one", 1, @"print"), Line(@"two", 5, @"debugPrint"), Line(@"three", 3, nil) ]];
  XCTAssertEqual(handed, 3);
  XCTAssertEqualObjects(sdk.submitted[0].message, @"one");
  XCTAssertEqualObjects(sdk.submitted[0].tag, @"print");
  XCTAssertEqual(sdk.submitted[0].level, 1);
  XCTAssertEqualObjects(sdk.submitted[1].message, @"two");
  XCTAssertEqual(sdk.submitted[1].level, 5);
  XCTAssertEqualObjects(sdk.submitted[2].message, @"three");
  XCTAssertNil(sdk.submitted[2].tag);
}

- (void)testAnEmptyTagIsNoTag {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  [BGSFlutterLogOps addLinesWithSdk:sdk lines:@[ Line(@"x", 3, @"") ]];
  XCTAssertNil(sdk.submitted[0].tag);
}

- (void)testALevelOutsideTheSdksRangeIsRefused {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  for (NSNumber *level in @[ @0, @6, @-1, @99, @(NSIntegerMax) ]) {
    XCTAssertFalse([BGSFlutterLogOps addLineWithSdk:sdk line:Line(@"x", level.integerValue, nil)], @"%@", level);
  }
  XCTAssertEqual(sdk.submitted.count, 0u);
  for (NSInteger level = 1; level <= 5; level++) {
    XCTAssertTrue([BGSFlutterLogOps addLineWithSdk:sdk line:Line(@"x", level, nil)]);
  }
  XCTAssertEqual(sdk.submitted.count, 5u);
}

- (void)testAMalformedLineIsRefused {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  XCTAssertFalse([BGSFlutterLogOps addLineWithSdk:sdk line:Line(@"", 3, nil)]);
  XCTAssertFalse([BGSFlutterLogOps addLineWithSdk:sdk line:nil]);
  XCTAssertFalse([BGSFlutterLogOps addLineWithSdk:sdk line:(id)@"string"]);
  XCTAssertFalse([BGSFlutterLogOps addLineWithSdk:sdk line:(@{@"message" : @"x"})]);
  XCTAssertFalse([BGSFlutterLogOps addLineWithSdk:sdk line:(@{@"message" : @3, @"level" : @3})]);
  XCTAssertEqual(sdk.submitted.count, 0u);
}

- (void)testAWrapperWithNoChannelYetHandsNothingOver {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  sdk.channelAvailable = NO;
  XCTAssertEqual([BGSFlutterLogOps addLinesWithSdk:sdk lines:(@[ Line(@"a", 3, nil), Line(@"b", 3, nil) ])], 0);
}

- (void)testAnExceptionFromTheAppsFilterDropsThatLineAndTheBatchGoesOn {
  BGSFakeLogSdk *sdk = [[BGSFakeLogSdk alloc] init];
  sdk.throwOnMessage = @"bad";
  NSInteger handed = [BGSFlutterLogOps addLinesWithSdk:sdk
                                                  lines:@[ Line(@"a", 3, nil), Line(@"bad", 3, nil), Line(@"c", 3, nil) ]];
  XCTAssertEqual(handed, 2);
  XCTAssertEqualObjects(sdk.submitted[0].message, @"a");
  XCTAssertEqualObjects(sdk.submitted[1].message, @"c");
}

// ---- the real seam over a recording channel ------------------------------------------------------

- (void)testTheRealSeamClaimsOnlyTheWrapperSourceAndKeepsTheLevel {
  BGSFakeLogChannel *channel = [[BGSFakeLogChannel alloc] init];
  [BGSFlutterNetworkChannel shared].channel = channel;
  BGSFlutterRealLogSdk *sdk = [[BGSFlutterRealLogSdk alloc] init];
  XCTAssertTrue([sdk submitLogWithTag:@"print" message:@"hello" level:2]);
  XCTAssertTrue([sdk submitLogWithTag:nil message:@"world" level:5]);
  XCTAssertEqual(channel.calls.count, 2u);
  XCTAssertEqualObjects(channel.calls[0][@"tag"], @"print");
  XCTAssertEqualObjects(channel.calls[0][@"message"], @"hello");
  XCTAssertEqualObjects(channel.calls[0][@"level"], @(BugseeLogLevelWarning));
  // Custom: "the host runtime's own logs". Never Bugsee (the app's own Bugsee.log).
  XCTAssertEqualObjects(channel.calls[0][@"source"], @(BGSLogEventSourceCustom));
  XCTAssertEqualObjects(channel.calls[1][@"level"], @(BugseeLogLevelVerbose));
  XCTAssertEqualObjects(channel.calls[1][@"source"], @(BGSLogEventSourceCustom));
  [BGSFlutterNetworkChannel shared].channel = nil;
}

- (void)testWithNoChannelTheRealSeamRefusesAndNothingThrows {
  [BGSFlutterNetworkChannel shared].channel = nil;
  BGSFlutterRealLogSdk *sdk = [[BGSFlutterRealLogSdk alloc] init];
  XCTAssertFalse([sdk submitLogWithTag:nil message:@"x" level:3]);
}

- (void)testAReplacedRegistrationSendsToTheNewChannelOnly {
  BGSFakeLogChannel *retired = [[BGSFakeLogChannel alloc] init];
  BGSFakeLogChannel *current = [[BGSFakeLogChannel alloc] init];
  BGSFlutterRealLogSdk *sdk = [[BGSFlutterRealLogSdk alloc] init];
  [BGSFlutterNetworkChannel shared].channel = retired;
  XCTAssertTrue([sdk submitLogWithTag:nil message:@"before" level:3]);
  [BGSFlutterNetworkChannel shared].channel = current;
  XCTAssertTrue([sdk submitLogWithTag:nil message:@"after" level:3]);
  XCTAssertEqual(retired.calls.count, 1u);
  XCTAssertEqualObjects(retired.calls[0][@"message"], @"before");
  XCTAssertEqual(current.calls.count, 1u);
  XCTAssertEqualObjects(current.calls[0][@"message"], @"after");
  [BGSFlutterNetworkChannel shared].channel = nil;
}

- (void)testAnExceptionThrownThroughTheRealChannelIsCaughtPerLine {
  BGSFakeLogChannel *channel = [[BGSFakeLogChannel alloc] init];
  channel.throwing = YES;
  [BGSFlutterNetworkChannel shared].channel = channel;
  BGSFlutterRealLogSdk *sdk = [[BGSFlutterRealLogSdk alloc] init];
  XCTAssertFalse([BGSFlutterLogOps addLineWithSdk:sdk line:Line(@"a", 3, nil)]);
  channel.throwing = NO;
  XCTAssertTrue([BGSFlutterLogOps addLineWithSdk:sdk line:Line(@"b", 3, nil)]);
  [BGSFlutterNetworkChannel shared].channel = nil;
}

// ---- the wire against the real SDK's constants ---------------------------------------------------

- (NSDictionary *)fixture {
  NSString *path = [[[NSString stringWithUTF8String:__FILE__] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../../../../test/fixtures/log_wire.json"];
  NSData *data = [NSData dataWithContentsOfFile:[path stringByStandardizingPath]];
  XCTAssertNotNil(data, @"%@", path);
  return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

- (void)testTheSourceIsTheSdksCustom98AndNotOneItReserves {
  NSDictionary *fixture = [self fixture];
  XCTAssertEqual([BGSFlutterLogOps wrapperSource], [fixture[@"source"] integerValue]);
  XCTAssertEqual([BGSFlutterLogOps wrapperSource], (NSInteger)BGSLogEventSourceCustom);
  XCTAssertNotEqual([BGSFlutterLogOps wrapperSource], (NSInteger)BGSLogEventSourceBugsee);
  XCTAssertNotEqual([BGSFlutterLogOps wrapperSource], (NSInteger)BGSLogEventSourceInternal);
  XCTAssertNotEqual([BGSFlutterLogOps wrapperSource], (NSInteger)BGSLogEventSourceOSLog);
  XCTAssertEqual((NSInteger)BGSLogEventSourceBugsee, 4);
}

- (void)testEveryLevelDartSendsIsTheSdksOwnByValue {
  NSDictionary *fixture = [self fixture];
  NSDictionary *levels = fixture[@"levels"];
  NSDictionary *constants = @{
    @"BugseeLogLevelError" : @(BugseeLogLevelError),
    @"BugseeLogLevelWarning" : @(BugseeLogLevelWarning),
    @"BugseeLogLevelInfo" : @(BugseeLogLevelInfo),
    @"BugseeLogLevelDebug" : @(BugseeLogLevelDebug),
    @"BugseeLogLevelVerbose" : @(BugseeLogLevelVerbose),
  };
  XCTAssertEqual(levels.count, 5u);
  [fixture[@"iosLevelConstants"] enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *constant, BOOL *stop) {
    XCTAssertEqualObjects(constants[constant], levels[name], @"%@", name);
  }];
  XCTAssertEqual([BGSFlutterLogOps minLevel], [fixture[@"minLevel"] integerValue]);
  XCTAssertEqual([BGSFlutterLogOps maxLevel], [fixture[@"maxLevel"] integerValue]);
  XCTAssertEqual((NSInteger)BugseeLogLevelError, [BGSFlutterLogOps minLevel]);
  XCTAssertEqual((NSInteger)BugseeLogLevelVerbose, [BGSFlutterLogOps maxLevel]);
}

@end
