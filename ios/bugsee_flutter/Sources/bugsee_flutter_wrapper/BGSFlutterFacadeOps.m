#import "BGSFlutterFacadeOps.h"

#import "BGSFlutterReportOps.h"

@import Bugsee;

static NSString *const kInvalidArgument = @"invalid-argument";
static NSString *const kAttributeRejected = @"attribute-rejected";
static NSString *const kSdkError = @"sdk-error";
static NSString *const kNotAttached = @"not-attached";

/// Android's `BugseeAttributes.CUSTOM_ATTRIBUTE_MAX_LENGTH_LIMIT`, applied to both platforms so a
/// string is not accepted on one and dropped on the other. iOS's own limit is on the archived size
/// (1124 bytes) and is detected by the read-back.
static const NSInteger kAttributeStringMaxLength = 1024;

/// `Float.MAX_VALUE`: Android refuses a double at or above it, so both platforms do.
static const double kAttributeNumberLimit = 3.4028234663852886e38;

/// An NSNumber that is a boolean (what Dart's `bool` arrives as), not merely 0 or 1.
static BOOL IsBoolean(NSNumber *number) {
  return CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID();
}

/// An NSNumber holding a floating point value (`float` or `double`), not an integer or a bool.
static BOOL IsFloating(NSNumber *number) {
  if (IsBoolean(number)) return NO;
  const char *type = [number objCType];
  return strcmp(type, "f") == 0 || strcmp(type, "d") == 0;
}

/// The severity the SDK applies to a report that names none: `reporting.defaults.bug-priority`.
static BugseeSeverityLevel DefaultBugSeverity(void) {
  id value = [Bugsee getLaunchOptions][BugseeOptionReportingDefaultBugPriority];
  return [value isKindOfClass:[NSNumber class]] ? (BugseeSeverityLevel)[value integerValue]
                                                : BugseeSeverityHigh;
}

@implementation BGSFlutterRealFacade

- (void)setAttribute:(NSString *)name value:(id)value {
  [Bugsee setAttribute:name withValue:value];
}
- (id)getAttribute:(NSString *)name {
  return [Bugsee getAttribute:name];
}
- (NSDictionary<NSString *, id> *)getAllAttributes {
  return [Bugsee getAllAttributes];
}
- (void)clearAttribute:(NSString *)name {
  [Bugsee clearAttribute:name];
}
- (void)clearAllAttributes {
  [Bugsee clearAllAttributes];
}
- (void)setUserIdentifier:(NSString *)identifier {
  [Bugsee setUserIdentifier:identifier];
}
- (NSString *)getUserIdentifier {
  return [Bugsee getUserIdentifier];
}
- (void)traceName:(NSString *)name value:(id)value {
  [Bugsee trace:name value:value];
}
- (void)eventName:(NSString *)name params:(NSDictionary *)params {
  if (params == nil) {
    [Bugsee event:name];
  } else {
    [Bugsee event:name params:params];
  }
}
- (void)logMessage:(NSString *)message level:(NSInteger)level {
  [Bugsee log:message level:(BugseeLogLevel)level];
}
- (void)notifyTitle:(NSString *)title
               body:(NSString *)body
           severity:(NSInteger)severity
             fields:(NSDictionary<NSString *, NSString *> *)fields
             urgent:(BOOL)urgent {
  [Bugsee notifyWithTitle:title
                     body:body
                 severity:(BugseeSeverityLevel)severity
                   fields:fields
                   urgent:urgent];
}
- (BOOL)addBreadcrumbCategory:(NSString *)category
                        level:(NSInteger)level
                      message:(NSString *)message
                         type:(NSString *)type
                         data:(NSDictionary *)data {
  // `createBreadcrumb` still returns a crumb when capture is off and `addBreadcrumb:` then records
  // nothing; Android's factory returns none. The option is the common signal.
  id capture = [Bugsee getLaunchOptions][BugseeOptionCaptureBreadcrumbs];
  if (![capture isKindOfClass:[NSNumber class]] || ![(NSNumber *)capture boolValue]) {
    return NO;
  }
  id<BGSBugseeExchangeFactory> factory = [Bugsee getExchangeFactory];
  id<BGSBreadcrumb> crumb = factory != nil ? [factory createBreadcrumb] : nil;
  if (crumb == nil) {
    return NO;
  }
  crumb.category = category;
  crumb.level = level;
  crumb.message = message;
  crumb.type = type;
  if (data != nil) {
    crumb.data = data;
  }
  [Bugsee addBreadcrumb:crumb];
  return YES;
}
- (void)startBlackout {
  [Bugsee startBlackout];
}
- (void)endBlackout {
  [Bugsee endBlackout];
}
- (BOOL)isBlackout {
  return [Bugsee isBlackout];
}
- (void)showReportDialogSummary:(NSString *)summary
                    description:(NSString *)description
                       severity:(NSInteger)severity
                         labels:(NSArray<NSString *> *)labels {
  if (summary == nil && description == nil && severity == 0 && labels == nil) {
    [Bugsee showReportDialog];
  } else if (severity == 0 && labels == nil) {
    // Without a severity the SDK applies the default bug priority; the four-argument form would
    // set 0 ("never set").
    [Bugsee showReportDialogWithSummary:summary ?: @"" description:description ?: @""];
  } else {
    [Bugsee showReportDialogWithSummary:summary ?: @""
                            description:description ?: @""
                               severity:severity == 0 ? DefaultBugSeverity() : (BugseeSeverityLevel)severity
                                 labels:labels];
  }
}
- (void)uploadSummary:(NSString *)summary
          description:(NSString *)description
             severity:(NSInteger)severity
               labels:(NSArray<NSString *> *)labels {
  if (severity == 0 && labels == nil) {
    [Bugsee uploadWithSummary:summary description:description];
  } else if (severity == 0) {
    [Bugsee uploadWithSummary:summary
                  description:description
                     severity:DefaultBugSeverity()
                       labels:labels];
  } else {
    [Bugsee uploadWithSummary:summary
                  description:description
                     severity:(BugseeSeverityLevel)severity
                       labels:labels];
  }
}

@end

@implementation BGSFlutterFacadeResult
- (BOOL)failed {
  return self.errorCode != nil;
}
@end

static BGSFlutterFacadeResult *Ok(id value) {
  BGSFlutterFacadeResult *r = [[BGSFlutterFacadeResult alloc] init];
  r.value = value;
  return r;
}

static BGSFlutterFacadeResult *Fail(NSString *code, NSString *message) {
  BGSFlutterFacadeResult *r = [[BGSFlutterFacadeResult alloc] init];
  r.errorCode = code;
  r.errorMessage = message;
  return r;
}

/// The exception's name only: the SDK's reason may carry user data.
static BGSFlutterFacadeResult *SdkFailure(NSString *what, NSException *exception) {
  return Fail(kSdkError,
              [NSString stringWithFormat:@"%@: the SDK threw %@", what, exception.name]);
}

static BOOL IsString(id v) {
  return [v isKindOfClass:[NSString class]];
}

@implementation BGSFlutterFacadeOps

+ (NSString *)invalidArgument { return kInvalidArgument; }
+ (NSString *)attributeRejected { return kAttributeRejected; }
+ (NSString *)sdkError { return kSdkError; }
+ (NSString *)notAttached { return kNotAttached; }
+ (NSInteger)attributeStringMaxLength { return kAttributeStringMaxLength; }

// ---- Attributes --------------------------------------------------------------------------------

/// The value as the SDK takes it, or nil with `message` set.
+ (nullable id)checkedAttributeValue:(id)value message:(NSString **)message {
  if (IsString(value)) {
    if ([(NSString *)value length] > (NSUInteger)kAttributeStringMaxLength) {
      *message = [NSString stringWithFormat:@"an attribute string is at most %ld UTF-16 units",
                                            (long)kAttributeStringMaxLength];
      return nil;
    }
    return value;
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    NSNumber *number = value;
    if (IsFloating(number)) {
      const double d = number.doubleValue;
      if (isnan(d) || isinf(d) || fabs(d) >= kAttributeNumberLimit) {
        *message = @"an attribute number must be finite and below the largest 32-bit float";
        return nil;
      }
    }
    return value;
  }
  *message = @"an attribute value must be a string, a bool, an int or a double";
  return nil;
}

+ (BOOL)sentValue:(id)sent matchesStored:(id)stored {
  if (stored == nil) return NO;
  if (IsString(sent)) return IsString(stored) && [sent isEqualToString:stored];
  if ([sent isKindOfClass:[NSNumber class]] && [stored isKindOfClass:[NSNumber class]]) {
    // A bool must stay a bool; a number is compared as the same kind of number.
    if (IsBoolean(sent) != IsBoolean(stored)) return NO;
    return [sent isEqualToNumber:stored];
  }
  return NO;
}

+ (id)dartValueFromStored:(id)stored {
  if (IsString(stored)) return stored;
  if ([stored isKindOfClass:[NSNumber class]]) {
    NSNumber *number = stored;
    if (IsFloating(number) && (isnan(number.doubleValue) || isinf(number.doubleValue))) {
      return nil;
    }
    // The same object, not re-boxed: a CFBoolean's identity is what makes it a bool on the wire.
    return stored;
  }
  if ([stored isKindOfClass:[NSArray class]]) {
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    for (id element in (NSArray *)stored) {
      if (!IsString(element)) return nil;
      [strings addObject:element];
    }
    return strings;
  }
  return nil;
}

+ (BGSFlutterFacadeResult *)setAttributeWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                           name:(NSString *)name
                                          value:(id)value {
  if (!IsString(name) || name.length == 0) {
    return Fail(kInvalidArgument, @"an attribute needs a non-empty name");
  }
  NSString *message = nil;
  id checked = [self checkedAttributeValue:value message:&message];
  if (checked == nil) {
    return Fail(kInvalidArgument, message);
  }
  @try {
    // The SDK answers YES even for a value it ignored (over its archive limit), so the read-back is
    // the signal.
    [sdk setAttribute:name value:checked];
    id stored = [sdk getAttribute:name];
    if (![self sentValue:checked matchesStored:stored]) {
      // Never the value: it is user data.
      return Fail(kAttributeRejected,
                  @"the SDK did not keep the attribute (over its size limit, or it could not store it)");
    }
  } @catch (NSException *exception) {
    return SdkFailure(@"setAttribute", exception);
  }
  return Ok(nil);
}

+ (BGSFlutterFacadeResult *)getAttributeWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(NSString *)name {
  if (!IsString(name) || name.length == 0) {
    return Fail(kInvalidArgument, @"an attribute needs a non-empty name");
  }
  @try {
    return Ok([self dartValueFromStored:[sdk getAttribute:name]]);
  } @catch (NSException *exception) {
    return SdkFailure(@"getAttribute", exception);
  }
}

+ (BGSFlutterFacadeResult *)getAllAttributesWithSdk:(id<BGSFlutterFacadeSDK>)sdk {
  @try {
    NSMutableDictionary<NSString *, id> *out = [NSMutableDictionary dictionary];
    [[sdk getAllAttributes] enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
      id converted = [self dartValueFromStored:value];
      if (IsString(key) && converted != nil) {
        out[key] = converted;
      }
    }];
    return Ok(out);
  } @catch (NSException *exception) {
    return SdkFailure(@"getAllAttributes", exception);
  }
}

+ (BGSFlutterFacadeResult *)clearAttributeWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(NSString *)name {
  if (!IsString(name) || name.length == 0) {
    return Fail(kInvalidArgument, @"an attribute needs a non-empty name");
  }
  @try {
    [sdk clearAttribute:name];
  } @catch (NSException *exception) {
    return SdkFailure(@"clearAttribute", exception);
  }
  return Ok(nil);
}

+ (BGSFlutterFacadeResult *)clearAllAttributesWithSdk:(id<BGSFlutterFacadeSDK>)sdk {
  @try {
    [sdk clearAllAttributes];
  } @catch (NSException *exception) {
    return SdkFailure(@"clearAllAttributes", exception);
  }
  return Ok(nil);
}

// ---- User identifier ---------------------------------------------------------------------------

+ (BGSFlutterFacadeResult *)setUserIdentifierWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                          identifier:(NSString *)identifier {
  @try {
    // The SDK treats nil and an empty string as a clear, like Android's wrapper path below.
    [sdk setUserIdentifier:(IsString(identifier) && identifier.length > 0) ? identifier : nil];
  } @catch (NSException *exception) {
    return SdkFailure(@"setUserIdentifier", exception);
  }
  return Ok(nil);
}

+ (BGSFlutterFacadeResult *)getUserIdentifierWithSdk:(id<BGSFlutterFacadeSDK>)sdk {
  @try {
    NSString *id_ = [sdk getUserIdentifier];
    return Ok((IsString(id_) && id_.length > 0) ? id_ : nil);
  } @catch (NSException *exception) {
    return SdkFailure(@"getUserIdentifier", exception);
  }
}

// ---- Events, traces, logs ----------------------------------------------------------------------

+ (BGSFlutterFacadeResult *)traceWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(NSString *)name value:(id)value {
  if (!IsString(name) || name.length == 0) {
    return Fail(kInvalidArgument, @"a trace needs a non-empty name");
  }
  if (!(IsString(value) || [value isKindOfClass:[NSNumber class]])) {
    return Fail(kInvalidArgument, @"a trace value must be a string, a bool, an int or a double");
  }
  @try {
    [sdk traceName:name value:value];
  } @catch (NSException *exception) {
    return SdkFailure(@"trace", exception);
  }
  return Ok(nil);
}

+ (BGSFlutterFacadeResult *)eventWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(NSString *)name params:(id)params {
  if (!IsString(name) || name.length == 0) {
    return Fail(kInvalidArgument, @"an event needs a non-empty name");
  }
  if (params != nil && ![params isKindOfClass:[NSDictionary class]]) {
    return Fail(kInvalidArgument, @"event parameters must be a map");
  }
  for (id key in (NSDictionary *)params) {
    if (!IsString(key)) {
      return Fail(kInvalidArgument, @"event parameters need string keys");
    }
  }
  @try {
    [sdk eventName:name params:params];
  } @catch (NSException *exception) {
    return SdkFailure(@"event", exception);
  }
  return Ok(nil);
}

+ (BGSFlutterFacadeResult *)logWithSdk:(id<BGSFlutterFacadeSDK>)sdk message:(NSString *)message level:(int64_t)level {
  if (!IsString(message)) {
    return Fail(kInvalidArgument, @"a log message is required");
  }
  // `BugseeLogLevel` Error..Verbose; the same integers as Android's `LogLevel` (the manifests).
  if (level < 1 || level > 5) {
    return Fail(kInvalidArgument, @"level must be an SDK log level value (1..5)");
  }
  @try {
    [sdk logMessage:message level:(NSInteger)level];
  } @catch (NSException *exception) {
    return SdkFailure(@"log", exception);
  }
  return Ok(nil);
}

// ---- Breadcrumbs, notifications ----------------------------------------------------------------

+ (NSInteger)breadcrumbLevelForName:(NSString *)name {
  // iOS `BugseeLogLevel`: error 1, warning 2, info 3, debug 4 (Android's are debug 1 .. fatal 5).
  if ([name isEqualToString:@"error"] || [name isEqualToString:@"fatal"]) return BugseeLogLevelError;
  if ([name isEqualToString:@"warning"]) return BugseeLogLevelWarning;
  if ([name isEqualToString:@"info"]) return BugseeLogLevelInfo;
  if ([name isEqualToString:@"debug"]) return BugseeLogLevelDebug;
  return -1;
}

+ (BGSFlutterFacadeResult *)addBreadcrumbWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                        category:(NSString *)category
                                           level:(NSString *)level
                                         message:(NSString *)message
                                            type:(NSString *)type
                                            data:(id)data {
  const NSInteger sdkLevel = [self breadcrumbLevelForName:level];
  if (sdkLevel < 0) {
    return Fail(kInvalidArgument, @"level must be debug, info, warning, error or fatal");
  }
  if (!IsString(category) || !IsString(message) || !IsString(type)) {
    return Fail(kInvalidArgument, @"a breadcrumb needs a category, a message and a type");
  }
  if (data != nil && ![data isKindOfClass:[NSDictionary class]]) {
    return Fail(kInvalidArgument, @"breadcrumb data must be a map");
  }
  for (id key in (NSDictionary *)data) {
    if (!IsString(key)) {
      return Fail(kInvalidArgument, @"breadcrumb data needs string keys");
    }
  }
  @try {
    return Ok(@([sdk addBreadcrumbCategory:category
                                     level:sdkLevel
                                   message:message
                                      type:type
                                      data:data]));
  } @catch (NSException *exception) {
    return SdkFailure(@"addBreadcrumb", exception);
  }
}

/// 0 for "not given"; the SDK treats 0 as unset. A value outside 1..5 is refused (nil, message set).
+ (NSInteger)severityFrom:(NSNumber *)severity ok:(BOOL *)ok {
  *ok = YES;
  if (severity == nil) return 0;
  const long long v = severity.longLongValue;
  if (v < BGSFlutterReportOps.minSeverity || v > BGSFlutterReportOps.maxSeverity) {
    *ok = NO;
    return 0;
  }
  return (NSInteger)v;
}

/// Labels as the SDK takes them: strings. nil stays nil.
+ (nullable NSArray<NSString *> *)labelsFrom:(NSArray *)labels ok:(BOOL *)ok {
  *ok = YES;
  if (labels == nil) return nil;
  if (![labels isKindOfClass:[NSArray class]]) {
    *ok = NO;
    return nil;
  }
  for (id label in labels) {
    if (!IsString(label)) {
      *ok = NO;
      return nil;
    }
  }
  return [labels copy];
}

+ (BGSFlutterFacadeResult *)relayNotificationWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                               title:(NSString *)title
                                                body:(NSString *)body
                                            severity:(NSNumber *)severity
                                              fields:(NSArray *)flat
                                              urgent:(BOOL)urgent {
  if (!IsString(title) || [[title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] == 0) {
    // Both SDKs drop it and only log.
    return Fail(kInvalidArgument, @"a notification needs a non-empty title");
  }
  BOOL ok = YES;
  const NSInteger sdkSeverity = [self severityFrom:severity ok:&ok];
  if (!ok) {
    return Fail(kInvalidArgument, @"severity must be an SDK severity value (1..5)");
  }
  NSMutableDictionary<NSString *, NSString *> *fields = nil;
  if (flat != nil) {
    if (![flat isKindOfClass:[NSArray class]] || flat.count % 2 != 0) {
      return Fail(kInvalidArgument, @"notification fields are key, value pairs");
    }
    fields = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < flat.count; i += 2) {
      if (!IsString(flat[i]) || !IsString(flat[i + 1])) {
        return Fail(kInvalidArgument, @"notification fields must be strings");
      }
      fields[flat[i]] = flat[i + 1];
    }
  }
  @try {
    [sdk notifyTitle:title body:body severity:sdkSeverity fields:fields urgent:urgent];
  } @catch (NSException *exception) {
    return SdkFailure(@"notify", exception);
  }
  return Ok(nil);
}

// ---- Blackout ----------------------------------------------------------------------------------

+ (BGSFlutterFacadeResult *)startBlackoutWithSdk:(id<BGSFlutterFacadeSDK>)sdk {
  @try {
    [sdk startBlackout];
  } @catch (NSException *exception) {
    return SdkFailure(@"startBlackout", exception);
  }
  return Ok(nil);
}

+ (BGSFlutterFacadeResult *)endBlackoutWithSdk:(id<BGSFlutterFacadeSDK>)sdk {
  @try {
    [sdk endBlackout];
  } @catch (NSException *exception) {
    return SdkFailure(@"endBlackout", exception);
  }
  return Ok(nil);
}

+ (BGSFlutterFacadeResult *)isBlackoutWithSdk:(id<BGSFlutterFacadeSDK>)sdk {
  @try {
    return Ok(@([sdk isBlackout]));
  } @catch (NSException *exception) {
    return SdkFailure(@"isBlackout", exception);
  }
}

// ---- Reports -----------------------------------------------------------------------------------

+ (BGSFlutterFacadeResult *)showReportDialogWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                            summary:(NSString *)summary
                                        description:(NSString *)description
                                           severity:(NSNumber *)severity
                                             labels:(NSArray *)labels {
  BOOL ok = YES;
  const NSInteger sdkSeverity = [self severityFrom:severity ok:&ok];
  if (!ok) {
    return Fail(kInvalidArgument, @"severity must be an SDK severity value (1..5)");
  }
  NSArray<NSString *> *checked = [self labelsFrom:labels ok:&ok];
  if (!ok) {
    return Fail(kInvalidArgument, @"labels must be a list of strings");
  }
  @try {
    [sdk showReportDialogSummary:summary description:description severity:sdkSeverity labels:checked];
  } @catch (NSException *exception) {
    return SdkFailure(@"showReportDialog", exception);
  }
  return Ok(nil);
}

+ (BGSFlutterFacadeResult *)uploadWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                  summary:(NSString *)summary
                              description:(NSString *)description
                                 severity:(NSNumber *)severity
                                   labels:(NSArray *)labels {
  if (!IsString(summary) || !IsString(description)) {
    return Fail(kInvalidArgument, @"a report needs a summary and a description");
  }
  BOOL ok = YES;
  const NSInteger sdkSeverity = [self severityFrom:severity ok:&ok];
  if (!ok) {
    return Fail(kInvalidArgument, @"severity must be an SDK severity value (1..5)");
  }
  NSArray<NSString *> *checked = [self labelsFrom:labels ok:&ok];
  if (!ok) {
    return Fail(kInvalidArgument, @"labels must be a list of strings");
  }
  @try {
    [sdk uploadSummary:summary description:description severity:sdkSeverity labels:checked];
  } @catch (NSException *exception) {
    return SdkFailure(@"upload", exception);
  }
  return Ok(nil);
}

@end
