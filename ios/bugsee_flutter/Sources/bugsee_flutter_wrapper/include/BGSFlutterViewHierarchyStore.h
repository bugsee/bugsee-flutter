#import <Foundation/Foundation.h>

@class BGSFlutterSecureRectangleStore;

NS_ASSUME_NONNULL_BEGIN

/// Where the managed view hierarchy (the SDK's `vh` data request) lives, and what answers it.
///
/// Why a cache. The SDK asks for `vh` from `-requestDataWithType:callback:` on the MAIN thread
/// and times the reply from when the call RETURNS (500 ms, `BGSManagedHierarchyTimeoutMs` in
/// BGSCaptureDataProviderViewHierarchy.m), after which a late reply is ignored. Flutter's Dart
/// isolate cannot answer from there: it needs the platform thread to reply, so a wait for Dart on
/// the main thread is a deadlock (the report pipeline avoids the same one). So Dart PUSHES each
/// snapshot here (`-publishForOwner:...`) and this class answers immediately, from memory, on
/// whatever thread asks. It also never counts toward the SDK's "silent wrapper" backoff (three
/// timeouts cut the budget to 50 ms): an answer, even `nil`, is not a timeout.
///
/// What is stored. A JSON TEMPLATE: text cut at the place of the snapshot's age and of every
/// node's box, plus the boxes in the view's LOGICAL pixels. The text is never parsed and never
/// changed except for those insertions. At answer time each box is converted by
/// `BGSFlutterPlacementMapper`, the code that places the secure rectangles: POINTS in the
/// screen's coordinate space, the unit of the native tree (workbook 5.3, 6.6). The conversion
/// needs the view's current position and the screen's scale, so it is done per answer, never
/// cached.
///
/// Fail closed. The answer is `nil` (the SDK records nothing from the wrapper) when there is no
/// snapshot, when the view is not placed or is in no window, when the screen's scale no longer
/// matches the one the boxes were measured at, or when a box is not finite. Never a partial
/// answer. A message that is not shaped as documented in `ViewHierarchyMessage`, or too large,
/// clears the sender's snapshot.
///
/// Ownership. Process-wide and outside the wrapper object (which is replaced when Dart refines
/// the identity), like the secure rectangles. Snapshots are per Dart isolate (owner = engine);
/// an engine's detach drops its snapshot (a detached engine serves nothing, never a stale
/// tree). With several engines the newest snapshot that can be rendered is served (a newer one whose view is hidden does not hide an older one that can be shown).
/// State is immutable and swapped whole under a write lock.
///
/// Staleness. A snapshot is as of the last frame that changed the tree (plus Dart's throttle,
/// 300 ms by default); Flutter draws nothing without a frame, so an unchanged screen is still
/// described exactly however old the snapshot. Its age is written into the payload
/// (`options.age_ms`) because the SDK stamps the entry with the time of the REPLY. No maximum
/// age: see doc/view-hierarchy.md.
@interface BGSFlutterViewHierarchyStore : NSObject

+ (instancetype)shared;

/// The SDK's `BGSManagedHierarchyDataType`. Compared with the SDK's source by a drift guard.
+ (NSString *)dataType;

/// Most characters of template one snapshot may hold.
+ (NSUInteger)maxTemplateCharacters;

- (instancetype)initWithPlacement:(BGSFlutterSecureRectangleStore *)placement
                            clock:(NSTimeInterval (^)(void))clock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Run before every answer: a re-read of where the Flutter views are (the SDK asks on the main
/// thread, so this is synchronous there). Defaults to the placement store's pull refresh.
- (void)setRefresher:(nullable void (^)(void))refresher;

/// Applies a message of `owner`. Empty `segments` clears the owner's snapshot; a malformed or
/// oversize one clears it too (and is YES: applied as a clear). `bounds` is packed native-endian
/// doubles, flat ltrb. NO, changing nothing, for an older message or a retired epoch.
- (BOOL)publishForOwner:(int64_t)owner
                  epoch:(int64_t)epoch
               sequence:(int64_t)sequence
                 viewId:(int64_t)viewId
                  ratio:(double)ratio
               segments:(NSArray<NSString *> *)segments
                 bounds:(NSData *)bounds;

/// Dart's engine is gone: nothing of it is served any more.
- (void)dropOwner:(int64_t)owner;

/// The SDK's `vh` answer: the newest snapshot rendered for the screen as it is now, or `nil`. Any
/// thread; never blocks; never throws.
- (nullable NSString *)answer;

/// For tests only.
- (void)clearForTests;

@end

NS_ASSUME_NONNULL_END
