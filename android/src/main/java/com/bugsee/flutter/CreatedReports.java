package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.reporting.Report;

/**
 * The one created report ({@code Bugsee.createReport}) this process may hold, under an opaque handle,
 * with a deadline on every stage so nothing the app forgot is kept for good.
 *
 * <p>States: idle; RESERVED (the SDK was asked, its listener has not answered: bounded by the
 * create timeout); HELD (handed to Dart: bounded by the time to live). A second request while one is
 * reserved or held is refused ({@link #reserve} returns 0), so a forgotten report cannot be joined by
 * another, each holding the SDK's snapshot and capture buffers.
 *
 * <p>Every reservation carries a STAMP and every answer must present it, so an SDK listener that
 * arrives after its reservation timed out can neither take the slot of a newer one nor publish its
 * report: {@link #fulfil} refuses it and the caller discards that report. Handles are {@code cr-<n>},
 * numbered from 1 for the life of the process, never reused. The scheduler and the clock of the timers
 * are injected; nothing in here blocks, and the callbacks run outside the monitor.
 */
final class CreatedReports {

    /** What the timers call back with. Run outside the monitor, on the scheduler's thread. */
    interface Expiry {
        /** The SDK did not answer in time; its late answer will be refused. */
        void createTimedOut();

        /** The time to live passed: release {@code report} (it was removed already). */
        void expired(@NonNull Report report);
    }

    /** What {@link #reserve} answers for a request over the rate limit. */
    static final int RATE_LIMITED = -1;

    /**
     * At most this many created reports may be started in {@link #RATE_WINDOW_MS}. The SDKs have no way
     * to cancel a created report (no public call on either): a report the app discards or forgets leaves
     * the SDK's opened snapshot on disk until the next launch's recovery drops it, so a create/discard
     * loop would grow storage without bound. This is the bound.
     */
    static final int RATE_LIMIT = 6;
    static final long RATE_WINDOW_MS = 60_000L;

    /** Milliseconds on a monotonic clock; a seam. */
    interface Clock {
        long nowMs();
    }

    private static final CreatedReports SHARED = new CreatedReports(
            new ReportHandlerPipeline.DaemonScheduler(), () -> System.nanoTime() / 1_000_000L);

    @NonNull
    static CreatedReports shared() {
        return SHARED;
    }

    private final ReportHandlerPipeline.Scheduler scheduler;
    private final Clock clock;
    /** When each recent reservation was made, oldest first; guarded by this. */
    private final java.util.ArrayDeque<Long> recent = new java.util.ArrayDeque<>();
    /** The engine whose Dart isolate asked for the reservation or the held report. */
    @Nullable private Object owner;

    /** True from a successful reserve until that reservation is ended. */
    private boolean creating;
    private int currentStamp;
    private int nextStamp = 1;
    @Nullable private Report report;
    @Nullable private String handle;
    private int next = 1;
    @Nullable private ReportHandlerPipeline.Cancellable timer;

    CreatedReports(@NonNull final ReportHandlerPipeline.Scheduler scheduler, @NonNull final Clock clock) {
        this.scheduler = scheduler;
        this.clock = clock;
    }

    /**
     * @param engine the engine asking; only its reset releases what this reservation becomes
     * @return the stamp {@link #fulfil} must present, 0 when a report is reserved or held, or
     *         {@link #RATE_LIMITED}
     */
    int reserve(@NonNull final Object engine, final long createTimeoutMs, @NonNull final Expiry expiry) {
        final int stamp;
        synchronized (this) {
            if (creating || report != null) {
                return 0;
            }
            final long now = clock.nowMs();
            while (!recent.isEmpty() && now - recent.peekFirst() >= RATE_WINDOW_MS) {
                recent.pollFirst();
            }
            if (recent.size() >= RATE_LIMIT) {
                return RATE_LIMITED;
            }
            recent.addLast(now);
            this.owner = engine;
            creating = true;
            stamp = nextStamp;
            nextStamp = nextStamp == Integer.MAX_VALUE ? 1 : nextStamp + 1;
            currentStamp = stamp;
            timer = scheduler.schedule(() -> {
                final boolean timedOut;
                synchronized (CreatedReports.this) {
                    timedOut = creating && currentStamp == stamp;
                    if (timedOut) {
                        creating = false;
                        currentStamp = 0;
                        timer = null;
                        owner = null;
                    }
                }
                if (timedOut) {
                    expiry.createTimedOut();
                }
            }, createTimeoutMs);
        }
        return stamp;
    }

    /**
     * Ends the reservation {@code stamp} names. A report gets {@code cr-<n>} and is held for
     * {@code ttlMs}; null frees the slot. A stamp that is not the current one (timed out, cleared, or
     * a second answer) changes nothing and returns null: the caller then discards {@code created}.
     */
    @Nullable
    String fulfil(
            final int stamp,
            @Nullable final Report created,
            final long ttlMs,
            @NonNull final Expiry expiry
    ) {
        synchronized (this) {
            if (!creating || stamp == 0 || stamp != currentStamp) {
                return null;
            }
            cancelTimer();
            creating = false;
            currentStamp = 0;
            if (created == null) {
                owner = null;
                return null;
            }
            final String minted = "cr-" + next++;
            handle = minted;
            report = created;
            timer = scheduler.schedule(() -> {
                final Report gone = take(minted);
                if (gone != null) {
                    expiry.expired(gone);
                }
            }, ttlMs);
            return minted;
        }
    }

    /** True when {@code stamp} still names the open reservation. */
    synchronized boolean isReserved(final int stamp) {
        return creating && stamp != 0 && stamp == currentStamp;
    }

    @Nullable
    synchronized Report get(@Nullable final String handleId) {
        return report != null && handleId != null && handleId.equals(handle) ? report : null;
    }

    /** Removes the report and frees the slot. An unknown handle removes nothing. */
    @Nullable
    synchronized Report take(@Nullable final String handleId) {
        final Report held = get(handleId);
        if (held == null) {
            return null;
        }
        cancelTimer();
        report = null;
        handle = null;
        owner = null;
        return held;
    }

    /**
     * Drops what {@code engine} reserved or holds (nothing, when the slot is another engine's): a second
     * engine's Dart isolate starting must not destroy the first one's report. Every stamp issued for the
     * dropped reservation fails {@link #fulfil}.
     *
     * @return the held report that was dropped, or null
     */
    @Nullable
    synchronized Report clearOwner(@NonNull final Object engine) {
        if (owner != engine) {
            return null;
        }
        cancelTimer();
        final Report held = report;
        creating = false;
        currentStamp = 0;
        report = null;
        handle = null;
        owner = null;
        return held;
    }

    private void cancelTimer() {
        final ReportHandlerPipeline.Cancellable t = timer;
        timer = null;
        if (t != null) {
            try {
                t.cancel();
            } catch (final Throwable ignored) {
                // A timer that cannot be cancelled fires into a stale stamp or handle and does nothing.
            }
        }
    }
}
