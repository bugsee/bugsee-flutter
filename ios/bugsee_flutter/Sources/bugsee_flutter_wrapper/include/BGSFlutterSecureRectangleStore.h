#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where the secure-rectangle sets live (workbook 5.4.2): outside the wrapper
/// object, because the wrapper is replaced mid-session when Dart refines the
/// identity, and the regions must survive that or the app is recorded
/// unredacted until it next republishes.
///
/// Empty for now; Phase 3b fills it. A set is the SDK's packed buffer
/// `[version, count, l, t, r, b, ...]` (little-endian int32), kept per display
/// (5.2.3). Stored as published (an immutable NSData copy) and handed out as is,
/// so the SDK thread that pulls it never sees a half-written set (5.4.1).
@interface BGSFlutterSecureRectangleStore : NSObject

+ (instancetype)shared;
- (instancetype)init;

/// The set last published for `display`, or the empty set: `[0, 0]`. Version 0 is
/// the contract's "unknown", so the SDK compares the rectangles themselves; a
/// constant real version would let a later set that also starts at that version,
/// with real rectangles, be ignored (the SDK caches by version per display:
/// unredacted capture).
- (NSData *)snapshotForDisplay:(NSInteger)display;

/// Replaces the set for `display`. The data is copied.
- (void)publish:(NSData *)buffer forDisplay:(NSInteger)display;

/// For tests only.
- (void)clearForTests;

@end

NS_ASSUME_NONNULL_END
