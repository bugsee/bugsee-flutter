#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the store reads off the device, at every pull.
@protocol BGSFlutterSecureEnvironment <NSObject>
/// The display's physical pixels per Flutter logical pixel right now (iOS: `UIScreen.scale`,
/// which is Flutter's device pixel ratio). Read at every pull, never cached. The ratio a message
/// was measured at must equal it, or the whole display is covered until Dart republishes. Not
/// finite or not positive means "unknown" and fails closed.
- (double)nativePixelRatioForDisplay:(NSInteger)display;
/// SDK units per physical pixel: `1 / UIScreen.scale` on iOS (the SDK takes points). With a
/// matching ratio a Flutter logical pixel is therefore exactly one point, and the screen's scale
/// is never multiplied in.
- (double)unitsPerPhysicalPixelForDisplay:(NSInteger)display;
/// The display's size in points in the current orientation; `CGSizeZero` when unknown.
- (CGSize)displayBoundsInPointsForDisplay:(NSInteger)display;
@end

typedef NS_ENUM(NSInteger, BGSFlutterPlacementKind) {
  /// The view's position on the screen is known.
  BGSFlutterPlacementKnown,
  /// Not known: serve the whole display (fail closed).
  BGSFlutterPlacementUnknown,
  /// Known not to be on screen: serve nothing.
  BGSFlutterPlacementAbsent,
};

/// What one view published: the ratio it was measured at and its flat logical ltrb (packed
/// native-endian doubles).
@interface BGSFlutterSecureViewRects : NSObject
@property(nonatomic, readonly) double ratio;
@property(nonatomic, readonly, copy) NSData *rects;
- (instancetype)initWithRatio:(double)ratio rects:(NSData *)rects;
@end

/// Where one Flutter view sits on the screen, in points.
@interface BGSFlutterSecurePlacement : NSObject
@property(nonatomic, readonly) BGSFlutterPlacementKind kind;
@property(nonatomic, readonly) NSInteger display;
@property(nonatomic, readonly) double x;
@property(nonatomic, readonly) double y;
/// The view's own scale on screen (it, or an ancestor, is scaled); 1 normally.
@property(nonatomic, readonly) double scaleX;
@property(nonatomic, readonly) double scaleY;
+ (instancetype)knownOnDisplay:(NSInteger)display x:(double)x y:(double)y;
+ (instancetype)knownOnDisplay:(NSInteger)display
                             x:(double)x
                             y:(double)y
                        scaleX:(double)scaleX
                        scaleY:(double)scaleY;
+ (instancetype)unknown;
+ (instancetype)absent;
@end

/// Where the secure-rectangle sets live (workbook 5.4.2): outside the wrapper
/// object, because the wrapper is replaced mid-session when Dart refines the
/// identity, and the regions must survive that or the app is recorded
/// unredacted until it next republishes.
///
/// What the SDK takes (iOS 7.0.0-beta7, BGSContracts.h `secureRectanglesForDisplay:`):
/// a packed little-endian int32 `[version, count, l, t, r, b, ...]`; the rectangles
/// are in POINTS in the screen's coordinate space, origin top-left, `r`/`b` exclusive
/// (the SDK draws them as they are over the recorded frame, which is the screen), and
/// the SDK edge-rounds nothing itself, so fractional edges must be rounded OUTWARD
/// here. Only display 0 is polled today; it is called once per captured frame and per
/// report screenshot on the thread that snapshots the frame (currently the main
/// thread). A non-zero version equal to the last one seen makes the SDK skip the
/// rectangles; 0 makes it compare them; a count of 0 clears the set.
///
/// Dart publishes Flutter LOGICAL pixels relative to its view, with the pixel ratio it measured
/// them at. This class multiplies by that ratio and by `unitsPerPhysicalPixel` (so by 1 on iOS),
/// by the view's own on-screen scale, adds the view's position on the screen, then rounds outward
/// (scale BEFORE rounding, 5.3.1). The screen's scale is read at every pull and must equal the
/// ratio: a mismatch (Flutter has not caught up with a display change) covers the whole display
/// until Dart republishes.
///
/// Grace window: every set that stops being current is served as well for `+graceSeconds` from the
/// moment IT stopped (not from the last change, so a long movement does not widen the cover to its
/// path), because Dart measures after a frame and the message crosses a channel while
/// the frame may be captured first. It only ever over-covers; the union shrinking back is itself a
/// change and moves the version. A region that has just APPEARED has no previous place, so its
/// first frame can still be recorded before the message lands: the one exposure left.
///
/// Versions are derived from what is served, per display: they move exactly when the
/// served rectangles differ from the ones served before, never otherwise, and skip 0.
/// A display that never had a rectangle serves `[0, 0]`.
///
/// Fail closed: a view whose placement is unknown, a rectangle that is not finite, a
/// malformed list and a scale that is not a positive finite number are each served as
/// ONE rectangle covering the whole display; a view known to be off screen serves nothing.
///
/// Thread safety: written state is immutable and replaced whole; the served buffer is an
/// immutable `NSData` (5.4.1).
@interface BGSFlutterSecureRectangleStore : NSObject

+ (instancetype)shared;
/// Knows nothing about the device until an environment is installed: every view covers
/// the whole display.
- (instancetype)init;
/// No grace window: what is written is what is served at once. For tests.
- (instancetype)initWithEnvironment:(id<BGSFlutterSecureEnvironment>)environment;
/// `clock` returns seconds from a monotonic source; `grace` is how long each past set is served after
/// it stopped being current (0 for none).
- (instancetype)initWithEnvironment:(id<BGSFlutterSecureEnvironment>)environment
                              clock:(NSTimeInterval (^)(void))clock
                              grace:(NSTimeInterval)grace NS_DESIGNATED_INITIALIZER;

/// How long each past set is served after it stopped being current. Repeated in Java (`GRACE_MS`).
+ (NSTimeInterval)graceSeconds;

- (void)setEnvironment:(id<BGSFlutterSecureEnvironment>)environment;

/// Called first by every `-pullForDisplay:` (the placement tracker's refresh request).
/// It must not block.
- (void)setPullHook:(nullable void (^)(void))hook;

/// Applies Dart's whole state for `owner`: `views` maps a view id to what it published; a view
/// not in it has no rectangles any more. Ignored (returns NO) when `epoch` is the current one and
/// `sequence` is not newer, or when `epoch` was retired (a straggler of a dead isolate). An epoch
/// not seen before is a new isolate (a hot restart): it replaces the old one's state and retires
/// its epoch. Epochs are random ids, never clocks.
- (BOOL)publishForOwner:(int64_t)owner
                  epoch:(int64_t)epoch
               sequence:(int64_t)sequence
                  views:(NSDictionary<NSNumber *, BGSFlutterSecureViewRects *> *)views;

/// Where `owner`'s view `viewId` sits now. Not a change when it is the same.
- (void)setPlacement:(BGSFlutterSecurePlacement *)placement
            forOwner:(int64_t)owner
              viewId:(int64_t)viewId;

/// Dart's engine is gone: forget its rectangles, placements and ordering.
- (void)dropOwner:(int64_t)owner;

/// The SDK's pull: asks for a placement refresh, then serves.
- (NSData *)pullForDisplay:(NSInteger)display;

/// The buffer for `display`, computed from the current state, scale and size.
- (NSData *)snapshotForDisplay:(NSInteger)display;

/// The version after `version`: wraps, never lands on 0 (unknown).
+ (int32_t)versionAfter:(int32_t)version;

/// For tests only.
- (void)clearForTests;

@end

NS_ASSUME_NONNULL_END
