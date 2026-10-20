#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One SDK lifecycle event, as handed to the Dart side.
@interface BGSFlutterLifecycleEvent : NSObject
/// The name with the `com.bugsee.lifecycle.` prefix stripped (once). A name this
/// wrapper does not know is carried unchanged.
@property(nonatomic, copy, readonly) NSString *name;
/// Set only for the events that carry a report id; carried, not interpreted.
@property(nonatomic, copy, readonly, nullable) NSString *reportId;
/// String-to-string payload entries that crossed cleanly; nil when none.
@property(nonatomic, copy, readonly, nullable) NSDictionary<NSString *, NSString *> *data;
@end

typedef void (^BGSFlutterLifecycleSink)(BGSFlutterLifecycleEvent *event);

/// Carries the SDK's lifecycle events from the registered wrapper to the Dart
/// side (workbook Part 4). Process-wide and independent of the wrapper object
/// (which is replaced when Dart refines the identity) and of the Flutter engine
/// (which appears later).
///
/// Threading: the SDK calls the wrapper on its own serial queue, never the main
/// thread (4.4). Flutter channels must be used on the platform thread, so every
/// delivery is dispatched to the delivery queue (the main queue in production).
///
/// Buffering: until Dart attaches there is no sink, and the first events of a
/// launch happen long before a Dart isolate can listen. Events are kept in order
/// in a buffer of at most `+bufferCapacity` entries and flushed on attach. When
/// full the OLDEST event is dropped (the freshest state matters most) and counted
/// in `droppedCount`.
///
/// Names: prefix stripped once; unknown names and names without the prefix are
/// forwarded unchanged (4.3).
@interface BGSFlutterLifecycleHub : NSObject

/// The prefix both SDKs put on every lifecycle event name.
+ (NSString *)prefix;
/// At most this many events are kept while no Dart side is attached.
+ (NSUInteger)bufferCapacity;

+ (instancetype)shared;
- (instancetype)initWithDeliveryQueue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Called by the wrapper from the SDK's queue. Never throws.
- (void)dispatchRawName:(nullable NSString *)rawName data:(nullable id)data;

/// Makes `sink` the receiver and flushes the buffer to it, in order, ahead of
/// any event dispatched afterwards. Returns a token for `-detach:`.
- (id)attachSink:(BGSFlutterLifecycleSink)sink;

/// Detaches only while `token` is still the receiver (a second engine may have
/// attached). Events buffer again until the next attach.
- (void)detach:(id)token;

@property(atomic, readonly) NSUInteger droppedCount;
@property(atomic, readonly) NSUInteger bufferedCount;

/// Exposed for tests: the event the hub would build for a raw name and payload.
+ (BGSFlutterLifecycleEvent *)eventForRawName:(NSString *)rawName data:(nullable id)data;

@end

NS_ASSUME_NONNULL_END
