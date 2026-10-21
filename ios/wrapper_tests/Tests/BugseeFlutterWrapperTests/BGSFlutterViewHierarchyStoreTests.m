#import <XCTest/XCTest.h>

#import "BGSFlutterSecureRectangleStore.h"
#import "BGSFlutterViewHierarchyStore.h"

/// The managed view hierarchy cache (the SDK's `vh`) on iOS: what is served, in which unit (points,
/// the unit of the native tree), and every case that must serve nothing instead.

/// A screen a test can change between answers. A 3x phone: a Flutter logical pixel is a point.
@interface BGSVHScreen : NSObject <BGSFlutterSecureEnvironment>
@property(nonatomic) double nativeRatio;
@property(nonatomic) double units;
@end
@implementation BGSVHScreen
- (instancetype)init {
  if ((self = [super init])) {
    _nativeRatio = 3;
    _units = 1.0 / 3;
  }
  return self;
}
- (double)nativePixelRatioForDisplay:(NSInteger)display {
  return _nativeRatio;
}
- (double)unitsPerPhysicalPixelForDisplay:(NSInteger)display {
  return _units;
}
- (CGSize)displayBoundsInPointsForDisplay:(NSInteger)display {
  return CGSizeMake(402, 874);
}
@end

/// A clock a test moves.
@interface BGSVHClock : NSObject
@property(nonatomic) NSTimeInterval now;
@end
@implementation BGSVHClock
@end

static NSData *Doubles(const double *values, NSUInteger count) {
  return [NSData dataWithBytes:values length:count * sizeof(double)];
}
#define BOUNDS(...)                                       \
  ({                                                      \
    double b_[] = {__VA_ARGS__};                          \
    Doubles(b_, sizeof(b_) / sizeof(double));             \
  })

@interface BGSFlutterViewHierarchyStoreTests : XCTestCase
@end

@implementation BGSFlutterViewHierarchyStoreTests {
  BGSVHScreen *_screen;
  BGSFlutterSecureRectangleStore *_placement;
  BGSFlutterViewHierarchyStore *_store;
  BGSVHClock *_clock;
  int64_t _sequence;
}

static const int64_t kOwner = 1;

- (void)setUp {
  _screen = [[BGSVHScreen alloc] init];
  BGSVHClock *clock = [[BGSVHClock alloc] init];
  clock.now = 100;
  _clock = clock;
  _placement = [[BGSFlutterSecureRectangleStore alloc] initWithEnvironment:_screen
                                                                     clock:^NSTimeInterval {
                                                                       return clock.now;
                                                                     }
                                                                     grace:0];
  _store = [[BGSFlutterViewHierarchyStore alloc] initWithPlacement:_placement
                                                             clock:^NSTimeInterval {
                                                               return clock.now;
                                                             }];
  [_store setRefresher:nil];
  _sequence = 0;
}

/// Two nodes: `A{age}B<box0>C<box1>D`.
- (NSArray<NSString *> *)template {
  return @[ @"A", @"B", @"C", @"D" ];
}

- (BOOL)publishOwner:(int64_t)owner
               epoch:(int64_t)epoch
            sequence:(int64_t)sequence
               ratio:(double)ratio
            segments:(NSArray<NSString *> *)segments
              bounds:(NSData *)bounds {
  return [_store publishForOwner:owner
                           epoch:epoch
                        sequence:sequence
                          viewId:0
                           ratio:ratio
                        segments:segments
                          bounds:bounds];
}

- (void)place:(BGSFlutterSecurePlacement *)placement owner:(int64_t)owner {
  [_placement setPlacement:placement forOwner:owner viewId:0];
}

/// Publishes the two-node template for owner 1 at the screen's ratio, the view at (x, y).
- (void)publishPlacedAtX:(double)x y:(double)y bounds:(NSData *)bounds {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:x y:y] owner:kOwner];
  XCTAssertTrue([self publishOwner:kOwner
                             epoch:1
                          sequence:++_sequence
                             ratio:_screen.nativeRatio
                          segments:[self template]
                            bounds:bounds]);
}

#pragma mark - nothing

- (void)testNothingPublishedAnswersNil {
  XCTAssertNil([_store answer]);
}

- (void)testASnapshotThatCannotBePlacedAnswersNil {
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:1 ratio:3 segments:[self template]
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)]);
  XCTAssertNil([_store answer]);
  [self place:[BGSFlutterSecurePlacement unknown] owner:kOwner];
  XCTAssertNil([_store answer]);
}

/// In no window: nothing of Flutter can be drawn.
- (void)testAViewKnownToBeOffScreenAnswersNil {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  XCTAssertNotNil([_store answer]);
  [self place:[BGSFlutterSecurePlacement absent] owner:kOwner];
  XCTAssertNil([_store answer]);
}

#pragma mark - unit and placement (workbook 5.3, 6.6)

/// iOS: POINTS. On a 3x screen a Flutter logical pixel IS a point, so nothing is multiplied by 3
/// (the Android rule would give 300 here).
- (void)testOnA3xScreenLogicalPixelsAreServedAsPointsNotMultipliedByTheScale {
  [self publishPlacedAtX:30 y:60 bounds:BOUNDS(0, 0, 100, 200, 10, 20, 50, 40)];
  XCTAssertEqualObjects([_store answer], @"A0B[30,60,100,200]C[40,80,40,20]D");
}

/// A factor that is neither 1 nor whole: scaled first, rounded outward after.
- (void)testEdgesRoundOutwardAfterScaling {
  _screen.units = 1.5 / 3;  // ratio * units = 1.5
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 1, 1, 1.25, 2.25, 1.5, 2.5)];
  // 1.875 -> 1, 3.375 -> 3, 2.25 -> 3, 3.75 -> 4: width 2, height 1
  XCTAssertEqualObjects([_store answer], @"A0B[0,0,2,2]C[1,3,2,1]D");
}

- (void)testTheViewsOwnScaleOnScreenIsApplied {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:10 y:10 scaleX:0.5 scaleY:0.5] owner:kOwner];
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:1 ratio:3 segments:[self template]
                            bounds:BOUNDS(0, 0, 100, 100, 0, 0, 10, 10)]);
  // 100 * 1 * 0.5 + 10 = 60 -> [10,10,50,50]; 10 * 0.5 + 10 = 15 -> [10,10,5,5]
  XCTAssertEqualObjects([_store answer], @"A0B[10,10,50,50]C[10,10,5,5]D");
}

/// The same point is in the same place for the secure rectangles and the hierarchy.
- (void)testTheSamePlaceAsTheSecureRectangles {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:17 y:29 scaleX:0.75 scaleY:0.5] owner:kOwner];
  double box[] = {3.3, 4.7, 21.2, 30.9};
  [_placement publishForOwner:kOwner epoch:1 sequence:1
                        views:@{@0 : [[BGSFlutterSecureViewRects alloc] initWithRatio:3 rects:Doubles(box, 4)]}];
  NSData *buffer = [_placement snapshotForDisplay:0];
  const int32_t *secure = buffer.bytes;  // [version, count, l, t, r, b]
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:1 ratio:3 segments:(@[ @"A", @"B", @"C" ])
                            bounds:Doubles(box, 4)]);
  NSString *expected = [NSString stringWithFormat:@"A0B[%d,%d,%d,%d]C", secure[2], secure[3],
                                                  secure[4] - secure[2], secure[5] - secure[3]];
  XCTAssertEqualObjects([_store answer], expected);
}

/// Boxes measured at one scale are not served after the screen changed scale.
- (void)testARatioThatNoLongerMatchesAnswersNil {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  XCTAssertNotNil([_store answer]);
  _screen.nativeRatio = 2;
  XCTAssertNil([_store answer]);
  _screen.nativeRatio = 3;
  XCTAssertNotNil([_store answer], @"matches again");
}

- (void)testABoxThatIsNotFiniteAnswersNilNotAPartialDocument {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, NAN, 5)];
  XCTAssertNil([_store answer]);
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, INFINITY, 5, 5)];
  XCTAssertNil([_store answer]);
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 1e300, 5)];
  XCTAssertNil([_store answer], @"beyond what the SDK's arithmetic can take");
}

#pragma mark - age

- (void)testTheAgeIsMeasuredWhenTheAnswerIsGiven {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  XCTAssertTrue([[_store answer] hasPrefix:@"A0B"]);
  _clock.now += 2.5;
  XCTAssertTrue([[_store answer] hasPrefix:@"A2500B"]);
}

#pragma mark - refresh hook

/// The SDK asks on the main thread, so the refresh runs there, before every answer, and a throw
/// from it does not stop the answer.
- (void)testTheRefresherRunsBeforeEveryAnswerAndMayThrow {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  __block int runs = 0;
  [_store setRefresher:^{
    runs++;
    [NSException raise:NSInternalInconsistencyException format:@"could not refresh"];
  }];
  XCTAssertNotNil([_store answer]);
  XCTAssertNotNil([_store answer]);
  XCTAssertEqual(runs, 2);
}

/// By default the refresh is the placement store's: the one a pull makes.
- (void)testTheDefaultRefresherIsThePlacementStoresPullHook {
  BGSFlutterViewHierarchyStore *fresh = [[BGSFlutterViewHierarchyStore alloc]
      initWithPlacement:_placement
                  clock:^NSTimeInterval {
                    return 0;
                  }];
  __block int pulls = 0;
  [_placement setPullHook:^{
    pulls++;
  }];
  (void)[fresh answer];
  XCTAssertEqual(pulls, 1);
}

#pragma mark - shape, size, clearing

- (void)testEmptySegmentsClearTheSnapshot {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  XCTAssertNotNil([_store answer]);
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:++_sequence ratio:1 segments:@[] bounds:[NSData data]]);
  XCTAssertNil([_store answer]);
}

- (void)testAMalformedMessageClearsWhatWasThere {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  // 3 segments for 2 nodes: one short.
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:++_sequence ratio:3 segments:(@[ @"A", @"B", @"C" ])
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)]);
  XCTAssertNil([_store answer]);
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  // Seven numbers: not a whole number of boxes.
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:++_sequence ratio:3 segments:[self template]
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5)]);
  XCTAssertNil([_store answer]);
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  // A segment that is not a string.
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:++_sequence ratio:3
                          segments:(NSArray<NSString *> *)(@[ @"A", @1, @"C", @"D" ])
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)]);
  XCTAssertNil([_store answer]);
}

- (void)testAnOversizeTemplateClearsWhatWasThere {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  NSUInteger limit = [BGSFlutterViewHierarchyStore maxTemplateCharacters];
  NSString *huge = [@"" stringByPaddingToLength:limit withString:@"x" startingAtIndex:0];
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:++_sequence ratio:3
                          segments:(@[ huge, @"B", @"C", @"D" ])
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)]);
  XCTAssertNil([_store answer]);
  // Exactly at the limit is accepted.
  NSString *fits = [huge substringToIndex:limit - 3];
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:++_sequence ratio:3
                          segments:(@[ fits, @"B", @"C", @"D" ])
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)]);
  XCTAssertNotNil([_store answer]);
}

#pragma mark - immutability

/// What was sent is what is served, whatever happens to the caller's objects afterwards.
- (void)testWhatWasPublishedCannotBeChangedFromOutside {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] owner:kOwner];
  NSMutableArray<NSString *> *segments = [[self template] mutableCopy];
  NSMutableData *bounds = [BOUNDS(0, 0, 10, 10, 0, 0, 5, 5) mutableCopy];
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:1 ratio:3 segments:segments bounds:bounds]);
  NSString *before = [_store answer];
  segments[0] = @"X";
  [segments removeAllObjects];
  memset(bounds.mutableBytes, 0x7f, bounds.length);
  XCTAssertEqualObjects([_store answer], before);
}

#pragma mark - ordering

- (void)testAnOlderSequenceIsIgnoredAndKeepsWhatWasThere {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] owner:kOwner];
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:5 ratio:3 segments:[self template]
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)]);
  NSString *served = [_store answer];
  XCTAssertFalse([self publishOwner:kOwner epoch:1 sequence:5 ratio:3 segments:[self template]
                             bounds:BOUNDS(0, 0, 99, 99, 0, 0, 5, 5)]);
  XCTAssertFalse([self publishOwner:kOwner epoch:1 sequence:4 ratio:1 segments:@[] bounds:[NSData data]]);
  XCTAssertEqualObjects([_store answer], served);
}

- (void)testANewEpochIsANewIsolateAndReplacesTheOldOne {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] owner:kOwner];
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:50 ratio:3 segments:[self template]
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)]);
  // A hot restart: a fresh epoch whose counter starts again at 1.
  XCTAssertTrue([self publishOwner:kOwner epoch:2 sequence:1 ratio:3 segments:[self template]
                            bounds:BOUNDS(0, 0, 20, 20, 0, 0, 5, 5)]);
  XCTAssertEqualObjects([_store answer], @"A0B[0,0,20,20]C[0,0,5,5]D");
}

- (void)testARetiredEpochsStragglerIsIgnored {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] owner:kOwner];
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:1 ratio:3 segments:[self template]
                            bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)]);
  XCTAssertTrue([self publishOwner:kOwner epoch:2 sequence:1 ratio:3 segments:[self template]
                            bounds:BOUNDS(0, 0, 20, 20, 0, 0, 5, 5)]);
  XCTAssertFalse([self publishOwner:kOwner epoch:1 sequence:99 ratio:1 segments:@[] bounds:[NSData data]],
                 @"the dead isolate's late message");
  XCTAssertEqualObjects([_store answer], @"A0B[0,0,20,20]C[0,0,5,5]D");
}

#pragma mark - owners

- (void)testADetachedEngineServesNothingEvenThoughItsViewWasPlaced {
  [self publishPlacedAtX:0 y:0 bounds:BOUNDS(0, 0, 10, 10, 0, 0, 5, 5)];
  XCTAssertNotNil([_store answer]);
  [_store dropOwner:kOwner];
  XCTAssertNil([_store answer]);
}

- (void)testWithSeveralEnginesTheNewestSnapshotIsServedAndOnlyIfItCanBePlaced {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] owner:1];
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] owner:2];
  XCTAssertTrue([self publishOwner:1 epoch:1 sequence:1 ratio:3 segments:(@[ @"one", @"B", @"C", @"D" ])
                            bounds:BOUNDS(0, 0, 1, 1, 0, 0, 1, 1)]);
  _clock.now += 0.01;
  XCTAssertTrue([self publishOwner:2 epoch:1 sequence:1 ratio:3 segments:(@[ @"two", @"B", @"C", @"D" ])
                            bounds:BOUNDS(0, 0, 1, 1, 0, 0, 1, 1)]);
  XCTAssertTrue([[_store answer] hasPrefix:@"two"]);
  // The newest cannot be placed: nothing is served, not the other engine's older tree.
  [self place:[BGSFlutterSecurePlacement unknown] owner:2];
  XCTAssertNil([_store answer]);
  [_store dropOwner:2];
  XCTAssertTrue([[_store answer] hasPrefix:@"one"]);
}

#pragma mark - thread safety

/// Writers swap between two whole snapshots while readers answer: every answer is one of the two,
/// complete, never a mixture (5.4.1).
- (void)testConcurrentPublishAndAnswerNeverTear {
  [self place:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] owner:kOwner];
  NSArray *first = @[ @"AAAA", @"-", @"AAAA", @"AAAA" ];
  NSArray *second = @[ @"BBBB", @"-", @"BBBB", @"BBBB" ];
  NSData *boxA = BOUNDS(0, 0, 1, 1, 0, 0, 2, 2);
  NSData *boxB = BOUNDS(0, 0, 3, 3, 0, 0, 4, 4);
  XCTAssertTrue([self publishOwner:kOwner epoch:1 sequence:1 ratio:3 segments:first bounds:boxA]);
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  NSObject *seenLock = [[NSObject alloc] init];
  __block BOOL stop = NO;
  dispatch_group_t group = dispatch_group_create();
  NSRegularExpression *age = [NSRegularExpression regularExpressionWithPattern:@"(AAAA|BBBB)\\d+" options:0 error:nil];
  for (int i = 0; i < 3; i++) {
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      while (!stop) {
        NSString *s = [self->_store answer];
        if (s != nil) {
          NSString *stripped = [age stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"$1"];
          @synchronized(seenLock) {
            [seen addObject:stripped];
          }
        }
      }
    });
  }
  int64_t seq = 100;
  for (int i = 0; i < 20000; i++) {
    [self publishOwner:kOwner epoch:1 sequence:++seq ratio:3 segments:(i % 2 == 0 ? second : first)
                bounds:(i % 2 == 0 ? boxB : boxA)];
  }
  stop = YES;
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
  NSSet *allowed = [NSSet setWithArray:@[ @"AAAA-[0,0,1,1]AAAA[0,0,2,2]AAAA", @"BBBB-[0,0,3,3]BBBB[0,0,4,4]BBBB" ]];
  XCTAssertTrue([seen isSubsetOfSet:allowed], @"only whole snapshots, got %@", seen);
  XCTAssertTrue(seen.count > 0);
}

@end
