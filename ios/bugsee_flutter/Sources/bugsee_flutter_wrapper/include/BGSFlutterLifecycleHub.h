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
/// Receivers: any number may be attached (a UI engine and a background engine);
/// each gets every event, and detaching one leaves the others alone.
///
/// Buffering: while NO receiver is attached, and the first events of a launch happen
/// long before a Dart isolate can listen, events are kept in order in a buffer of at
/// most `+bufferCapacity` entries and flushed to the next receiver. When full the
/// OLDEST event is dropped (the freshest state matters most) and counted in
/// `droppedCount`; the first drop is logged, then every `+dropLogEvery`th. The latest
/// status event is also remembered and replayed to every new receiver, so a restarted
/// engine knows the status.
///
/// Limit: the guarantees end at the hop into the sink. Report events still in this buffer are
/// flushed to the next receiver and events in flight to the LAST receiver that detaches go
/// back to the buffer; an event already SENT over the channel while Dart has no handler is held only by
/// Flutter's channel buffer (one message by default) and is not retried. Consumers must not
/// rely on delivery surviving a restart.
///
/// Names: prefix stripped once; unknown names and names without the prefix are
/// forwarded unchanged (4.3).
@interface BGSFlutterLifecycleHub : NSObject

/// The prefix both SDKs put on every lifecycle event name.
+ (NSString *)prefix;
/// At most this many events are kept while no Dart side is attached.
+ (NSUInteger)bufferCapacity;
/// Drops are always counted; a warning is logged for the first and then every Nth.
+ (NSUInteger)dropLogEvery;

+ (instancetype)shared;
- (instancetype)initWithDeliveryQueue:(dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Called by the wrapper from the SDK's queue. Never throws.
- (void)dispatchRawName:(nullable NSString *)rawName data:(nullable id)data;

/// Adds `sink` as a receiver; it first gets what it missed (see above), in order,
/// ahead of any event dispatched afterwards. Returns a token for `-detach:`.
- (id)attachSink:(BGSFlutterLifecycleSink)sink;

/// Removes only this receiver. Events posted to it that have not run yet go back to
/// the front of the buffer when no receiver remains.
- (void)detach:(id)token;

/// As `-detach:`, also handing back events the sink took but never sent on (a sink that
/// queues, such as the Swift plugin's pump). When no receiver remains they go to the
/// front of the buffer, ahead of what was still waiting for the sink, in order.
- (void)detach:(id)token undelivered:(nullable NSArray<BGSFlutterLifecycleEvent *> *)undelivered;

@property(atomic, readonly) NSUInteger droppedCount;
@property(atomic, readonly) NSUInteger bufferedCount;

/// Exposed for tests: the event the hub would build for a raw name and payload.
+ (BGSFlutterLifecycleEvent *)eventForRawName:(NSString *)rawName data:(nullable id)data;

@end

NS_ASSUME_NONNULL_END
