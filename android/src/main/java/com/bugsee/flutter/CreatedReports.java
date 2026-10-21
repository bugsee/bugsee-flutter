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

    private static final CreatedReports SHARED = new CreatedReports(new ReportHandlerPipeline.DaemonScheduler());

    @NonNull
    static CreatedReports shared() {
        return SHARED;
    }

    private final ReportHandlerPipeline.Scheduler scheduler;

    /** True from a successful reserve until that reservation is ended. */
    private boolean creating;
    private int currentStamp;
    private int nextStamp = 1;
    @Nullable private Report report;
    @Nullable private String handle;
    private int next = 1;
    @Nullable private ReportHandlerPipeline.Cancellable timer;

    CreatedReports(@NonNull final ReportHandlerPipeline.Scheduler scheduler) {
        this.scheduler = scheduler;
    }

    /**
     * @return the stamp {@link #fulfil} must present, or 0 when a report is reserved or held
     */
    int reserve(final long createTimeoutMs, @NonNull final Expiry expiry) {
        final int stamp;
        synchronized (this) {
            if (creating || report != null) {
                return 0;
            }
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
        return held;
    }

    /** Drops whatever is held or reserved; every stamp issued so far fails {@link #fulfil}. */
    @Nullable
    synchronized Report clear() {
        cancelTimer();
        final Report held = report;
        creating = false;
        currentStamp = 0;
        report = null;
        handle = null;
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
