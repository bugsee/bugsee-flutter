#import "BGSFlutterViewHierarchyStore.h"

#import <QuartzCore/QuartzCore.h>

#include <math.h>

#import "BGSFlutterSecureRectangleStore.h"

/// The SDK's `BGSManagedHierarchyDataType` (BGSCaptureDataProviderViewHierarchy.m), Android's
/// `DataRequestTypes.VIEW_HIERARCHY`.
static NSString *const kDataType = @"vh";
static const NSUInteger kMaxTemplateCharacters = 1u << 20;
/// Epochs remembered as retired, so a straggler of a dead isolate is ignored.
static const NSUInteger kRetiredEpochs = 32;
/// Largest magnitude served: the secure rectangles' limit (keeps the SDK's arithmetic safe).
static const double kLimit = 268435456.0;  // 2^28

@interface BGSFlutterVHSnapshot : NSObject
@property(nonatomic, readonly) int64_t viewId;
@property(nonatomic, readonly) double ratio;
@property(nonatomic, readonly, copy) NSArray<NSString *> *segments;
@property(nonatomic, readonly, copy) NSData *bounds;
@property(nonatomic, readonly) NSTimeInterval received;
@end
@implementation BGSFlutterVHSnapshot
- (instancetype)initWithViewId:(int64_t)viewId
                         ratio:(double)ratio
                      segments:(NSArray<NSString *> *)segments
                        bounds:(NSData *)bounds
                      received:(NSTimeInterval)received {
  if ((self = [super init])) {
    _viewId = viewId;
    _ratio = ratio;
    _segments = [segments copy];
    _bounds = [bounds copy];
    _received = received;
  }
  return self;
}
@end

/// What is known of one owner: its message ordering and its snapshot, if any. Immutable.
@interface BGSFlutterVHEntry : NSObject
@property(nonatomic, readonly) int64_t epoch;
@property(nonatomic, readonly) int64_t sequence;
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *retired;
@property(nonatomic, readonly, nullable) BGSFlutterVHSnapshot *snapshot;
@end
@implementation BGSFlutterVHEntry
- (instancetype)initWithEpoch:(int64_t)epoch
                     sequence:(int64_t)sequence
                      retired:(NSArray<NSNumber *> *)retired
                     snapshot:(BGSFlutterVHSnapshot *)snapshot {
  if ((self = [super init])) {
    _epoch = epoch;
    _sequence = sequence;
    _retired = [retired copy];
    _snapshot = snapshot;
  }
  return self;
}
@end

@implementation BGSFlutterViewHierarchyStore {
  BGSFlutterSecureRectangleStore *_placement;
  NSTimeInterval (^_clock)(void);
  NSObject *_writeLock;
  NSDictionary<NSNumber *, BGSFlutterVHEntry *> *_owners;
  void (^_refresher)(void);
}

+ (instancetype)shared {
  static BGSFlutterViewHierarchyStore *store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [[BGSFlutterViewHierarchyStore alloc]
        initWithPlacement:[BGSFlutterSecureRectangleStore shared]
                    clock:^NSTimeInterval {
                      return CACurrentMediaTime();
                    }];
  });
  return store;
}

+ (NSString *)dataType {
  return kDataType;
}

+ (NSUInteger)maxTemplateCharacters {
  return kMaxTemplateCharacters;
}

- (instancetype)initWithPlacement:(BGSFlutterSecureRectangleStore *)placement
                            clock:(NSTimeInterval (^)(void))clock {
  if ((self = [super init])) {
    _placement = placement;
    _clock = [clock copy];
    _writeLock = [[NSObject alloc] init];
    _owners = @{};
    __weak BGSFlutterSecureRectangleStore *weakPlacement = placement;
    _refresher = [^{
      [weakPlacement refreshPlacements];
    } copy];
  }
  return self;
}

- (void)setRefresher:(void (^)(void))refresher {
  @synchronized(_writeLock) {
    _refresher = [refresher copy];
  }
}

- (BOOL)publishForOwner:(int64_t)owner
                  epoch:(int64_t)epoch
               sequence:(int64_t)sequence
                 viewId:(int64_t)viewId
                  ratio:(double)ratio
               segments:(NSArray<NSString *> *)segments
                 bounds:(NSData *)bounds {
  @synchronized(_writeLock) {
    BGSFlutterVHEntry *last = _owners[@(owner)];
    NSArray<NSNumber *> *retired = @[];
    if (last != nil) {
      if ([last.retired containsObject:@(epoch)]) {
        return NO;  // a straggler of a dead isolate
      }
      if (epoch == last.epoch) {
        if (sequence <= last.sequence) return NO;
        retired = last.retired;
      } else {
        // A new isolate (a hot restart): its epoch is any id not seen before, never a clock.
        NSMutableArray *grown = [last.retired mutableCopy];
        [grown addObject:@(last.epoch)];
        while (grown.count > kRetiredEpochs) [grown removeObjectAtIndex:0];
        retired = grown;
      }
    }
    BGSFlutterVHSnapshot *snapshot =
        segments.count == 0 ? nil : [self validatedViewId:viewId
                                                    ratio:ratio
                                                 segments:segments
                                                   bounds:bounds];
    NSMutableDictionary *next = [_owners mutableCopy];
    next[@(owner)] = [[BGSFlutterVHEntry alloc] initWithEpoch:epoch
                                                     sequence:sequence
                                                      retired:retired
                                                     snapshot:snapshot];
    _owners = next;
    return YES;
  }
}

/// The shape rules of `ViewHierarchyMessage`; nil when broken (fail closed).
- (BGSFlutterVHSnapshot *)validatedViewId:(int64_t)viewId
                                    ratio:(double)ratio
                                 segments:(NSArray<NSString *> *)segments
                                   bounds:(NSData *)bounds {
  NSUInteger doubles = bounds.length / sizeof(double);
  if (bounds.length % (4 * sizeof(double)) != 0 || segments.count != doubles / 4 + 2) return nil;
  NSUInteger chars = 0;
  for (id segment in segments) {
    if (![segment isKindOfClass:[NSString class]]) return nil;
    chars += [(NSString *)segment length];
    if (chars > kMaxTemplateCharacters) return nil;
  }
  return [[BGSFlutterVHSnapshot alloc] initWithViewId:viewId
                                                ratio:ratio
                                             segments:segments
                                               bounds:bounds
                                             received:_clock()];
}

- (void)dropOwner:(int64_t)owner {
  @synchronized(_writeLock) {
    if (_owners[@(owner)] == nil) return;
    NSMutableDictionary *next = [_owners mutableCopy];
    [next removeObjectForKey:@(owner)];
    _owners = next;
  }
}

- (NSString *)answer {
  @try {
    NSDictionary<NSNumber *, BGSFlutterVHEntry *> *owners;
    void (^refresher)(void);
    @synchronized(_writeLock) {
      owners = _owners;
      refresher = _refresher;
    }
    if (refresher != nil) {
      @try {
        refresher();
      } @catch (id exception) {
        // A placement that could not be refreshed is judged by the store.
      }
    }
    int64_t newestOwner = 0;
    BGSFlutterVHSnapshot *newest = nil;
    for (NSNumber *owner in owners) {
      BGSFlutterVHSnapshot *s = owners[owner].snapshot;
      if (s != nil && (newest == nil || s.received > newest.received)) {
        newest = s;
        newestOwner = owner.longLongValue;
      }
    }
    return newest == nil ? nil : [self renderOwner:newestOwner snapshot:newest];
  } @catch (id exception) {
    return nil;
  }
}

static BOOL BGSFinite(double v) {
  return !isnan(v) && !isinf(v);
}

static BOOL BGSInRange(double v) {
  return BGSFinite(v) && fabs(v) <= kLimit;
}

- (NSString *)renderOwner:(int64_t)owner snapshot:(BGSFlutterVHSnapshot *)s {
  BGSFlutterPlacementMapper *mapper = [_placement mapperForOwner:owner
                                                          viewId:s.viewId
                                                           ratio:s.ratio];
  if (mapper == nil) return nil;
  long long ageMs = (long long)fmax(0, floor((_clock() - s.received) * 1000.0));
  NSMutableString *out = [NSMutableString stringWithCapacity:s.segments[0].length + 64];
  [out appendString:s.segments[0]];
  [out appendFormat:@"%lld", ageMs];
  [out appendString:s.segments[1]];
  const double *b = s.bounds.bytes;
  NSUInteger nodes = s.bounds.length / (4 * sizeof(double));
  for (NSUInteger k = 0; k < nodes; k++) {
    double l = b[4 * k], t = b[4 * k + 1], r = b[4 * k + 2], bt = b[4 * k + 3];
    if (!BGSFinite(l) || !BGSFinite(t) || !BGSFinite(r) || !BGSFinite(bt)) return nil;
    // Scaled and placed first, rounded last, outward like the secure rectangles.
    double left = floor([mapper xForLogical:l]);
    double top = floor([mapper yForLogical:t]);
    double right = ceil([mapper xForLogical:r]);
    double bottom = ceil([mapper yForLogical:bt]);
    if (!BGSInRange(left) || !BGSInRange(top) || !BGSInRange(right) || !BGSInRange(bottom)) {
      return nil;
    }
    [out appendFormat:@"[%lld,%lld,%lld,%lld]", (long long)left, (long long)top,
                      (long long)(right - left), (long long)(bottom - top)];
    [out appendString:s.segments[k + 2]];
  }
  return out;
}

- (void)clearForTests {
  @synchronized(_writeLock) {
    _owners = @{};
  }
}

@end
