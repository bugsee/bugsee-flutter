#import "BGSFlutterSecureRectangleStore.h"

#import <QuartzCore/QuartzCore.h>

#include <math.h>

/// Version meaning "unknown" (`BGSSecureRectanglesVersionUnknown` in the SDK's BGSContracts.h,
/// not imported here so the store needs no SDK).
static const int32_t kUnknownVersion = 0;
static const NSInteger kHeaderInts = 2;
/// A whole-display rectangle's size when the display's is not known.
static const int32_t kFallbackDisplaySize = 16384;
/// Largest magnitude served: keeps the SDK's own arithmetic away from overflow.
static const double kLimit = 268435456.0;  // 2^28
/// How long each past set is served after it stopped being current. Repeated in Java (GRACE_MS).
static const NSTimeInterval kGraceSeconds = 0.12;
/// More rectangles than this and the past sets still being served are collapsed to their bounding box.
static const NSUInteger kMaxRectangles = 64;
/// How far a message's ratio may differ from the screen's (floating-point noise).
static const double kRatioTolerance = 1e-3;
/// Epochs remembered as retired, so a straggler of a dead isolate is ignored.
static const NSUInteger kRetiredEpochs = 32;

#pragma mark - Placement

@implementation BGSFlutterSecureViewRects
- (instancetype)initWithRatio:(double)ratio rects:(NSData *)rects {
  if ((self = [super init])) {
    _ratio = ratio;
    _rects = [rects copy];
  }
  return self;
}
@end

@implementation BGSFlutterSecurePlacement
- (instancetype)initWithKind:(BGSFlutterPlacementKind)kind
                     display:(NSInteger)display
                           x:(double)x
                           y:(double)y
                      scaleX:(double)scaleX
                      scaleY:(double)scaleY {
  if ((self = [super init])) {
    _kind = kind;
    _display = display;
    _x = x;
    _y = y;
    _scaleX = scaleX;
    _scaleY = scaleY;
  }
  return self;
}
+ (instancetype)knownOnDisplay:(NSInteger)display x:(double)x y:(double)y {
  return [self knownOnDisplay:display x:x y:y scaleX:1 scaleY:1];
}
+ (instancetype)knownOnDisplay:(NSInteger)display
                             x:(double)x
                             y:(double)y
                        scaleX:(double)scaleX
                        scaleY:(double)scaleY {
  return [[self alloc] initWithKind:BGSFlutterPlacementKnown
                            display:display
                                  x:x
                                  y:y
                             scaleX:scaleX
                             scaleY:scaleY];
}
+ (instancetype)unknown {
  return [[self alloc] initWithKind:BGSFlutterPlacementUnknown display:0 x:0 y:0 scaleX:1 scaleY:1];
}
+ (instancetype)absent {
  return [[self alloc] initWithKind:BGSFlutterPlacementAbsent display:0 x:0 y:0 scaleX:1 scaleY:1];
}
- (BOOL)isEqual:(id)object {
  if (![object isKindOfClass:[BGSFlutterSecurePlacement class]]) return NO;
  BGSFlutterSecurePlacement *other = object;
  return _kind == other.kind && _display == other.display && _x == other.x && _y == other.y &&
         _scaleX == other.scaleX && _scaleY == other.scaleY;
}
- (NSUInteger)hash {
  return (NSUInteger)_kind ^ (NSUInteger)_display ^ (NSUInteger) @(_x).hash ^ (NSUInteger) @(_y).hash;
}
@end

#pragma mark - Unknown environment

@interface BGSFlutterUnknownEnvironment : NSObject <BGSFlutterSecureEnvironment>
@end
@implementation BGSFlutterUnknownEnvironment
- (double)nativePixelRatioForDisplay:(NSInteger)display {
  return NAN;
}
- (double)unitsPerPhysicalPixelForDisplay:(NSInteger)display {
  return 1;
}
- (CGSize)displayBoundsInPointsForDisplay:(NSInteger)display {
  return CGSizeZero;
}
@end

#pragma mark - Mapper

static BOOL BGSUsable(double v);

@implementation BGSFlutterPlacementMapper {
  double _factor;
  double _sx, _sy, _x, _y;
}
+ (instancetype)mapperForPlacement:(BGSFlutterSecurePlacement *)placement
                         viewRatio:(double)viewRatio
                       nativeRatio:(double)nativeRatio
                              unit:(double)unit {
  if (!BGSUsable(viewRatio) || !BGSUsable(nativeRatio) || !BGSUsable(unit) ||
      !BGSUsable(placement.scaleX) || !BGSUsable(placement.scaleY) ||
      fabs(nativeRatio - viewRatio) > kRatioTolerance * fmax(1, viewRatio)) {
    return nil;
  }
  BGSFlutterPlacementMapper *mapper = [[BGSFlutterPlacementMapper alloc] init];
  mapper->_display = placement.display;
  mapper->_factor = viewRatio * unit;
  mapper->_sx = placement.scaleX;
  mapper->_sy = placement.scaleY;
  mapper->_x = placement.x;
  mapper->_y = placement.y;
  return mapper;
}
- (double)xForLogical:(double)logical {
  return logical * _factor * _sx + _x;
}
- (double)yForLogical:(double)logical {
  return logical * _factor * _sy + _y;
}
@end

#pragma mark - Immutable state

/// One Flutter view of one Dart isolate.
@interface BGSFlutterLane : NSObject
@property(nonatomic, readonly) int64_t owner;
@property(nonatomic, readonly) int64_t viewId;
/// The ratio Dart measured the rectangles at.
@property(nonatomic, readonly) double ratio;
/// Packed native-endian doubles, flat ltrb, logical pixels, as Dart sent them.
@property(nonatomic, readonly, copy) NSData *rects;
@end
@implementation BGSFlutterLane
- (instancetype)initWithOwner:(int64_t)owner viewId:(int64_t)viewId ratio:(double)ratio rects:(NSData *)rects {
  if ((self = [super init])) {
    _owner = owner;
    _viewId = viewId;
    _ratio = ratio;
    _rects = [rects copy];
  }
  return self;
}
- (NSString *)key {
  return [BGSFlutterLane keyForOwner:_owner viewId:_viewId];
}
+ (NSString *)keyForOwner:(int64_t)owner viewId:(int64_t)viewId {
  return [NSString stringWithFormat:@"%lld:%lld", owner, viewId];
}
@end

@interface BGSFlutterSecureState : NSObject
/// Sorted by (owner, viewId).
@property(nonatomic, readonly) NSArray<BGSFlutterLane *> *lanes;
@property(nonatomic, readonly) NSDictionary<NSString *, BGSFlutterSecurePlacement *> *placements;
/// owner -> @[epoch, sequence, retired epochs] of the newest applied publish.
@property(nonatomic, readonly) NSDictionary<NSNumber *, NSArray *> *order;
@end
@implementation BGSFlutterSecureState
- (instancetype)initWithLanes:(NSArray *)lanes placements:(NSDictionary *)placements order:(NSDictionary *)order {
  if ((self = [super init])) {
    _lanes = [lanes copy];
    _placements = [placements copy];
    _order = [order copy];
  }
  return self;
}
@end

/// A set that stopped being current, and until when it is still served.
@interface BGSFlutterPast : NSObject
@property(nonatomic, readonly, copy) NSData *quads;
@property(nonatomic, readonly) NSTimeInterval until;
@end
@implementation BGSFlutterPast
- (instancetype)initWithQuads:(NSData *)quads until:(NSTimeInterval)until {
  if ((self = [super init])) {
    _quads = [quads copy];
    _until = until;
  }
  return self;
}
@end

/// What a display last served.
@interface BGSFlutterServed : NSObject
@property(nonatomic, readonly) int32_t version;
/// What is served: the current set plus every past set still inside its window.
@property(nonatomic, readonly, copy) NSData *quads;
@property(nonatomic, readonly, copy) NSData *current;
/// Newest first. Each is served until the grace period after it stopped being current.
@property(nonatomic, readonly, copy) NSArray<BGSFlutterPast *> *past;
@property(nonatomic, readonly, copy) NSData *buffer;
@end
@implementation BGSFlutterServed
- (instancetype)initWithVersion:(int32_t)version
                          quads:(NSData *)quads
                        current:(NSData *)current
                           past:(NSArray<BGSFlutterPast *> *)past {
  if ((self = [super init])) {
    _version = version;
    _quads = [quads copy];
    _current = [current copy];
    _past = [past copy];
    NSMutableData *buffer = [NSMutableData dataWithCapacity:(kHeaderInts * 4) + quads.length];
    int32_t header[2] = {version, (int32_t)(quads.length / (4 * sizeof(int32_t)))};
    [buffer appendBytes:header length:sizeof(header)];
    [buffer appendData:quads];
    _buffer = [buffer copy];  // immutable: safe to hand to any thread
  }
  return self;
}
@end

#pragma mark - Store

@implementation BGSFlutterSecureRectangleStore {
  id<BGSFlutterSecureEnvironment> _environment;
  NSTimeInterval (^_clock)(void);
  NSTimeInterval _grace;
  BGSFlutterSecureState *_state;
  NSMutableDictionary<NSNumber *, BGSFlutterServed *> *_served;
  void (^_pullHook)(void);
  NSObject *_writeLock;
  NSObject *_serveLock;
}

+ (NSTimeInterval)graceSeconds {
  return kGraceSeconds;
}

+ (instancetype)shared {
  static BGSFlutterSecureRectangleStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [[BGSFlutterSecureRectangleStore alloc]
        initWithEnvironment:[[BGSFlutterUnknownEnvironment alloc] init]
                      clock:^NSTimeInterval {
                        return CACurrentMediaTime();
                      }
                      grace:kGraceSeconds];
  });
  return store;
}

- (instancetype)init {
  return [self initWithEnvironment:[[BGSFlutterUnknownEnvironment alloc] init]];
}

- (instancetype)initWithEnvironment:(id<BGSFlutterSecureEnvironment>)environment {
  return [self initWithEnvironment:environment
                             clock:^NSTimeInterval {
                               return CACurrentMediaTime();
                             }
                             grace:0];
}

- (instancetype)initWithEnvironment:(id<BGSFlutterSecureEnvironment>)environment
                              clock:(NSTimeInterval (^)(void))clock
                              grace:(NSTimeInterval)grace {
  if ((self = [super init])) {
    _environment = environment;
    _clock = [clock copy];
    _grace = grace;
    _state = [[BGSFlutterSecureState alloc] initWithLanes:@[] placements:@{} order:@{}];
    _served = [NSMutableDictionary dictionary];
    _writeLock = [[NSObject alloc] init];
    _serveLock = [[NSObject alloc] init];
  }
  return self;
}

- (void)setEnvironment:(id<BGSFlutterSecureEnvironment>)environment {
  @synchronized(_serveLock) {
    _environment = environment;
  }
}

- (void)setPullHook:(void (^)(void))hook {
  @synchronized(_writeLock) {
    _pullHook = [hook copy];
  }
}

- (BGSFlutterSecureState *)currentState {
  @synchronized(_writeLock) {
    return _state;
  }
}

- (BOOL)publishForOwner:(int64_t)owner
                  epoch:(int64_t)epoch
               sequence:(int64_t)sequence
                  views:(NSDictionary<NSNumber *, BGSFlutterSecureViewRects *> *)views {
  @synchronized(_writeLock) {
    BGSFlutterSecureState *previous = _state;
    NSArray *last = previous.order[@(owner)];
    NSArray<NSNumber *> *retired = @[];
    if (last != nil) {
      int64_t lastEpoch = [last[0] longLongValue];
      int64_t lastSequence = [last[1] longLongValue];
      NSArray<NSNumber *> *lastRetired = last[2];
      if ([lastRetired containsObject:@(epoch)]) {
        return NO;  // a straggler of a dead isolate
      }
      if (epoch == lastEpoch) {
        if (sequence <= lastSequence) return NO;
        retired = lastRetired;
      } else {
        // A new isolate (a hot restart): its epoch is any id not seen before, never a clock.
        NSMutableArray *grown = [lastRetired mutableCopy];
        [grown addObject:@(lastEpoch)];
        while (grown.count > kRetiredEpochs) [grown removeObjectAtIndex:0];
        retired = grown;
      }
    }
    NSMutableArray<BGSFlutterLane *> *lanes = [NSMutableArray array];
    for (BGSFlutterLane *lane in previous.lanes) {
      if (lane.owner != owner) [lanes addObject:lane];
    }
    [views enumerateKeysAndObjectsUsingBlock:^(NSNumber *viewId, BGSFlutterSecureViewRects *view, BOOL *stop) {
      if (view.rects.length > 0) {
        [lanes addObject:[[BGSFlutterLane alloc] initWithOwner:owner
                                                        viewId:viewId.longLongValue
                                                         ratio:view.ratio
                                                         rects:view.rects]];
      }
    }];
    [lanes sortUsingComparator:^NSComparisonResult(BGSFlutterLane *a, BGSFlutterLane *b) {
      if (a.owner != b.owner) return a.owner < b.owner ? NSOrderedAscending : NSOrderedDescending;
      if (a.viewId != b.viewId) return a.viewId < b.viewId ? NSOrderedAscending : NSOrderedDescending;
      return NSOrderedSame;
    }];
    NSMutableDictionary *order = [previous.order mutableCopy];
    order[@(owner)] = @[ @(epoch), @(sequence), retired ];
    _state = [[BGSFlutterSecureState alloc] initWithLanes:lanes
                                               placements:previous.placements
                                                    order:order];
    return YES;
  }
}

- (void)setPlacement:(BGSFlutterSecurePlacement *)placement forOwner:(int64_t)owner viewId:(int64_t)viewId {
  @synchronized(_writeLock) {
    BGSFlutterSecureState *previous = _state;
    NSString *key = [BGSFlutterLane keyForOwner:owner viewId:viewId];
    if ([placement isEqual:previous.placements[key]]) {
      return;
    }
    NSMutableDictionary *placements = [previous.placements mutableCopy];
    placements[key] = placement;
    _state = [[BGSFlutterSecureState alloc] initWithLanes:previous.lanes
                                               placements:placements
                                                    order:previous.order];
  }
}

- (void)dropOwner:(int64_t)owner {
  @synchronized(_writeLock) {
    BGSFlutterSecureState *previous = _state;
    NSMutableArray *lanes = [NSMutableArray array];
    for (BGSFlutterLane *lane in previous.lanes) {
      if (lane.owner != owner) [lanes addObject:lane];
    }
    NSString *prefix = [NSString stringWithFormat:@"%lld:", owner];
    NSMutableDictionary *placements = [NSMutableDictionary dictionary];
    [previous.placements enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
      if (![key hasPrefix:prefix]) placements[key] = value;
    }];
    NSMutableDictionary *order = [previous.order mutableCopy];
    [order removeObjectForKey:@(owner)];
    _state = [[BGSFlutterSecureState alloc] initWithLanes:lanes placements:placements order:order];
  }
}

- (NSData *)pullForDisplay:(NSInteger)display {
  [self refreshPlacements];
  return [self snapshotForDisplay:display];
}

- (void)refreshPlacements {
  void (^hook)(void);
  @synchronized(_writeLock) {
    hook = _pullHook;
  }
  if (hook != nil) {
    @try {
      hook();
    } @catch (id exception) {
      // The pull is always answered.
    }
  }
}

- (BGSFlutterPlacementMapper *)mapperForOwner:(int64_t)owner viewId:(int64_t)viewId ratio:(double)ratio {
  @try {
    BGSFlutterSecurePlacement *placement =
        [self currentState].placements[[BGSFlutterLane keyForOwner:owner viewId:viewId]];
    if (placement == nil || placement.kind != BGSFlutterPlacementKnown) return nil;
    id<BGSFlutterSecureEnvironment> env;
    @synchronized(_serveLock) {
      env = _environment;
    }
    return [BGSFlutterPlacementMapper
        mapperForPlacement:placement
                 viewRatio:ratio
               nativeRatio:[env nativePixelRatioForDisplay:placement.display]
                      unit:[env unitsPerPhysicalPixelForDisplay:placement.display]];
  } @catch (id exception) {
    return nil;
  }
}

+ (int32_t)versionAfter:(int32_t)version {
  int32_t next = (int32_t)((uint32_t)version + 1u);  // wraps
  return next == kUnknownVersion ? next + 1 : next;
}

static int32_t BGSClampInt(int32_t v, int32_t max) {
  return v < 0 ? 0 : (v > max ? max : v);
}

static int32_t BGSToInt(double v) {
  return (int32_t)fmax(-kLimit, fmin(kLimit, v));
}

static BOOL BGSUsable(double v) {
  return v > 0 && !isinf(v);
}

/// The point rectangles `display` should serve for `state`, as packed int32 quads.
static NSData *BGSServe(BGSFlutterSecureState *state, NSInteger display,
                        id<BGSFlutterSecureEnvironment> env) {
  double nativeRatio = NAN;
  double unit = 1;
  CGSize bounds = CGSizeZero;
  BOOL envRead = NO;
  NSMutableData *out = [NSMutableData data];
  BOOL whole = NO;

  for (BGSFlutterLane *lane in state.lanes) {
    BGSFlutterSecurePlacement *placement = state.placements[[lane key]];
    BGSFlutterPlacementKind kind = placement == nil ? BGSFlutterPlacementUnknown : placement.kind;
    if (kind == BGSFlutterPlacementAbsent) continue;
    if (kind == BGSFlutterPlacementUnknown) {
      whole = YES;
      continue;
    }
    if (placement.display != display) continue;
    if (!envRead) {
      nativeRatio = [env nativePixelRatioForDisplay:display];
      unit = [env unitsPerPhysicalPixelForDisplay:display];
      bounds = [env displayBoundsInPointsForDisplay:display];
      envRead = YES;
    }
    NSUInteger count = lane.rects.length / sizeof(double);
    BGSFlutterPlacementMapper *mapper = [BGSFlutterPlacementMapper mapperForPlacement:placement
                                                                            viewRatio:lane.ratio
                                                                          nativeRatio:nativeRatio
                                                                                 unit:unit];
    if (mapper == nil || lane.rects.length % (4 * sizeof(double)) != 0) {
      // Measured at another ratio than the screen has now, or not measurable.
      whole = YES;
      continue;
    }
    const double *r = lane.rects.bytes;
    for (NSUInteger i = 0; i + 3 < count; i += 4) {
      double l = r[i], t = r[i + 1], rt = r[i + 2], b = r[i + 3];
      if (!isfinite(l) || !isfinite(t) || !isfinite(rt) || !isfinite(b)) {
        whole = YES;
        continue;
      }
      if (rt <= l || b <= t) continue;  // degenerate: nothing to hide
      // Scale and place first, round outward last (5.3.1).
      int32_t il = BGSToInt(floor([mapper xForLogical:l]));
      int32_t it = BGSToInt(floor([mapper yForLogical:t]));
      int32_t ir = BGSToInt(ceil([mapper xForLogical:rt]));
      int32_t ib = BGSToInt(ceil([mapper yForLogical:b]));
      if (bounds.width > 0 && bounds.height > 0) {
        int32_t w = (int32_t)ceil(bounds.width), h = (int32_t)ceil(bounds.height);
        il = BGSClampInt(il, w);
        ir = BGSClampInt(ir, w);
        it = BGSClampInt(it, h);
        ib = BGSClampInt(ib, h);
      }
      if (ir <= il || ib <= it) continue;  // nothing of it is on the display
      int32_t quad[4] = {il, it, ir, ib};
      [out appendBytes:quad length:sizeof(quad)];
    }
  }

  if (whole) {
    // Something could not be placed or measured: cover everything.
    if (!envRead) bounds = [env displayBoundsInPointsForDisplay:display];
    int32_t w = bounds.width > 0 ? (int32_t)ceil(bounds.width) : kFallbackDisplaySize;
    int32_t h = bounds.height > 0 ? (int32_t)ceil(bounds.height) : kFallbackDisplaySize;
    int32_t quad[4] = {0, 0, w, h};
    return [NSData dataWithBytes:quad length:sizeof(quad)];
  }
  return out;
}

/// The rectangles of `a` then those of `b` that are not in `a`; `b` collapsed to its bounding box
/// when together they would be too many.
static NSData *BGSUnion(NSData *a, NSData *b) {
  if (b.length == 0) return a;
  const int32_t *pa = a.bytes, *pb = b.bytes;
  NSUInteger na = a.length / (4 * sizeof(int32_t)), nb = b.length / (4 * sizeof(int32_t));
  NSMutableData *extra = [NSMutableData data];
  for (NSUInteger i = 0; i < nb; i++) {
    BOOL present = NO;
    for (NSUInteger j = 0; j < na && !present; j++) {
      present = memcmp(pa + 4 * j, pb + 4 * i, 4 * sizeof(int32_t)) == 0;
    }
    if (!present) [extra appendBytes:pb + 4 * i length:4 * sizeof(int32_t)];
  }
  if (extra.length == 0) return a;
  NSUInteger ne = extra.length / (4 * sizeof(int32_t));
  if (na + ne > kMaxRectangles) {
    const int32_t *pe = extra.bytes;
    int32_t l = INT32_MAX, t = INT32_MAX, r = INT32_MIN, bt = INT32_MIN;
    for (NSUInteger i = 0; i < ne; i++) {
      l = MIN(l, pe[4 * i]);
      t = MIN(t, pe[4 * i + 1]);
      r = MAX(r, pe[4 * i + 2]);
      bt = MAX(bt, pe[4 * i + 3]);
    }
    int32_t box[4] = {l, t, r, bt};
    extra = [NSMutableData dataWithBytes:box length:sizeof(box)];
  }
  NSMutableData *out = [a mutableCopy];
  [out appendData:extra];
  return out;
}

- (NSData *)snapshotForDisplay:(NSInteger)display {
  @synchronized(_serveLock) {
    NSTimeInterval now = _clock();
    NSData *target = BGSServe([self currentState], display, _environment);
    BGSFlutterServed *last = _served[@(display)];
    if (last == nil) {
      if (target.length == 0) {
        int32_t empty[2] = {kUnknownVersion, 0};
        return [NSData dataWithBytes:empty length:sizeof(empty)];
      }
      BGSFlutterServed *first = [[BGSFlutterServed alloc] initWithVersion:1
                                                                    quads:target
                                                                  current:target
                                                                     past:@[]];
      _served[@(display)] = first;
      return first.buffer;
    }
    // Sets that stopped being current are served for a window each, counted from the moment THEY
    // stopped (not from the last change), so a long movement keeps only the last window's worth of
    // places instead of its whole path.
    NSMutableArray<BGSFlutterPast *> *past = [NSMutableArray array];
    if (_grace > 0 && ![target isEqualToData:last.current] && last.current.length > 0) {
      [past addObject:[[BGSFlutterPast alloc] initWithQuads:last.current until:now + _grace]];
    }
    for (BGSFlutterPast *p in last.past) {
      if (p.until > now) [past addObject:p];
    }
    NSData *out = target;
    for (BGSFlutterPast *p in past) out = BGSUnion(out, p.quads);
    int32_t version = [out isEqualToData:last.quads]
                          ? last.version
                          : [BGSFlutterSecureRectangleStore versionAfter:last.version];
    BGSFlutterServed *next = [[BGSFlutterServed alloc] initWithVersion:version
                                                                 quads:out
                                                               current:target
                                                                  past:past];
    _served[@(display)] = next;
    return next.buffer;
  }
}

- (void)clearForTests {
  @synchronized(_writeLock) {
    _state = [[BGSFlutterSecureState alloc] initWithLanes:@[] placements:@{} order:@{}];
    _pullHook = nil;
  }
  @synchronized(_serveLock) {
    [_served removeAllObjects];
    _environment = [[BGSFlutterUnknownEnvironment alloc] init];
  }
}

@end
