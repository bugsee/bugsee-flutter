#import "BGSFlutterFeedbackOps.h"

@import Bugsee;
@import BugseeFeedback;

static NSString *const kNotRegistered = @"not-registered";
static NSString *const kSdkError = @"sdk-error";

#pragma mark - The real add-on

/// `BugseeFeedbackListener` -> this package's protocol. The SDK holds it weakly: the slot keeps it.
@interface BGSFlutterFeedbackAdapter : NSObject <BugseeFeedbackListener>
@property(atomic, strong, nullable) id<BGSFlutterFeedbackListener> target;
@end

@implementation BGSFlutterFeedbackAdapter
- (void)onNewMessagesReceived:(NSArray<NSString *> *)messages {
  [self.target onNewMessagesReceived:messages];
}
- (void)onNewMessageSent:(NSString *)message {
  [self.target onNewMessageSent:message];
}
@end

@implementation BGSFlutterFeedbackAdapterSlot {
  BGSFlutterFeedbackAdapter *_adapter;
  void (^_install)(id);
  BOOL _installed;
}

- (instancetype)initWithInstaller:(void (^)(id))install {
  if (self = [super init]) {
    _adapter = [BGSFlutterFeedbackAdapter new];
    _install = [install copy];
  }
  return self;
}

- (id)adapter {
  return _adapter;
}

- (void)installListener:(id<BGSFlutterFeedbackListener>)listener {
  @synchronized(self) {
    if (listener != nil && !_installed) {
      // Marked only once the add-on took it: a raise leaves the next call to try again.
      _install(_adapter);
      _installed = YES;
    }
    _adapter.target = listener;
  }
}

@end

static id<BGSFlutterFeedbackListenerSlot> gSlotOverride;

static id<BGSFlutterFeedbackListenerSlot> RealSlot(void) {
  static BGSFlutterFeedbackAdapterSlot *slot;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    slot = [[BGSFlutterFeedbackAdapterSlot alloc] initWithInstaller:^(id adapter) {
      [[BugseeFeedback shared] setListener:adapter];
    }];
  });
  return slot;
}

@implementation BGSFlutterRealFeedback

+ (void)useListenerSlotForTesting:(id<BGSFlutterFeedbackListenerSlot>)slot {
  gSlotOverride = slot;
}

- (BOOL)isRegistered {
  return [Bugsee ext:[BugseeFeedback class]] != nil;
}

- (BOOL)registerIfMissing {
  @try {
    if ([self isRegistered]) {
      NSLog(@"BugseeFlutterFeedback: feedback add-on registered (the add-on's shim or this plugin's +load)");
      return NO;
    }
    [BugseeFeedback register];
    NSLog(@"BugseeFlutterFeedback: the SDK had no feedback add-on registered; registered it from this plugin");
    return YES;
  } @catch (NSException *exception) {
    NSLog(@"BugseeFlutterFeedback: could not register the feedback add-on: %@", exception.name);
    return NO;
  }
}

- (void)showFeedbackUI {
  [[BugseeFeedback shared] showFeedbackUI];
}

- (void)setGreeting:(NSString *)greeting {
  [[BugseeFeedback shared] setGreeting:greeting];
}

- (void)setListener:(id<BGSFlutterFeedbackListener>)listener {
  [(gSlotOverride ?: RealSlot()) installListener:listener];
}

@end

#pragma mark - Registration

@implementation BGSFlutterFeedbackRegistrar

static dispatch_once_t gOnce;

+ (void)load {
  [self ensureRegistered];
}

+ (void)ensureRegistered {
  dispatch_once(&gOnce, ^{
    @try {
      [BugseeFeedback register];
    } @catch (NSException *exception) {
      NSLog(@"BugseeFlutterFeedback: could not register the feedback add-on: %@", exception.name);
    }
  });
}

@end

#pragma mark - Results

@implementation BGSFlutterFeedbackResult
- (BOOL)failed {
  return self.errorCode != nil;
}
@end

#pragma mark - Ops

/// One engine's way into the fan-out.
@interface BGSFlutterFeedbackRelay : NSObject
@property(nonatomic, copy) BGSFlutterFeedbackReceivedBlock received;
@property(nonatomic, copy) BGSFlutterFeedbackSentBlock sent;
/// NO after a removal, so a callback already queued drops.
@property(atomic) BOOL accepting;
@end

static void OnMain(dispatch_block_t block) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

@implementation BGSFlutterFeedbackRelay

- (void)deliverReceived:(NSArray<NSString *> *)texts {
  if (!self.accepting) return;
  OnMain(^{
    if (self.accepting) self.received(texts);
  });
}

- (void)deliverSent:(NSString *)message {
  if (!self.accepting) return;
  OnMain(^{
    if (self.accepting) self.sent(message);
  });
}

@end

/// Every engine's relay, in the order they were enabled; guarded by SlotLock().
static NSMutableArray<BGSFlutterFeedbackRelay *> *Relays(void) {
  static NSMutableArray *relays;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    relays = [NSMutableArray array];
  });
  return relays;
}

static NSObject *SlotLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [NSObject new];
  });
  return lock;
}

/// The one listener handed to the SDK while a relay exists; passes every event to all of them.
@interface BGSFlutterFeedbackFanout : NSObject <BGSFlutterFeedbackListener>
@end

@implementation BGSFlutterFeedbackFanout

- (NSArray<BGSFlutterFeedbackRelay *> *)snapshot {
  @synchronized(SlotLock()) {
    return [Relays() copy];
  }
}

- (void)onNewMessagesReceived:(NSArray<NSString *> *)messages {
  if (![messages isKindOfClass:[NSArray class]]) return;
  NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:messages.count];
  for (id m in messages) {
    if ([m isKindOfClass:[NSString class]]) [texts addObject:m];
  }
  if (texts.count == 0) return;
  for (BGSFlutterFeedbackRelay *relay in [self snapshot]) [relay deliverReceived:texts];
}

- (void)onNewMessageSent:(NSString *)message {
  if (![message isKindOfClass:[NSString class]]) return;
  for (BGSFlutterFeedbackRelay *relay in [self snapshot]) [relay deliverSent:message];
}

@end

static BGSFlutterFeedbackFanout *Fanout(void) {
  static BGSFlutterFeedbackFanout *fanout;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    fanout = [BGSFlutterFeedbackFanout new];
  });
  return fanout;
}

@implementation BGSFlutterFeedbackOps {
  id<BGSFlutterFeedbackSDK> _sdk;
  BGSFlutterFeedbackReceivedBlock _received;
  BGSFlutterFeedbackSentBlock _sent;
  BGSFlutterFeedbackRelay *_mine;
}

+ (NSString *)notRegisteredCode {
  return kNotRegistered;
}
+ (NSString *)sdkErrorCode {
  return kSdkError;
}

+ (void)resetSlotForTesting {
  @synchronized(SlotLock()) {
    for (BGSFlutterFeedbackRelay *relay in Relays()) relay.accepting = NO;
    [Relays() removeAllObjects];
  }
}

- (instancetype)initWithSdk:(id<BGSFlutterFeedbackSDK>)sdk
                   received:(BGSFlutterFeedbackReceivedBlock)received
                       sent:(BGSFlutterFeedbackSentBlock)sent {
  if (self = [super init]) {
    _sdk = sdk;
    _received = [received copy];
    _sent = [sent copy];
  }
  return self;
}

- (BOOL)attach {
  [self clearMine];
  return [_sdk isRegistered];
}

- (BGSFlutterFeedbackResult *)show {
  return [self call:^{
    [self->_sdk showFeedbackUI];
  }];
}

- (BGSFlutterFeedbackResult *)setGreeting:(NSString *)greeting {
  return [self call:^{
    [self->_sdk setGreeting:greeting];
  }];
}

- (BGSFlutterFeedbackResult *)setListenerEnabled:(BOOL)enabled {
  if (!enabled) {
    [self clearMine];
    return [BGSFlutterFeedbackResult new];
  }
  @synchronized(SlotLock()) {
    // The previous relay of this engine goes first: a failed install must not leave it listening.
    if (_mine != nil) {
      _mine.accepting = NO;
      [Relays() removeObject:_mine];
      _mine = nil;
    }
    BGSFlutterFeedbackResult *result = [BGSFlutterFeedbackResult new];
    if (Relays().count == 0) {
      // Hands the fan-out to the SDK (again: harmless if it already holds it).
      result = [self call:^{
        [self->_sdk setListener:Fanout()];
      }];
      if (result.failed) return result;
    }
    BGSFlutterFeedbackRelay *relay = [BGSFlutterFeedbackRelay new];
    relay.received = _received;
    relay.sent = _sent;
    relay.accepting = YES;
    [Relays() addObject:relay];
    _mine = relay;
    return result;
  }
}

- (void)detach {
  [self clearMine];
}

- (void)clearMine {
  @synchronized(SlotLock()) {
    BGSFlutterFeedbackRelay *ours = _mine;
    _mine = nil;
    if (ours == nil) return;
    ours.accepting = NO;
    [Relays() removeObject:ours];
    if (Relays().count == 0) {
      [self call:^{
        [self->_sdk setListener:nil];
      }];
    }
  }
}

/// The module must be there; an `NSException` from it is a failure, with the name only (the SDK's
/// reason can quote the user's chat text or the greeting).
- (BGSFlutterFeedbackResult *)call:(dispatch_block_t)body {
  BGSFlutterFeedbackResult *result = [BGSFlutterFeedbackResult new];
  if (![_sdk isRegistered]) {
    result.errorCode = kNotRegistered;
    result.errorMessage = @"the SDK has no feedback module registered";
    return result;
  }
  @try {
    body();
  } @catch (NSException *exception) {
    result.errorCode = kSdkError;
    result.errorMessage = [NSString stringWithFormat:@"the SDK raised %@", exception.name];
  }
  return result;
}

@end
