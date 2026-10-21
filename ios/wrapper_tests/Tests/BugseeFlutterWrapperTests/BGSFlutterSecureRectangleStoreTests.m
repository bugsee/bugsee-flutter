#import <XCTest/XCTest.h>

#import "BGSFlutterSecurePlacementTracker.h"
#import "BGSFlutterSecureRectangleStore.h"

/// Workbook Part 5 on iOS: units, rounding, versions, ownership. The SDK's unit here is POINTS in
/// the screen's coordinate space (BGSContracts.h, `secureRectanglesForDisplay:`).

/// A device a test can change between pulls.
@interface BGSMockScreen : NSObject <BGSFlutterSecureEnvironment>
@property(nonatomic) double factor;
@property(nonatomic) CGSize bounds;
@property(nonatomic) NSInteger scaleReads;
@end

@implementation BGSMockScreen
- (instancetype)init {
  if ((self = [super init])) {
    _factor = 1;  // a logical pixel is a point
    _bounds = CGSizeMake(402, 874);  // iPhone 17 Pro, points
  }
  return self;
}
- (double)pointsPerLogicalPixelForDisplay:(NSInteger)display {
  _scaleReads++;
  return _factor;
}
- (CGSize)displayBoundsInPointsForDisplay:(NSInteger)display {
  return _bounds;
}
@end

@interface BGSFlutterSecureRectangleStoreTests : XCTestCase
@end

@implementation BGSFlutterSecureRectangleStoreTests {
  BGSMockScreen *_screen;
  BGSFlutterSecureRectangleStore *_store;
  int64_t _sequence;
}

- (void)setUp {
  _screen = [[BGSMockScreen alloc] init];
  _store = [[BGSFlutterSecureRectangleStore alloc] initWithEnvironment:_screen];
  _sequence = 0;
}

static NSData *Doubles(const double *values, NSUInteger count) {
  return [NSData dataWithBytes:values length:count * sizeof(double)];
}
#define VIEW(...)                                          \
  ({                                                       \
    double v_[] = {__VA_ARGS__};                           \
    @{@0 : Doubles(v_, sizeof(v_) / sizeof(double))};      \
  })

static NSArray<NSNumber *> *Ints(NSData *buffer) {
  NSMutableArray *out = [NSMutableArray array];
  const int32_t *p = buffer.bytes;
  for (NSUInteger i = 0; i < buffer.length / 4; i++) [out addObject:@(p[i])];
  return out;
}

/// `[count, l, t, r, b, ...]`: the buffer without its version.
static NSArray<NSNumber *> *WithoutVersion(NSData *buffer) {
  NSArray *all = Ints(buffer);
  return [all subarrayWithRange:NSMakeRange(1, all.count - 1)];
}

static int32_t VersionOf(NSData *buffer) {
  return ((const int32_t *)buffer.bytes)[0];
}

- (BOOL)publishViews:(NSDictionary<NSNumber *, NSData *> *)views {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  return [_store publishForOwner:1 epoch:1 sequence:++_sequence views:views];
}
#define PUBLISH(...) XCTAssertTrue([self publishViews:VIEW(__VA_ARGS__)])

#pragma mark - empty

- (void)testADisplayThatNeverHadARectangleIsUnknownAndEmpty {
  XCTAssertEqualObjects(Ints([_store snapshotForDisplay:0]), (@[ @0, @0 ]));
}

- (void)testAfterARectangleVersionsAreRealAndAnEmptiedSetIsStillCounted {
  PUBLISH(1, 1, 2, 2);
  NSData *full = [_store snapshotForDisplay:0];
  XCTAssertEqual(((const int32_t *)full.bytes)[1], 1);
  XCTAssertNotEqual(VersionOf(full), 0);
  XCTAssertTrue([_store publishForOwner:1 epoch:1 sequence:++_sequence views:@{}]);
  NSData *empty = [_store snapshotForDisplay:0];
  XCTAssertEqual(((const int32_t *)empty.bytes)[1], 0);
  XCTAssertNotEqual(VersionOf(empty), VersionOf(full), @"emptying is a change");
  XCTAssertNotEqual(VersionOf(empty), 0);
}

#pragma mark - unit (5.3) and rounding (5.1.2)

/// Workbook 5.3.3: the check must not pass vacuously, so this runs against the real UIScreen and
/// refuses to run where its scale is 1. On a 3x screen the factor is 1, NOT the screen's scale.
- (void)testTheUIKitFactorIsOneNotTheScreensScale {
  BGSFlutterUIKitEnvironment *env = [[BGSFlutterUIKitEnvironment alloc] init];
  UIScreen *screen = [UIScreen mainScreen];
  [env updateWithScreen:screen];
  XCTAssertNotEqual(screen.scale, 1.0, @"run on a 2x/3x simulator: at scale 1 this test proves nothing");
  XCTAssertEqual([env pointsPerLogicalPixelForDisplay:0], 1.0);
  XCTAssertTrue(CGSizeEqualToSize([env displayBoundsInPointsForDisplay:0], screen.bounds.size));
}

/// On a 3x screen Flutter's logical pixels are points: nothing is multiplied by 3, which is what
/// treating them as physical pixels (the Android rule) would do.
- (void)testOnA3xScreenLogicalPixelsAreServedAsPointsNotMultipliedByTheScale {
  _screen.factor = 1;
  PUBLISH(10, 20, 100, 50);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @10, @20, @100, @50 ]));
}

/// A factor that is not 1 and not whole: scale first, round outward after.
- (void)testScalesToPointsThenRoundsOutward {
  _screen.factor = 1.5;
  PUBLISH(1.25, 2.25, 1.5, 2.5);
  // 1.875 -> 1, 3.375 -> 3, 2.25 -> 3, 3.75 -> 4
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @1, @3, @3, @4 ]));
}

- (void)testRoundsAfterScalingNotBefore {
  _screen.factor = 1.5;
  PUBLISH(1.25, 0, 1.5, 1);
  NSArray *s = WithoutVersion([_store snapshotForDisplay:0]);
  // Rounding first would give floor(1.25)*1.5 = 1.5 -> 1 and ceil(1.5)*1.5 = 3.
  XCTAssertEqualObjects(s[1], @1);
  XCTAssertEqualObjects(s[3], @3);
  // ceil(1.5*1.5 = 2.25) = 3, so no sub-point strip is left; round-to-nearest would give 2.
}

- (void)testLeftAndTopFloorRightAndBottomCeil {
  _screen.factor = 1.5;
  PUBLISH(0.9, 0.9, 1.1, 1.1);
  // 1.35 -> 1, 1.65 -> 2
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @1, @1, @2, @2 ]));
}

- (void)testRightAndBottomAreExclusiveSoExactEdgesAreNotWidened {
  PUBLISH(0, 0, 10, 20);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @10, @20 ]));
}

- (void)testDegenerateRectanglesAreDropped {
  PUBLISH(5, 5, 5, 10, 5, 5, 10, 5, 10, 10, 5, 20, 1.25, 1, 1.25, 2, 1, 1, 2, 2);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @1, @1, @2, @2 ]));
}

/// The factor is read at every pull (5.3.2).
- (void)testTheScaleIsReadPerCall {
  _screen.factor = 1;
  PUBLISH(10, 10, 20, 20);
  NSData *at1 = [_store snapshotForDisplay:0];
  XCTAssertEqualObjects(WithoutVersion(at1), (@[ @1, @10, @10, @20, @20 ]));
  _screen.factor = 2.0 / 3.0;
  NSData *at2 = [_store snapshotForDisplay:0];
  XCTAssertEqualObjects(WithoutVersion(at2), (@[ @1, @6, @6, @14, @14 ]));  // 6.67 -> 6, 13.33 -> 14
  XCTAssertNotEqual(VersionOf(at1), VersionOf(at2), @"a scale change moves the version");
  XCTAssertGreaterThanOrEqual(_screen.scaleReads, 2);
}

- (void)testASetWithNoScaleChangeKeepsItsVersionAcrossPulls {
  PUBLISH(10, 10, 20, 20);
  int32_t v = VersionOf([_store snapshotForDisplay:0]);
  for (int i = 0; i < 5; i++) XCTAssertEqual(VersionOf([_store snapshotForDisplay:0]), v);
}

#pragma mark - coordinate space

- (void)testTheViewsPositionOnTheScreenIsAdded {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:20.5] forOwner:1 viewId:0];
  double v[] = {10, 10, 20, 20};
  [_store publishForOwner:1 epoch:1 sequence:1 views:@{@0 : Doubles(v, 4)}];
  // y: floor(30.5) = 30, ceil(40.5) = 41
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @10, @30, @20, @41 ]));
}

- (void)testMovingTheViewMovesTheRectanglesAndTheVersion {
  PUBLISH(10, 10, 20, 20);
  NSData *before = [_store snapshotForDisplay:0];
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:100 y:0] forOwner:1 viewId:0];
  NSData *after = [_store snapshotForDisplay:0];
  XCTAssertEqualObjects(WithoutVersion(after), (@[ @1, @110, @10, @120, @20 ]));
  XCTAssertNotEqual(VersionOf(before), VersionOf(after));
}

- (void)testRectanglesAreClampedToTheScreenAndOnesOffItAreDropped {
  PUBLISH(-10, -10, 5, 5, 300, 800, 500, 900, 1000, 1000, 1100, 1100);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]),
                        (@[ @2, @0, @0, @5, @5, @300, @800, @402, @874 ]));
}

#pragma mark - fail closed

- (void)testAViewWhosePlacementIsUnknownCoversTheWholeScreen {
  double v[] = {10, 10, 20, 20};
  [_store publishForOwner:1 epoch:1 sequence:1 views:@{@0 : Doubles(v, 4)}];  // no placement
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @402, @874 ]));
  [_store setPlacement:[BGSFlutterSecurePlacement unknown] forOwner:1 viewId:0];
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @402, @874 ]));
}

- (void)testAWholeScreenCoverUsesTheFallbackSizeWhenTheScreenIsUnknown {
  _screen.bounds = CGSizeZero;
  double v[] = {10, 10, 20, 20};
  [_store publishForOwner:1 epoch:1 sequence:1 views:@{@0 : Doubles(v, 4)}];
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @16384, @16384 ]));
}

- (void)testAViewKnownToBeOffScreenServesNothing {
  [_store setPlacement:[BGSFlutterSecurePlacement absent] forOwner:1 viewId:0];
  double v[] = {10, 10, 20, 20};
  [_store publishForOwner:1 epoch:1 sequence:1 views:@{@0 : Doubles(v, 4)}];
  XCTAssertEqual(((const int32_t *)[_store snapshotForDisplay:0].bytes)[1], 0);
  [_store setPlacement:[BGSFlutterSecurePlacement unknown] forOwner:1 viewId:0];
  XCTAssertEqual(((const int32_t *)[_store snapshotForDisplay:0].bytes)[1], 1);
}

- (void)testARectangleThatIsNotFiniteCoversTheWholeScreen {
  PUBLISH(1, 1, 2, 2, NAN, 0, 5, 5);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @402, @874 ]));
  PUBLISH(1, 1, 2, 2, 0, 0, INFINITY, 5);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @402, @874 ]));
}

- (void)testAScaleThatIsNotUsableCoversTheWholeScreen {
  PUBLISH(1, 1, 2, 2);
  for (NSNumber *bad in @[ @0, @-1, @(NAN), @(INFINITY) ]) {
    _screen.factor = bad.doubleValue;
    XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @402, @874 ]),
                          @"factor %@", bad);
  }
}

- (void)testAMalformedViewListCoversTheWholeScreen {
  PUBLISH(1, 2, 3);  // not a multiple of four
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @402, @874 ]));
}

- (void)testAViewOtherThanTheImplicitOneIsNotPlacedSoItCoversTheScreen {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  double v[] = {1, 1, 2, 2};
  [_store publishForOwner:1 epoch:1 sequence:1 views:@{@7 : Doubles(v, 4)}];
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @0, @0, @402, @874 ]));
}

#pragma mark - versions (5.2)

- (void)testANoOpWriteDoesNotMoveTheVersion {
  PUBLISH(1, 1, 2, 2);
  int32_t v = VersionOf([_store snapshotForDisplay:0]);
  for (int i = 0; i < 4; i++) {
    PUBLISH(1, 1, 2, 2);
    XCTAssertEqual(VersionOf([_store snapshotForDisplay:0]), v);
  }
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  XCTAssertEqual(VersionOf([_store snapshotForDisplay:0]), v);
}

/// Workbook 5.2.4: a store that held the version constant across a change would fail here.
- (void)testEveryKindOfRealChangeMovesTheVersion {
  PUBLISH(1, 1, 2, 2);
  __block int32_t last = VersionOf([_store snapshotForDisplay:0]);
  void (^expectMoved)(NSString *) = ^(NSString *what) {
    int32_t v = VersionOf([self->_store snapshotForDisplay:0]);
    XCTAssertNotEqual(v, last, @"%@", what);
    last = v;
  };
  PUBLISH(1, 1, 3, 2);
  expectMoved(@"resize");
  PUBLISH(2, 1, 4, 2);
  expectMoved(@"move");
  PUBLISH(2, 1, 4, 2, 10, 10, 11, 11);
  expectMoved(@"add");
  PUBLISH(2, 1, 4, 2);
  expectMoved(@"remove one");
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:1 y:0] forOwner:1 viewId:0];
  expectMoved(@"view moved");
  _screen.factor = 1.5;
  expectMoved(@"scale");
  _screen.bounds = CGSizeMake(3, 3);
  expectMoved(@"screen size");
}

- (void)testASetThatComesBackStillGetsANewVersion {
  PUBLISH(1, 1, 2, 2);
  int32_t a = VersionOf([_store snapshotForDisplay:0]);
  PUBLISH(5, 5, 6, 6);
  int32_t b = VersionOf([_store snapshotForDisplay:0]);
  PUBLISH(1, 1, 2, 2);
  int32_t c = VersionOf([_store snapshotForDisplay:0]);
  XCTAssertNotEqual(a, b);
  XCTAssertNotEqual(b, c);
  XCTAssertNotEqual(a, c, @"the SDK cached a by version; c must not look like a");
}

- (void)testVersionsNeverLandOnZero {
  XCTAssertEqual([BGSFlutterSecureRectangleStore versionAfter:-1], 1);
  XCTAssertEqual([BGSFlutterSecureRectangleStore versionAfter:INT32_MAX], INT32_MIN);
  XCTAssertEqual([BGSFlutterSecureRectangleStore versionAfter:4], 5);
}

- (void)testVersionsArePerDisplay {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:1 x:0 y:0] forOwner:2 viewId:0];
  double a[] = {1, 1, 2, 2}, b[] = {4, 4, 5, 5};
  [_store publishForOwner:1 epoch:1 sequence:1 views:@{@0 : Doubles(a, 4)}];
  [_store publishForOwner:2 epoch:1 sequence:1 views:@{@0 : Doubles(b, 4)}];
  int32_t d0 = VersionOf([_store snapshotForDisplay:0]);
  int32_t d1 = VersionOf([_store snapshotForDisplay:1]);
  XCTAssertEqual(d0, VersionOf([_store snapshotForDisplay:0]));
  XCTAssertEqual(d1, VersionOf([_store snapshotForDisplay:1]));
  double b2[] = {1, 1, 9, 9};
  [_store publishForOwner:2 epoch:1 sequence:2 views:@{@0 : Doubles(b2, 4)}];
  XCTAssertEqual(d0, VersionOf([_store snapshotForDisplay:0]));
  XCTAssertNotEqual(d1, VersionOf([_store snapshotForDisplay:1]));
  XCTAssertEqual(((const int32_t *)[_store snapshotForDisplay:2].bytes)[1], 0);
}

#pragma mark - ordering

- (void)testADelayedOlderMessageNeverOverwritesANewerOne {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  double a[] = {1, 1, 2, 2}, old[] = {7, 7, 8, 8}, b[] = {2, 2, 3, 3};
  XCTAssertTrue([_store publishForOwner:1 epoch:5 sequence:10 views:@{@0 : Doubles(a, 4)}]);
  XCTAssertFalse([_store publishForOwner:1 epoch:5 sequence:9 views:@{@0 : Doubles(old, 4)}], @"older sequence");
  XCTAssertFalse([_store publishForOwner:1 epoch:5 sequence:10 views:@{@0 : Doubles(old, 4)}], @"same sequence");
  XCTAssertFalse([_store publishForOwner:1 epoch:4 sequence:99 views:@{@0 : Doubles(old, 4)}], @"older epoch");
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @1, @1, @2, @2 ]));
  XCTAssertTrue([_store publishForOwner:1 epoch:5 sequence:11 views:@{@0 : Doubles(b, 4)}]);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @2, @2, @3, @3 ]));
}

- (void)testANewIsolateWinsEvenThoughItsCounterRestarted {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  double a[] = {1, 1, 2, 2}, b[] = {2, 2, 3, 3};
  XCTAssertTrue([_store publishForOwner:1 epoch:5 sequence:500 views:@{@0 : Doubles(a, 4)}]);
  XCTAssertTrue([_store publishForOwner:1 epoch:6 sequence:1 views:@{@0 : Doubles(b, 4)}]);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @2, @2, @3, @3 ]));
}

- (void)testTheOrderingIsPerOwnerAndAPublishReplacesOnlyItsOwnersViews {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:2 viewId:0];
  double a[] = {1, 1, 2, 2}, b[] = {4, 4, 5, 5};
  XCTAssertTrue([_store publishForOwner:1 epoch:1 sequence:50 views:@{@0 : Doubles(a, 4)}]);
  XCTAssertTrue([_store publishForOwner:2 epoch:1 sequence:1 views:@{@0 : Doubles(b, 4)}]);
  XCTAssertEqual(((const int32_t *)[_store snapshotForDisplay:0].bytes)[1], 2);
  XCTAssertTrue([_store publishForOwner:1 epoch:1 sequence:51 views:@{}]);
  XCTAssertEqualObjects(WithoutVersion([_store snapshotForDisplay:0]), (@[ @1, @4, @4, @5, @5 ]));
}

- (void)testDroppingAnOwnerClearsItsRectanglesAndOrdering {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  double a[] = {1, 1, 2, 2};
  [_store publishForOwner:1 epoch:9 sequence:9 views:@{@0 : Doubles(a, 4)}];
  [_store dropOwner:1];
  XCTAssertEqual(((const int32_t *)[_store snapshotForDisplay:0].bytes)[1], 0);
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  XCTAssertTrue([_store publishForOwner:1 epoch:1 sequence:1 views:@{@0 : Doubles(a, 4)}]);
  XCTAssertEqual(((const int32_t *)[_store snapshotForDisplay:0].bytes)[1], 1);
}

#pragma mark - ownership (5.4.1)

- (void)testWhatTheSdkReceivesIsAnImmutableSnapshotSharedSafely {
  PUBLISH(1, 1, 2, 2);
  NSData *first = [_store snapshotForDisplay:0];
  XCTAssertFalse([first isKindOfClass:[NSMutableData class]]);
  PUBLISH(5, 5, 6, 6);
  // What an earlier pull returned is untouched by a later publish.
  XCTAssertEqualObjects(WithoutVersion(first), (@[ @1, @1, @1, @2, @2 ]));
}

- (void)testReadersOnAnotherQueueSeeOnlyWholeSetsAndConsistentVersions {
  [_store setPlacement:[BGSFlutterSecurePlacement knownOnDisplay:0 x:0 y:0] forOwner:1 viewId:0];
  __block BOOL stop = NO;
  NSLock *lock = [[NSLock alloc] init];
  NSMutableDictionary<NSNumber *, NSArray *> *contentByVersion = [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *failures = [NSMutableArray array];
  dispatch_group_t group = dispatch_group_create();
  for (int t = 0; t < 2; t++) {
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      while (!stop) {
        NSData *s = [self->_store snapshotForDisplay:0];
        NSArray *ints = Ints(s);
        NSInteger n = [ints[1] integerValue];
        NSString *problem = nil;
        if (ints.count != 2 + 4 * (NSUInteger)n) problem = @"header and length disagree";
        for (NSInteger r = 0; !problem && r < n; r++) {
          NSInteger l = [ints[2 + 4 * r] integerValue];
          if ([ints[3 + 4 * r] integerValue] != l || [ints[4 + 4 * r] integerValue] != l + 100 ||
              [ints[5 + 4 * r] integerValue] != l + 100 || l != r) {
            problem = @"torn rectangle";
          }
        }
        NSArray *content = [ints subarrayWithRange:NSMakeRange(1, ints.count - 1)];
        [lock lock];
        NSArray *seen = contentByVersion[ints[0]];
        if (seen == nil) {
          contentByVersion[ints[0]] = content;
        } else if (![seen isEqual:content]) {
          problem = @"one version meant two sets";
        }
        if (problem) [failures addObject:problem];
        [lock unlock];
      }
    });
  }
  for (int i = 1; i <= 3000; i++) {
    int k = 1 + (i % 12);
    double set[4 * 12];
    for (int r = 0; r < k; r++) {
      set[4 * r] = r;
      set[4 * r + 1] = r;
      set[4 * r + 2] = r + 100;
      set[4 * r + 3] = r + 100;
    }
    [_store publishForOwner:1 epoch:1 sequence:i views:@{@0 : Doubles(set, 4 * k)}];
  }
  stop = YES;
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
  XCTAssertEqual(failures.count, 0u, @"%@", failures.firstObject);
}

#pragma mark - the SDK's pull

- (void)testAPullCallsTheHookFirstAndSurvivesItThrowing {
  PUBLISH(1, 1, 2, 2);
  __block int calls = 0;
  [_store setPullHook:^{
    calls++;
    @throw [NSException exceptionWithName:@"hook" reason:@"failed" userInfo:nil];
  }];
  XCTAssertEqual(((const int32_t *)[_store pullForDisplay:0].bytes)[1], 1);
  XCTAssertEqual(calls, 1);
}

@end
