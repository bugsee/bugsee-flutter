#import "BGSFlutterSecureRectangleStore.h"

@implementation BGSFlutterSecureRectangleStore {
  NSMutableDictionary<NSNumber *, NSData *> *_sets;
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
  if ((self = [super init])) {
    _sets = [NSMutableDictionary dictionary];
  }
  return self;
}

- (NSData *)snapshotForDisplay:(NSInteger)display {
  NSData *set;
  @synchronized(self) {
    set = _sets[@(display)];
  }
  if (set != nil) {
    return set;
  }
  int32_t ints[2] = {0, 0};
  return [NSData dataWithBytes:ints length:sizeof(ints)];
}

- (void)publish:(NSData *)buffer forDisplay:(NSInteger)display {
  NSData *copy = [buffer copy];
  @synchronized(self) {
    _sets[@(display)] = copy;
  }
}

- (void)clearForTests {
  @synchronized(self) {
    [_sets removeAllObjects];
  }
}

@end
