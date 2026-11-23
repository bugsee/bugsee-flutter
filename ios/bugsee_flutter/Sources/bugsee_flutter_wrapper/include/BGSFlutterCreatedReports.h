#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Arms a deadline; returns a token for the cancel block.
typedef id _Nullable (^BGSFlutterCreatedScheduler)(dispatch_block_t task, int64_t delayMs);
typedef void (^BGSFlutterCreatedCancel)(id token);
/// Milliseconds on a monotonic clock; injectable so a test controls time.
typedef int64_t (^BGSFlutterCreatedClock)(void);

/// What `-reserve...` answers for a request over the rate limit (a stamp is never this).
FOUNDATION_EXPORT const NSUInteger BGSFlutterCreatedRateLimited;
/// At most this many created reports may be started in `BGSFlutterCreatedRateWindowMs`. The SDKs have no
/// public way to cancel a created report: one the app discards or forgets leaves the SDK's opened snapshot
/// on disk until the next launch's recovery drops it, so a create/discard loop would grow storage without
/// bound. This is the bound.
FOUNDATION_EXPORT const NSUInteger BGSFlutterCreatedRateLimit;
FOUNDATION_EXPORT const int64_t BGSFlutterCreatedRateWindowMs;

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
                           cancel:(BGSFlutterCreatedCancel)cancel
                            clock:(BGSFlutterCreatedClock)clock NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The stamp `-fulfil:...` must present, 0 when a report is reserved or held, or
/// `BGSFlutterCreatedRateLimited`. `owner` is the engine asking: only its reset releases what the
/// reservation becomes. `onTimeout` runs when the SDK has not answered within `createTimeoutMs` (its late
/// answer will be refused).
- (NSUInteger)reserveForOwner:(id)owner createTimeoutMs:(int64_t)createTimeoutMs onTimeout:(dispatch_block_t)onTimeout;

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
/// Drops what `owner` reserved or holds (nothing, when the slot is another engine's: a second engine's
/// Dart isolate starting must not destroy the first one's report); every stamp issued for the dropped
/// reservation fails `-fulfil:`. Returns the held report that was dropped.
- (nullable id)clearOwner:(id)owner;

@end

NS_ASSUME_NONNULL_END
