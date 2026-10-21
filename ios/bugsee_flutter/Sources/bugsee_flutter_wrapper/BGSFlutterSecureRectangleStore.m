#import "BGSFlutterSecureRectangleStore.h"

#include <math.h>

/// Version meaning "unknown" (`BGSSecureRectanglesVersionUnknown` in the SDK's BGSContracts.h,
/// not imported here so the store needs no SDK).
static const int32_t kUnknownVersion = 0;
static const NSInteger kHeaderInts = 2;
/// A whole-display rectangle's size when the display's is not known.
static const int32_t kFallbackDisplaySize = 16384;
/// Largest magnitude served: keeps the SDK's own arithmetic away from overflow.
static const double kLimit = 268435456.0;  // 2^28

#pragma mark - Placement

@implementation BGSFlutterSecurePlacement
- (instancetype)initWithKind:(BGSFlutterPlacementKind)kind
                     display:(NSInteger)display
                           x:(double)x
                           y:(double)y {
  if ((self = [super init])) {
    _kind = kind;
    _display = display;
    _x = x;
    _y = y;
  }
  return self;
}
+ (instancetype)knownOnDisplay:(NSInteger)display x:(double)x y:(double)y {
  return [[self alloc] initWithKind:BGSFlutterPlacementKnown display:display x:x y:y];
}
+ (instancetype)unknown {
  return [[self alloc] initWithKind:BGSFlutterPlacementUnknown display:0 x:0 y:0];
}
+ (instancetype)absent {
  return [[self alloc] initWithKind:BGSFlutterPlacementAbsent display:0 x:0 y:0];
}
- (BOOL)isEqual:(id)object {
  if (![object isKindOfClass:[BGSFlutterSecurePlacement class]]) return NO;
  BGSFlutterSecurePlacement *other = object;
  return _kind == other.kind && _display == other.display && _x == other.x && _y == other.y;
}
- (NSUInteger)hash {
  return (NSUInteger)_kind ^ (NSUInteger)_display ^ (NSUInteger) @(_x).hash ^ (NSUInteger) @(_y).hash;
}
@end

#pragma mark - Unknown environment

@interface BGSFlutterUnknownEnvironment : NSObject <BGSFlutterSecureEnvironment>
@end
@implementation BGSFlutterUnknownEnvironment
- (double)pointsPerLogicalPixelForDisplay:(NSInteger)display {
  return NAN;
}
- (CGSize)displayBoundsInPointsForDisplay:(NSInteger)display {
  return CGSizeZero;
}
@end

#pragma mark - Immutable state

/// One Flutter view of one Dart isolate.
@interface BGSFlutterLane : NSObject
@property(nonatomic, readonly) int64_t owner;
@property(nonatomic, readonly) int64_t viewId;
/// Packed native-endian doubles, flat ltrb, logical pixels, as Dart sent them.
@property(nonatomic, readonly, copy) NSData *rects;
@end
@implementation BGSFlutterLane
- (instancetype)initWithOwner:(int64_t)owner viewId:(int64_t)viewId rects:(NSData *)rects {
  if ((self = [super init])) {
    _owner = owner;
    _viewId = viewId;
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
/// owner -> @[epoch, sequence] of the newest applied publish.
@property(nonatomic, readonly) NSDictionary<NSNumber *, NSArray<NSNumber *> *> *order;
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

/// What a display last served.
@interface BGSFlutterServed : NSObject
@property(nonatomic, readonly) int32_t version;
@property(nonatomic, readonly, copy) NSData *quads;
@property(nonatomic, readonly, copy) NSData *buffer;
@end
@implementation BGSFlutterServed
- (instancetype)initWithVersion:(int32_t)version quads:(NSData *)quads {
  if ((self = [super init])) {
    _version = version;
    _quads = [quads copy];
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
  BGSFlutterSecureState *_state;
  NSMutableDictionary<NSNumber *, BGSFlutterServed *> *_served;
  void (^_pullHook)(void);
  NSObject *_writeLock;
  NSObject *_serveLock;
}

+ (instancetype)shared {
  static BGSFlutterSecureRectangleStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [[BGSFlutterSecureRectangleStore alloc] init];
  });
  return store;
}

- (instancetype)init {
  return [self initWithEnvironment:[[BGSFlutterUnknownEnvironment alloc] init]];
}

- (instancetype)initWithEnvironment:(id<BGSFlutterSecureEnvironment>)environment {
  if ((self = [super init])) {
    _environment = environment;
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
                  views:(NSDictionary<NSNumber *, NSData *> *)views {
  @synchronized(_writeLock) {
    BGSFlutterSecureState *previous = _state;
    NSArray<NSNumber *> *last = previous.order[@(owner)];
    if (last != nil) {
      int64_t lastEpoch = last[0].longLongValue;
      int64_t lastSequence = last[1].longLongValue;
      if (epoch < lastEpoch || (epoch == lastEpoch && sequence <= lastSequence)) {
        return NO;
      }
    }
    NSMutableArray<BGSFlutterLane *> *lanes = [NSMutableArray array];
    for (BGSFlutterLane *lane in previous.lanes) {
      if (lane.owner != owner) [lanes addObject:lane];
    }
    [views enumerateKeysAndObjectsUsingBlock:^(NSNumber *viewId, NSData *rects, BOOL *stop) {
      if (rects.length > 0) {
        [lanes addObject:[[BGSFlutterLane alloc] initWithOwner:owner
                                                        viewId:viewId.longLongValue
                                                         rects:rects]];
      }
    }];
    [lanes sortUsingComparator:^NSComparisonResult(BGSFlutterLane *a, BGSFlutterLane *b) {
      if (a.owner != b.owner) return a.owner < b.owner ? NSOrderedAscending : NSOrderedDescending;
      if (a.viewId != b.viewId) return a.viewId < b.viewId ? NSOrderedAscending : NSOrderedDescending;
      return NSOrderedSame;
    }];
    NSMutableDictionary *order = [previous.order mutableCopy];
    order[@(owner)] = @[ @(epoch), @(sequence) ];
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
  return [self snapshotForDisplay:display];
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

/// The point rectangles `display` serves for `state`, as packed int32 quads.
static NSData *BGSServe(BGSFlutterSecureState *state, NSInteger display,
                        id<BGSFlutterSecureEnvironment> env) {
  double scale = NAN;
  BOOL scaleRead = NO;
  CGSize bounds = CGSizeZero;
  BOOL boundsRead = NO;
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
    if (!scaleRead) {
      scale = [env pointsPerLogicalPixelForDisplay:display];
      scaleRead = YES;
    }
    if (!boundsRead) {
      bounds = [env displayBoundsInPointsForDisplay:display];
      boundsRead = YES;
    }
    NSUInteger count = lane.rects.length / sizeof(double);
    if (!(scale > 0) || isinf(scale) || lane.rects.length % (4 * sizeof(double)) != 0) {
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
      int32_t il = BGSToInt(floor(l * scale + placement.x));
      int32_t it = BGSToInt(floor(t * scale + placement.y));
      int32_t ir = BGSToInt(ceil(rt * scale + placement.x));
      int32_t ib = BGSToInt(ceil(b * scale + placement.y));
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
    if (!boundsRead) bounds = [env displayBoundsInPointsForDisplay:display];
    int32_t w = bounds.width > 0 ? (int32_t)ceil(bounds.width) : kFallbackDisplaySize;
    int32_t h = bounds.height > 0 ? (int32_t)ceil(bounds.height) : kFallbackDisplaySize;
    int32_t quad[4] = {0, 0, w, h};
    return [NSData dataWithBytes:quad length:sizeof(quad)];
  }
  return out;
}

- (NSData *)snapshotForDisplay:(NSInteger)display {
  @synchronized(_serveLock) {
    NSData *quads = BGSServe([self currentState], display, _environment);
    BGSFlutterServed *previous = _served[@(display)];
    if (previous == nil && quads.length == 0) {
      int32_t empty[2] = {kUnknownVersion, 0};
      return [NSData dataWithBytes:empty length:sizeof(empty)];
    }
    if (previous != nil && [previous.quads isEqualToData:quads]) {
      return previous.buffer;
    }
    int32_t version = previous == nil ? 1 : [BGSFlutterSecureRectangleStore versionAfter:previous.version];
    BGSFlutterServed *next = [[BGSFlutterServed alloc] initWithVersion:version quads:quads];
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
