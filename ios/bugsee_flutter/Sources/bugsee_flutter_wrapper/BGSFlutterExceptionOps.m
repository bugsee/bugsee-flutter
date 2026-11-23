#import "BGSFlutterExceptionOps.h"

@import Bugsee.SPI;

static NSString *const kExceptionName = @"FlutterManagedException";
static const NSInteger kMaxPayloadLength = 262144;
static const NSInteger kMaxDomainLength = 256;

@implementation BGSFlutterRealExceptionSdk

- (BOOL)isLaunchedOrLaunching {
  Bugsee *bugsee = [Bugsee sharedInstance];
  return bugsee != nil &&
         (bugsee.status == BugseeStatusLaunched || bugsee.status == BugseeStatusLaunching);
}

- (void)logHandledName:(NSString *)name
                reason:(NSString *)reason
                domain:(NSString *)domain
            skipFrames:(NSInteger)skipFrames {
  [Bugsee logException:name reason:reason domain:domain skipFrames:skipFrames completion:nil];
}

- (void)logUnhandledName:(NSString *)name reason:(NSString *)reason {
  [Bugsee logUnhandledException:name reason:reason completion:nil];
}

@end

static BGSFlutterFacadeResult *Result(id value, NSString *code, NSString *message) {
  BGSFlutterFacadeResult *r = [[BGSFlutterFacadeResult alloc] init];
  r.value = value;
  r.errorCode = code;
  r.errorMessage = message;
  return r;
}

@implementation BGSFlutterExceptionOps

+ (NSString *)exceptionName { return kExceptionName; }
+ (NSInteger)maxPayloadLength { return kMaxPayloadLength; }
+ (NSInteger)maxDomainLength { return kMaxDomainLength; }

+ (BGSFlutterFacadeResult *)logWithSdk:(id<BGSFlutterExceptionSDK>)sdk
                               payload:(NSString *)payload
                               handled:(BOOL)handled
                                domain:(NSString *)domain {
  if (![payload isKindOfClass:[NSString class]] || payload.length == 0) {
    return Result(nil, BGSFlutterFacadeOps.invalidArgument, @"an exception needs its document");
  }
  if ((NSInteger)payload.length > kMaxPayloadLength) {
    // Never cut JSON in half: Dart keeps below this, so this is not a message of this version.
    return Result(nil, BGSFlutterFacadeOps.invalidArgument,
                  [NSString stringWithFormat:@"the exception document is longer than %ld UTF-16 units",
                                             (long)kMaxPayloadLength]);
  }
  if (domain != nil && (![domain isKindOfClass:[NSString class]] || domain.length == 0 ||
                        (NSInteger)domain.length > kMaxDomainLength)) {
    return Result(nil, BGSFlutterFacadeOps.invalidArgument,
                  [NSString stringWithFormat:@"domain must be 1 to %ld UTF-16 units",
                                             (long)kMaxDomainLength]);
  }
  @try {
    if (![sdk isLaunchedOrLaunching]) {
      return Result(@NO, nil, nil);
    }
    if (handled) {
      // skipFrames 0: the stack the SDK records is the platform thread's, not the app's; the Dart
      // frames are in the document.
      [sdk logHandledName:kExceptionName reason:payload domain:domain skipFrames:0];
    } else {
      // The SDK has no domain on this path: it is dropped (doc/exceptions.md).
      [sdk logUnhandledName:kExceptionName reason:payload];
    }
    return Result(@YES, nil, nil);
  } @catch (NSException *exception) {
    // The exception's name only: the SDK's reason may carry the document, which holds user data.
    return Result(nil, BGSFlutterFacadeOps.sdkError,
                  [NSString stringWithFormat:@"logException: the SDK threw %@", exception.name]);
  }
}

@end
