#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The SDK entry points the facade uses; the real ones are `BGSFlutterRealFacade`. A seam so a
/// unit test can see what reaches the SDK (the Android twin is `FacadeOps.Sdk`). Every method is
/// called on the platform (main) thread, which is where the SDK's public API is used.
@protocol BGSFlutterFacadeSDK <NSObject>
- (void)setAttribute:(NSString *)name value:(id)value;
- (nullable id)getAttribute:(NSString *)name;
- (nullable NSDictionary<NSString *, id> *)getAllAttributes;
- (void)clearAttribute:(NSString *)name;
- (void)clearAllAttributes;
- (void)setUserIdentifier:(nullable NSString *)identifier;
- (nullable NSString *)getUserIdentifier;
- (void)traceName:(NSString *)name value:(id)value;
- (void)eventName:(NSString *)name params:(nullable NSDictionary *)params;
- (void)logMessage:(NSString *)message level:(NSInteger)level;
- (void)notifyTitle:(NSString *)title
               body:(nullable NSString *)body
           severity:(NSInteger)severity
             fields:(nullable NSDictionary<NSString *, NSString *> *)fields
             urgent:(BOOL)urgent;
/// The SDK's own `BugseeLogLevel` integer for the crumb (the caller maps the name).
- (BOOL)addBreadcrumbCategory:(NSString *)category
                        level:(NSInteger)level
                      message:(NSString *)message
                         type:(NSString *)type
                         data:(nullable NSDictionary *)data;
- (void)startBlackout;
- (void)endBlackout;
- (BOOL)isBlackout;
/// `severity` 0 is "not given": the SDK applies its default priority.
- (void)showReportDialogSummary:(nullable NSString *)summary
                    description:(nullable NSString *)description
                       severity:(NSInteger)severity
                         labels:(nullable NSArray<NSString *> *)labels;
- (void)uploadSummary:(NSString *)summary
          description:(NSString *)description
             severity:(NSInteger)severity
               labels:(nullable NSArray<NSString *> *)labels;
@end

/// The real SDK.
@interface BGSFlutterRealFacade : NSObject <BGSFlutterFacadeSDK>
@end

/// What a facade operation answers: a value, or a failure with the bridge's code. An SDK exception
/// (an `NSException` would crash Swift) is a failure, never an escape.
@interface BGSFlutterFacadeResult : NSObject
@property(nonatomic, strong, nullable) id value;
@property(nonatomic, copy, nullable) NSString *errorCode;
@property(nonatomic, copy, nullable) NSString *errorMessage;
@property(nonatomic, readonly) BOOL failed;
@end

/// The rest of the public facade (Phase 4b): attributes, identity, events, traces, logs,
/// breadcrumbs, notifications, blackout and the two report entry points. Decisions here, SDK behind
/// the seam above. Dart validates first; this defends again.
///
/// Before launch the wrapper queues and gates nothing: each SDK entry point does what it does
/// (doc/api-surface.md, per method, from iOS 7.0.0-beta7 source). Attributes (NSUserDefaults), the
/// user identifier (Keychain) and blackout (a flag the video provider reads) work; event, trace,
/// log, breadcrumb, notification, the dialog and upload are dropped.
@interface BGSFlutterFacadeOps : NSObject

/// The strings of a failure's code; `test/facade_drift_test.dart` compares them with Dart.
@property(class, readonly) NSString *invalidArgument;
@property(class, readonly) NSString *attributeRejected;
@property(class, readonly) NSString *sdkError;
@property(class, readonly) NSString *notAttached;

/// Dart's longest attribute string (1024 UTF-16 units: Android's SDK limit, applied to both).
@property(class, readonly) NSInteger attributeStringMaxLength;

// Attributes. `value` of the result: nothing (set, clear), the value (get) or the dictionary.
+ (BGSFlutterFacadeResult *)setAttributeWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(nullable NSString *)name value:(nullable id)value NS_SWIFT_NAME(setAttribute(sdk:name:value:));
+ (BGSFlutterFacadeResult *)getAttributeWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(nullable NSString *)name NS_SWIFT_NAME(getAttribute(sdk:name:));
+ (BGSFlutterFacadeResult *)getAllAttributesWithSdk:(id<BGSFlutterFacadeSDK>)sdk NS_SWIFT_NAME(getAllAttributes(sdk:));
+ (BGSFlutterFacadeResult *)clearAttributeWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(nullable NSString *)name NS_SWIFT_NAME(clearAttribute(sdk:name:));
+ (BGSFlutterFacadeResult *)clearAllAttributesWithSdk:(id<BGSFlutterFacadeSDK>)sdk NS_SWIFT_NAME(clearAllAttributes(sdk:));

/// A stored value as the channel carries it (string, number, array of strings), or nil.
+ (nullable id)dartValueFromStored:(nullable id)stored;
/// Whether the SDK holds what was sent.
+ (BOOL)sentValue:(id)sent matchesStored:(nullable id)stored;

// User identifier.
+ (BGSFlutterFacadeResult *)setUserIdentifierWithSdk:(id<BGSFlutterFacadeSDK>)sdk identifier:(nullable NSString *)identifier NS_SWIFT_NAME(setUserIdentifier(sdk:identifier:));
+ (BGSFlutterFacadeResult *)getUserIdentifierWithSdk:(id<BGSFlutterFacadeSDK>)sdk NS_SWIFT_NAME(getUserIdentifier(sdk:));

// Events, traces, logs.
+ (BGSFlutterFacadeResult *)traceWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(nullable NSString *)name value:(nullable id)value NS_SWIFT_NAME(trace(sdk:name:value:));
+ (BGSFlutterFacadeResult *)eventWithSdk:(id<BGSFlutterFacadeSDK>)sdk name:(nullable NSString *)name params:(nullable id)params NS_SWIFT_NAME(event(sdk:name:params:));
+ (BGSFlutterFacadeResult *)logWithSdk:(id<BGSFlutterFacadeSDK>)sdk message:(nullable NSString *)message level:(int64_t)level NS_SWIFT_NAME(log(sdk:message:level:));

// Breadcrumbs, notifications.
/// `BugseeLogLevel` for a wire name, or -1. error and fatal are both `BugseeLogLevelError` (iOS has
/// no fatal rung).
+ (NSInteger)breadcrumbLevelForName:(nullable NSString *)name;
+ (BGSFlutterFacadeResult *)addBreadcrumbWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                        category:(nullable NSString *)category
                                           level:(nullable NSString *)level
                                         message:(nullable NSString *)message
                                            type:(nullable NSString *)type
                                            data:(nullable id)data NS_SWIFT_NAME(addBreadcrumb(sdk:category:level:message:type:data:));
+ (BGSFlutterFacadeResult *)relayNotificationWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                               title:(nullable NSString *)title
                                                body:(nullable NSString *)body
                                            severity:(nullable NSNumber *)severity
                                              fields:(nullable NSArray *)flatFields
                                              urgent:(BOOL)urgent NS_SWIFT_NAME(relayNotification(sdk:title:body:severity:fields:urgent:));

// Blackout.
+ (BGSFlutterFacadeResult *)startBlackoutWithSdk:(id<BGSFlutterFacadeSDK>)sdk NS_SWIFT_NAME(startBlackout(sdk:));
+ (BGSFlutterFacadeResult *)endBlackoutWithSdk:(id<BGSFlutterFacadeSDK>)sdk NS_SWIFT_NAME(endBlackout(sdk:));
+ (BGSFlutterFacadeResult *)isBlackoutWithSdk:(id<BGSFlutterFacadeSDK>)sdk NS_SWIFT_NAME(isBlackout(sdk:));

// Reports.
+ (BGSFlutterFacadeResult *)showReportDialogWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                            summary:(nullable NSString *)summary
                                        description:(nullable NSString *)description
                                           severity:(nullable NSNumber *)severity
                                             labels:(nullable NSArray *)labels NS_SWIFT_NAME(showReportDialog(sdk:summary:description:severity:labels:));
+ (BGSFlutterFacadeResult *)uploadWithSdk:(id<BGSFlutterFacadeSDK>)sdk
                                  summary:(nullable NSString *)summary
                              description:(nullable NSString *)description
                                 severity:(nullable NSNumber *)severity
                                   labels:(nullable NSArray *)labels NS_SWIFT_NAME(upload(sdk:summary:description:severity:labels:));

@end

NS_ASSUME_NONNULL_END
