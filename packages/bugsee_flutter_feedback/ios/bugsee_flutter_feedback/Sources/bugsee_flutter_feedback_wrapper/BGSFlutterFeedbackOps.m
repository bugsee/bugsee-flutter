#import "BGSFlutterFeedbackOps.h"

@import Bugsee;
@import BugseeFeedback;

static NSString *const kNotRegistered = @"not-registered";
static NSString *const kSdkError = @"sdk-error";

#pragma mark - The real add-on

/// `BugseeFeedbackListener` -> this package's protocol. A separate object: the SDK's slot is weak,
/// `BGSFlutterRealFeedback` holds this one.
@interface BGSFlutterFeedbackAdapter : NSObject <BugseeFeedbackListener>
@property(nonatomic, strong) id<BGSFlutterFeedbackListener> target;
@end

@implementation BGSFlutterFeedbackAdapter
- (void)onNewMessagesReceived:(NSArray<NSString *> *)messages {
  [self.target onNewMessagesReceived:messages];
}
- (void)onNewMessageSent:(NSString *)message {
  [self.target onNewMessageSent:message];
}
@end

@implementation BGSFlutterRealFeedback {
  BGSFlutterFeedbackAdapter *_adapter;
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
  if (listener == nil) {
    [[BugseeFeedback shared] setListener:nil];
    _adapter = nil;
    return;
  }
  BGSFlutterFeedbackAdapter *adapter = [BGSFlutterFeedbackAdapter new];
  adapter.target = listener;
  [[BugseeFeedback shared] setListener:adapter];
  _adapter = adapter;
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

/// The listener one ops instance installs.
@interface BGSFlutterFeedbackRelay : NSObject <BGSFlutterFeedbackListener>
@property(nonatomic, copy) BGSFlutterFeedbackReceivedBlock received;
@property(nonatomic, copy) BGSFlutterFeedbackSentBlock sent;
/// NO after a disable or detach, so a callback already queued drops.
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

- (void)onNewMessagesReceived:(NSArray<NSString *> *)messages {
  if (!self.accepting || ![messages isKindOfClass:[NSArray class]]) return;
  NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:messages.count];
  for (id m in messages) {
    if ([m isKindOfClass:[NSString class]]) [texts addObject:m];
  }
  if (texts.count == 0) return;
  OnMain(^{
    if (self.accepting) self.received(texts);
  });
}

- (void)onNewMessageSent:(NSString *)message {
  if (!self.accepting || ![message isKindOfClass:[NSString class]]) return;
  OnMain(^{
    if (self.accepting) self.sent(message);
  });
}

@end

/// The process's SDK slot, if one of ours holds it. Weak, like the SDK's own reference.
static __weak BGSFlutterFeedbackRelay *gInstalled;
static NSObject *SlotLock(void) {
  static NSObject *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [NSObject new];
  });
  return lock;
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
    gInstalled = nil;
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
  BGSFlutterFeedbackRelay *relay = [BGSFlutterFeedbackRelay new];
  relay.received = _received;
  relay.sent = _sent;
  @synchronized(SlotLock()) {
    // Dropped first: a failed install must not leave this instance accepting events.
    _mine.accepting = NO;
    BGSFlutterFeedbackResult *result = [self call:^{
      [self->_sdk setListener:relay];
    }];
    if (result.failed) return result;
    relay.accepting = YES;
    _mine = relay;
    gInstalled = relay;
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
    ours.accepting = NO;
    if (ours == nil || gInstalled != ours) return;
    gInstalled = nil;
    [self call:^{
      [self->_sdk setListener:nil];
    }];
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
