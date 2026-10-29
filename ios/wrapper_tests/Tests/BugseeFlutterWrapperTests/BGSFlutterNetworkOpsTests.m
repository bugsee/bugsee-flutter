#import <XCTest/XCTest.h>

#import "BGSFlutterNetworkOps.h"
#import "BGSFlutterWrapper.h"

@import Bugsee;
// 7.0 GA moves the wrapper contract to the Bugsee.SPI submodule (BugseeSPI.h);
// the 7.0 betas declare it in Bugsee.h.
#if __has_include(<Bugsee/BugseeSPI.h>)
#import <Bugsee/BugseeSPI.h>
#endif

/// A fake SDK behind the seam: records every event handed to it.
@interface BGSFakeNetworkSdk : NSObject <BGSFlutterNetworkSDK>
@property(nonatomic) BOOL accepting;
@property(nonatomic) NSTimeInterval now;
@property(nonatomic) BOOL channelAvailable;
/// The event id whose submit throws (an app filter that threw).
@property(nonatomic, copy) NSString *throwOnId;
@property(nonatomic, strong) NSMutableArray<BugseeNetworkEvent *> *submitted;
@property(nonatomic) NSInteger acceptsCalls;
@end

@implementation BGSFakeNetworkSdk
- (instancetype)init {
  if ((self = [super init])) {
    _accepting = YES;
    _now = 10000000000.0;
    _channelAvailable = YES;
    _submitted = [NSMutableArray array];
  }
  return self;
}
- (BOOL)acceptsNetworkEvents {
  _acceptsCalls++;
  return _accepting;
}
- (NSTimeInterval)currentTimestampMs {
  return _now;
}
- (BOOL)submitNetworkEvent:(id)event {
  if (!_channelAvailable) return NO;
  if ([[(BugseeNetworkEvent *)event ID] isEqualToString:_throwOnId]) {
    @throw [NSException exceptionWithName:@"AppFilter" reason:@"the app's filter threw" userInfo:nil];
  }
  [_submitted addObject:event];
  return YES;
}
@end

/// A channel that records what it is handed, with the flag.
@interface BGSFakeChannel : NSObject <BGSWrapperChannel>
@property(nonatomic, strong) NSMutableArray *events;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *flags;
@end
@implementation BGSFakeChannel
- (instancetype)init {
  if ((self = [super init])) {
    _events = [NSMutableArray array];
    _flags = [NSMutableArray array];
  }
  return self;
}
- (void)addNetworkEvent:(BugseeNetworkEvent *)event requiresFiltering:(BOOL)requiresFiltering {
  [_events addObject:event];
  [_flags addObject:@(requiresFiltering)];
}
@end

static NSMutableDictionary *Message(NSString *identifier, NSString *stage) {
  return [@{
    @"id" : identifier,
    @"stage" : stage,
    @"mechanism" : @"dart:io",
    @"method" : @"GET",
    @"url" : @"https://example.com/a",
    @"ageMs" : @0,
    @"size" : @0,
    @"statusCode" : @0,
  } mutableCopy];
}

@interface BGSFlutterNetworkOpsTests : XCTestCase
@end

@implementation BGSFlutterNetworkOpsTests

- (void)testWireStagesMapToTheSdksOwnConstantsAndAbortIsCancel {
  XCTAssertEqualObjects([BGSFlutterNetworkOps sdkStageForWire:@"before"], BugseeNetworkEventBegin);
  XCTAssertEqualObjects([BGSFlutterNetworkOps sdkStageForWire:@"complete"], BugseeNetworkEventComplete);
  XCTAssertEqualObjects([BGSFlutterNetworkOps sdkStageForWire:@"error"], BugseeNetworkEventError);
  // The SDK's own interception emits `cancel` on iOS (BugseeConstants.m), not `abort`.
  XCTAssertEqualObjects([BGSFlutterNetworkOps sdkStageForWire:@"abort"], BugseeNetworkEventCancel);
  XCTAssertEqualObjects(BugseeNetworkEventCancel, @"cancel");
}

- (void)testRedirectHasNoIosStageSoThatEventIsNotHandedOver {
  // iOS carries a redirect as redirectedFromURL on the final event, never as a stage.
  XCTAssertNil([BGSFlutterNetworkOps sdkStageForWire:@"redirect"]);
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  XCTAssertFalse([BGSFlutterNetworkOps addEventWithSdk:sdk event:Message(@"1", @"redirect")]);
  XCTAssertEqual(sdk.submitted.count, 0u);
  for (NSString *name in @[ @"timing", @"websocket", @"cancel", @"", @"Before" ]) {
    XCTAssertNil([BGSFlutterNetworkOps sdkStageForWire:name], @"%@", name);
  }
  XCTAssertNil([BGSFlutterNetworkOps sdkStageForWire:nil]);
}

- (void)testNothingIsHandedOverWhileTheSdkIsNotAccepting {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  sdk.accepting = NO;
  NSInteger handed = [BGSFlutterNetworkOps
      addEventsWithSdk:sdk
                events:@[ Message(@"1", @"before"), Message(@"1", @"complete") ]];
  XCTAssertEqual(handed, 0);
  XCTAssertEqual(sdk.submitted.count, 0u);
}

- (void)testTheBatchIsHandedOverInOrderAndCounted {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  NSInteger handed = [BGSFlutterNetworkOps addEventsWithSdk:sdk
                                                     events:@[
                                                       Message(@"a", @"before"),
                                                       Message(@"a", @"complete"),
                                                       Message(@"b", @"error"),
                                                     ]];
  XCTAssertEqual(handed, 3);
  XCTAssertEqualObjects(([sdk.submitted valueForKey:@"ID"]), (@[ @"a", @"a", @"b" ]));
  XCTAssertEqual(sdk.acceptsCalls, 1);
}

- (void)testEveryFieldReachesTheSdkEvent {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  NSMutableDictionary *m = Message(@"req-1", @"complete");
  m[@"method"] = @"POST";
  m[@"url"] = @"https://example.com/x?y=1";
  m[@"size"] = @11;
  m[@"statusCode"] = @201;
  m[@"headers"] = @{@"content-type" : @"application/json"};
  m[@"body"] = @"{\"a\":\"bcde\"}";
  m[@"redirectedFromUrl"] = @"https://example.com/old";
  m[@"errorShortMessage"] = @"short";
  m[@"errorDescription"] = @"long";
  XCTAssertTrue([BGSFlutterNetworkOps addEventWithSdk:sdk event:m]);
  BugseeNetworkEvent *e = sdk.submitted.firstObject;
  XCTAssertEqualObjects(e.ID, @"req-1");
  XCTAssertEqualObjects(e.bugseeNetworkEventType, BugseeNetworkEventComplete);
  XCTAssertEqual(e.type, BugseeNetwork);
  XCTAssertEqualObjects(e.mechanism, @"dart:io");
  XCTAssertEqualObjects(e.method, @"POST");
  XCTAssertEqualObjects(e.url, @"https://example.com/x?y=1");
  XCTAssertEqualObjects(e.redirectedFromURL, @"https://example.com/old");
  XCTAssertEqualObjects(e.headers, @{@"content-type" : @"application/json"});
  XCTAssertEqualObjects(e.body, [@"{\"a\":\"bcde\"}" dataUsingEncoding:NSUTF8StringEncoding]);
  XCTAssertEqual(e.dataSize, 11);
  XCTAssertEqual(e.responseCode, 201);
  // iOS has one error text; the short one is what `custom.error` shows.
  XCTAssertEqualObjects(e.error[@"description"], @"short");
  XCTAssertFalse(e.override);
}

- (void)testTheLongErrorTextIsUsedWhenThereIsNoShortOne {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  NSMutableDictionary *m = Message(@"1", @"error");
  m[@"errorDescription"] = @"long only";
  [BGSFlutterNetworkOps addEventWithSdk:sdk event:m];
  XCTAssertEqualObjects(((BugseeNetworkEvent *)sdk.submitted.firstObject).error[@"description"], @"long only");
  BGSFakeNetworkSdk *plain = [BGSFakeNetworkSdk new];
  [BGSFlutterNetworkOps addEventWithSdk:plain event:Message(@"2", @"before")];
  XCTAssertNil(((BugseeNetworkEvent *)plain.submitted.firstObject).error);
}

- (void)testNoBodyCarriesTheReasonAndTheSize {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  NSMutableDictionary *m = Message(@"1", @"complete");
  m[@"size"] = @5000;
  m[@"noBodyReason"] = @"size_too_large";
  [BGSFlutterNetworkOps addEventWithSdk:sdk event:m];
  BugseeNetworkEvent *e = sdk.submitted.firstObject;
  XCTAssertNil(e.body);
  XCTAssertEqualObjects(e.noBodyReason, @"size_too_large");
  XCTAssertEqual(e.dataSize, 5000);
}

- (void)testTheTimestampIsTheSdksClockMinusTheAgeAndTheAgeIsClamped {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  NSMutableDictionary *fresh = Message(@"1", @"before");
  fresh[@"ageMs"] = @1500;
  NSMutableDictionary *negative = Message(@"2", @"before");
  negative[@"ageMs"] = @-5;
  NSMutableDictionary *ancient = Message(@"3", @"before");
  ancient[@"ageMs"] = @(LLONG_MAX);
  [BGSFlutterNetworkOps addEventsWithSdk:sdk events:@[ fresh, negative, ancient ]];
  XCTAssertEqual(((BugseeNetworkEvent *)sdk.submitted[0]).timestamp, 10000000000.0 - 1500.0);
  XCTAssertEqual(((BugseeNetworkEvent *)sdk.submitted[1]).timestamp, 10000000000.0);
  XCTAssertEqual(((BugseeNetworkEvent *)sdk.submitted[2]).timestamp,
                 10000000000.0 - (double)[BGSFlutterNetworkOps maxAgeMs]);
}

- (void)testAMalformedMessageIsRefusedAndTheRestOfTheBatchGoesOn {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  NSMutableDictionary *noId = Message(@"", @"before");
  NSMutableDictionary *noUrl = Message(@"2", @"before");
  noUrl[@"url"] = @"";
  NSMutableDictionary *noMechanism = Message(@"3", @"before");
  [noMechanism removeObjectForKey:@"mechanism"];
  NSInteger handed = [BGSFlutterNetworkOps
      addEventsWithSdk:sdk
                events:@[ noId, noUrl, noMechanism, @"not a dictionary", Message(@"4", @"before") ]];
  XCTAssertEqual(handed, 1);
  XCTAssertEqualObjects(((BugseeNetworkEvent *)sdk.submitted.firstObject).ID, @"4");
  XCTAssertEqual([BGSFlutterNetworkOps addEventsWithSdk:sdk events:nil], 0);
  XCTAssertEqual([BGSFlutterNetworkOps addEventsWithSdk:sdk events:@[]], 0);
}

- (void)testAStatusOutsideHttpIsZeroAndANegativeSizeIsZero {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  NSMutableDictionary *m = Message(@"1", @"complete");
  m[@"statusCode"] = @100000;
  m[@"size"] = @-9;
  [BGSFlutterNetworkOps addEventWithSdk:sdk event:m];
  BugseeNetworkEvent *e = sdk.submitted.firstObject;
  XCTAssertEqual(e.responseCode, 0);
  XCTAssertEqual(e.dataSize, 0);
}

- (void)testAFilterThatThrowsDropsThatEventNotTheBatchNorTheApp {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  sdk.throwOnId = @"boom";
  NSInteger handed = [BGSFlutterNetworkOps addEventsWithSdk:sdk
                                                     events:@[
                                                       Message(@"a", @"before"),
                                                       Message(@"boom", @"complete"),
                                                       Message(@"c", @"complete"),
                                                     ]];
  XCTAssertEqual(handed, 2);
  XCTAssertEqualObjects(([sdk.submitted valueForKey:@"ID"]), (@[ @"a", @"c" ]));
}

- (void)testNoChannelIsNotCountedAsHandedOver {
  BGSFakeNetworkSdk *sdk = [BGSFakeNetworkSdk new];
  sdk.channelAvailable = NO;
  XCTAssertEqual([BGSFlutterNetworkOps addEventsWithSdk:sdk events:@[ Message(@"1", @"before") ]], 0);
}

- (void)testTheChannelIsAlwaysAskedToFilterTheEvent {
  BGSFlutterNetworkChannel *holder = [BGSFlutterNetworkChannel shared];
  id previous = holder.channel;
  BGSFakeChannel *channel = [BGSFakeChannel new];
  holder.channel = channel;
  BGSFlutterRealNetworkSdk *sdk = [BGSFlutterRealNetworkSdk new];
  BugseeNetworkEvent *event = [BugseeNetworkEvent eventWithID:@"1"
                                                   HTTPmethod:@"GET"
                                                         type:BugseeNetwork
                                              bugseeEventType:BugseeNetworkEventBegin
                                                          url:@"https://e/"
                                                redirectedUrl:nil
                                                         body:nil
                                                        error:nil
                                                      headers:nil
                                                 noBodyReason:nil
                                                     dataSize:0
                                                 responseCode:0];
  XCTAssertTrue([sdk submitNetworkEvent:event]);
  XCTAssertEqual(channel.events.count, 1u);
  XCTAssertIdentical(channel.events.firstObject, event);
  // requiresFiltering:NO would skip the SDK's default sanitizer and the app's filter.
  XCTAssertEqualObjects(channel.flags.firstObject, @YES);
  holder.channel = nil;
  XCTAssertFalse([sdk submitNetworkEvent:event]);
  holder.channel = previous;
}

- (void)testTheWrapperStoresTheChannelTheSdkHandsItAndTheNewestRegistrationWins {
  BGSFlutterNetworkChannel *holder = [BGSFlutterNetworkChannel shared];
  id previous = holder.channel;
  BGSFakeChannel *first = [BGSFakeChannel new];
  BGSFakeChannel *second = [BGSFakeChannel new];
  id<BGSBugseeWrapper> wrapper =
      (id<BGSBugseeWrapper>)[BGSFlutterWrapper wrapperWithType:@"flutter" version:@"1" build:nil context:nil];
  [wrapper onWrapperChannelAvailable:first];
  XCTAssertIdentical(holder.channel, first);
  // Dart refines the identity: a NEW wrapper object is registered and gets a new channel.
  id<BGSBugseeWrapper> refined =
      (id<BGSBugseeWrapper>)[BGSFlutterWrapper wrapperWithType:@"flutter" version:@"1" build:nil context:nil];
  [refined onWrapperChannelAvailable:second];
  XCTAssertIdentical(holder.channel, second);
  holder.channel = previous;
}


/// The fixture is what Dart sends; this compares it with what the pinned framework really has:
/// the stage and reason constants, by value, and the stages the wrapper maps.
- (void)testTheFixtureIsTheSdksRealConstants {
  NSString *path = [[[@(__FILE__) stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"../../../../test/fixtures/network_wire.json"]
      stringByStandardizingPath];
  NSData *data = [NSData dataWithContentsOfFile:path];
  XCTAssertNotNil(data, @"%@", path);
  NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  XCTAssertEqualObjects([BGSFlutterNetworkOps stageNames], fixture[@"stages"]);
  NSDictionary<NSString *, NSString *> *constants = @{
    @"BugseeNetworkEventBegin" : BugseeNetworkEventBegin,
    @"BugseeNetworkEventComplete" : BugseeNetworkEventComplete,
    @"BugseeNetworkEventError" : BugseeNetworkEventError,
    @"BugseeNetworkEventCancel" : BugseeNetworkEventCancel,
  };
  NSDictionary *stages = fixture[@"iosStageConstants"];
  for (NSString *wire in stages) {
    // The wrapper's mapping for each wire stage is the SDK constant the fixture names.
    XCTAssertEqualObjects([BGSFlutterNetworkOps sdkStageForWire:wire], constants[stages[wire]], @"%@", wire);
  }
  NSDictionary<NSString *, NSString *> *reasonConstants = @{
    @"BugseeNetworkBodySizeTooLarge" : BugseeNetworkBodySizeTooLarge,
    @"BugseeNetworkBodyUnsupportedContentType" : BugseeNetworkBodyUnsupportedContentType,
    @"BugseeNetworkBodyNoContentType" : BugseeNetworkBodyNoContentType,
    @"BugseeNetworkBodyCantReadData" : BugseeNetworkBodyCantReadData,
  };
  NSDictionary *reasons = fixture[@"noBodyReasons"];
  NSDictionary *named = fixture[@"iosReasonConstants"];
  for (NSString *key in named) {
    XCTAssertEqualObjects(reasonConstants[named[key]], reasons[key], @"%@", key);
  }
  XCTAssertEqual([BGSFlutterNetworkOps maxAgeMs], [fixture[@"maxAgeMs"] longLongValue]);
}

@end
