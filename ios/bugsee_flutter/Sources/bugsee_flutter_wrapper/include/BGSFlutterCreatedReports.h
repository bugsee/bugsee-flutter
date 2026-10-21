#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Arms a deadline; returns a token for the cancel block.
typedef id _Nullable (^BGSFlutterCreatedScheduler)(dispatch_block_t task, int64_t delayMs);
typedef void (^BGSFlutterCreatedCancel)(id token);

/// The one created report (`+[Bugsee createReportWithCompletion:]`) this process may hold, under an
/// opaque handle, with a deadline on every stage so nothing the app forgot is kept for good.
///
/// States: idle; RESERVED (the SDK was asked, its completion has not answered: bounded by the create
/// timeout); HELD (handed to Dart: bounded by the time to live). A second request while one is
/// reserved or held is refused (`-reserve...` returns 0), so a forgotten report cannot be joined by
/// another.
///
/// Every reservation carries a STAMP and every answer must present it, so an SDK completion that
/// arrives after its reservation timed out can neither take the slot of a newer one nor publish its
/// report. Handles are `cr-<n>`, numbered from 1 for the life of the process, never reused. The
/// callbacks run outside the lock; the report is `id` so this header needs no SDK import.
@interface BGSFlutterCreatedReports : NSObject

+ (instancetype)shared;
- (instancetype)initWithScheduler:(BGSFlutterCreatedScheduler)scheduler
                           cancel:(BGSFlutterCreatedCancel)cancel NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The stamp `-fulfil:...` must present, or 0 when a report is reserved or held. `onTimeout` runs when
/// the SDK has not answered within `createTimeoutMs` (its late answer will be refused).
- (NSUInteger)reserveWithCreateTimeoutMs:(int64_t)createTimeoutMs onTimeout:(dispatch_block_t)onTimeout;

/// Ends the reservation `stamp` names. A report gets `cr-<n>` and is held for `ttlMs`, after which it is
/// removed and `onExpired` runs with it; nil frees the slot. A stamp that is not the current one (timed
/// out, cleared, or a second answer) changes nothing and returns nil: the caller then discards `report`.
- (nullable NSString *)fulfil:(NSUInteger)stamp
                       report:(nullable id)report
                        ttlMs:(int64_t)ttlMs
                    onExpired:(void (^)(id report))onExpired;

- (BOOL)isReserved:(NSUInteger)stamp;
- (nullable id)reportForHandle:(nullable NSString *)handle;
/// Removes the report and frees the slot. An unknown handle removes nothing.
- (nullable id)takeHandle:(nullable NSString *)handle;
/// Drops whatever is held or reserved; every stamp issued so far fails `-fulfil:`.
- (nullable id)clear;

@end

NS_ASSUME_NONNULL_END
