#import <XCTest/XCTest.h>

#import "BGSFlutterCreatedReports.h"

/// The slot a created report lives in: one at a time, a deadline at every stage, and a stamp on every
/// reservation so a late SDK answer can never take a newer reservation's place.
@interface BGSCreatedTask : NSObject
@property(nonatomic, copy) dispatch_block_t block;
@property(nonatomic) int64_t delayMs;
@property(nonatomic) BOOL cancelled;
@end
@implementation BGSCreatedTask
@end

@interface BGSFlutterCreatedReportsTests : XCTestCase
@end

@implementation BGSFlutterCreatedReportsTests {
  BGSFlutterCreatedReports *_reports;
  NSMutableArray<BGSCreatedTask *> *_tasks;
  NSMutableArray *_expired;
  NSUInteger _timedOut;
}

- (void)setUp {
  _tasks = [NSMutableArray array];
  _expired = [NSMutableArray array];
  _timedOut = 0;
  __weak typeof(self) weakSelf = self;
  _reports = [[BGSFlutterCreatedReports alloc]
      initWithScheduler:^id(dispatch_block_t task, int64_t delayMs) {
        BGSCreatedTask *t = [[BGSCreatedTask alloc] init];
        t.block = task;
        t.delayMs = delayMs;
        [weakSelf.tasksForTest addObject:t];
        return t;
      }
      cancel:^(id token) {
        ((BGSCreatedTask *)token).cancelled = YES;
      }];
}

- (NSMutableArray<BGSCreatedTask *> *)tasksForTest {
  return _tasks;
}

- (NSUInteger)reserve {
  return [_reports reserveWithCreateTimeoutMs:1000 onTimeout:^{
    self->_timedOut++;
  }];
}

- (NSString *)fulfil:(NSUInteger)stamp report:(id)report ttl:(int64_t)ttl {
  return [_reports fulfil:stamp report:report ttlMs:ttl onExpired:^(id gone) {
    [self->_expired addObject:gone];
  }];
}

- (void)testASecondReservationIsRefusedWhileOneIsOpenOrHeld {
  const NSUInteger stamp = [self reserve];
  XCTAssertNotEqual(stamp, 0u);
  XCTAssertEqual([self reserve], 0u, @"reserved");
  NSString *handle = [self fulfil:stamp report:@"one" ttl:5000];
  XCTAssertNotNil(handle);
  XCTAssertEqual([self reserve], 0u, @"held");
  XCTAssertEqualObjects([_reports takeHandle:handle], @"one");
  XCTAssertNotEqual([self reserve], 0u, @"free again");
}

- (void)testHandlesAreNumberedAndNeverReused {
  NSString *first = [self fulfil:[self reserve] report:@"one" ttl:5000];
  [_reports takeHandle:first];
  NSString *second = [self fulfil:[self reserve] report:@"two" ttl:5000];
  XCTAssertEqualObjects(first, @"cr-1");
  XCTAssertEqualObjects(second, @"cr-2");
  XCTAssertNil([_reports reportForHandle:first]);
  XCTAssertEqualObjects([_reports reportForHandle:second], @"two");
}

- (void)testANilAnswerFreesTheSlotAndMintsNothing {
  XCTAssertNil([self fulfil:[self reserve] report:nil ttl:5000]);
  XCTAssertNotEqual([self reserve], 0u);
}

- (void)testTheCreateTimeoutFreesTheSlotAndTellsTheCaller {
  const NSUInteger stamp = [self reserve];
  BGSCreatedTask *timer = _tasks.lastObject;
  XCTAssertEqual(timer.delayMs, 1000);
  timer.block();
  XCTAssertEqual(_timedOut, 1u);
  XCTAssertNotEqual([self reserve], 0u, @"the slot is free");
  XCTAssertNil([self fulfil:stamp report:@"late" ttl:5000], @"the SDK's late answer is refused by its stamp");
}

- (void)testALateAnswerCannotTakeANewerReservationsPlace {
  const NSUInteger old = [self reserve];
  _tasks.lastObject.block();  // timed out
  const NSUInteger fresh = [self reserve];
  XCTAssertNotEqual(old, fresh);
  XCTAssertNil([self fulfil:old report:@"stale" ttl:5000]);
  XCTAssertTrue([_reports isReserved:fresh], @"the fresh reservation is intact");
  XCTAssertNotNil([self fulfil:fresh report:@"two" ttl:5000]);
}

- (void)testAFulfilCancelsTheCreateTimerAndAnAnswerAfterItDoesNothing {
  const NSUInteger stamp = [self reserve];
  BGSCreatedTask *createTimer = _tasks.lastObject;
  NSString *handle = [self fulfil:stamp report:@"one" ttl:5000];
  XCTAssertTrue(createTimer.cancelled);
  createTimer.block();  // fired anyway: the race
  XCTAssertEqual(_timedOut, 0u);
  XCTAssertEqualObjects([_reports reportForHandle:handle], @"one");
  XCTAssertNil([self fulfil:stamp report:@"two" ttl:5000], @"a second answer for the same stamp");
}

- (void)testTheTimeToLiveReleasesTheReportOnce {
  NSString *handle = [self fulfil:[self reserve] report:@"one" ttl:60000];
  BGSCreatedTask *ttl = _tasks.lastObject;
  XCTAssertEqual(ttl.delayMs, 60000);
  ttl.block();
  XCTAssertEqualObjects(_expired, @[ @"one" ]);
  XCTAssertNil([_reports reportForHandle:handle]);
  ttl.block();  // the race again
  XCTAssertEqual(_expired.count, 1u, @"released once");
  XCTAssertNotEqual([self reserve], 0u);
}

- (void)testTakeCancelsTheTimeToLiveSoAnUploadedReportIsNotDiscarded {
  NSString *handle = [self fulfil:[self reserve] report:@"one" ttl:60000];
  BGSCreatedTask *ttl = _tasks.lastObject;
  XCTAssertEqualObjects([_reports takeHandle:handle], @"one");
  XCTAssertTrue(ttl.cancelled);
  ttl.block();
  XCTAssertEqual(_expired.count, 0u, @"a taken report is not expired");
  XCTAssertNil([_reports takeHandle:handle], @"a second take");
}

- (void)testAnUnknownHandleTakesAndGetsNothing {
  NSString *handle = [self fulfil:[self reserve] report:@"one" ttl:5000];
  XCTAssertNil([_reports reportForHandle:@"cr-99"]);
  XCTAssertNil([_reports takeHandle:@"cr-99"]);
  XCTAssertNil([_reports takeHandle:nil]);
  XCTAssertEqualObjects([_reports reportForHandle:handle], @"one");
}

- (void)testClearReleasesWhatIsHeldAndInvalidatesOpenStamps {
  const NSUInteger open = [self reserve];
  XCTAssertNil([_reports clear]);
  XCTAssertNil([self fulfil:open report:@"one" ttl:5000]);
  NSString *handle = [self fulfil:[self reserve] report:@"two" ttl:5000];
  XCTAssertEqualObjects([_reports clear], @"two");
  XCTAssertNil([_reports reportForHandle:handle]);
  XCTAssertNotEqual([self reserve], 0u);
}

@end
