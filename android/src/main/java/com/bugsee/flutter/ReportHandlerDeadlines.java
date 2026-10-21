package com.bugsee.flutter;

import androidx.annotation.Nullable;

/**
 * How long Dart gets to handle one report callback, and whether it gets one.
 *
 * <p>Read from {@code bugsee-android} 7.4.2 ({@code ReportHandler}, {@code ReportHandlerChain},
 * {@code BugseeIssueReportingCoordinator}); the numbers are extracted into
 * {@code test/fixtures/report_enums.json} and compared by {@code test/report_enum_parity_test.dart}.
 * Ours is the SDK's budget LESS A MARGIN, never more, and the margin is a third of it
 * (workbook 7.3.5):
 *
 * <ul>
 *   <li><b>Healthy path</b> ({@code isTerminating = false}): the handler is posted to the
 *       dedicated thread {@value #LIVE_HANDLER_THREAD} (never main) and the SDK waits for the
 *       completion, up to the {@code ReportHandlerCallbackTimeout} option per handler (default
 *       30 s, {@code 0} disables that timer), the whole chain (wrapper then application handler)
 *       capped at 60 s or one timeout, whichever is longer. <b>The SDK starts that timer when it
 *       QUEUES the handler</b> ({@code ReportHandlerChain.Step.arm()}); ours starts when the
 *       handler is entered. The wait in between (the dispatch thread is shared, so another
 *       report's slow handler can hold it) is NOT observable from here, so the margin is what
 *       absorbs it: a handler queued behind more than the margin can still overrun the SDK's
 *       deadline, and an edit in that window is accepted here although the SDK has moved on.
 *       What IS observable, the wait for the platform thread after entry, is deducted from the
 *       window before Dart is asked ({@link #remainingMs}). {@link #LIVE_DEADLINE_MS} = 20 s of
 *       the 30 s.</li>
 *   <li><b>Terminating</b> ({@code true}): the crashing thread waits at most 3 s for both
 *       handlers together, the completion is ignored and the process dies when this returns.
 *       We never reach Dart there.</li>
 *   <li><b>Early-crash recovery</b> ({@code false}): a spawned
 *       {@code bugsee-report-handler-bounded} thread (inline on the launching thread, which can
 *       be main, if no thread can be started); the launching thread waits at most 3 s for the
 *       handler to RETURN, and the completion is a no-op the SDK never awaits. Nothing
 *       asynchronous can be waited for, and Dart is rarely attached yet (this runs inside
 *       {@code Application.onCreate}), so we complete at once.</li>
 * </ul>
 *
 * <p>The SDK does not say which path a call is on, so the only signal is the thread's name. It is
 * used for the TIME BUDGET and nothing else: it is never passed to Dart and never read as "this is
 * a recovered crash" (workbook 7.2.3). A thread we do not recognise gets the safe answer, which is
 * no round trip.
 */
final class ReportHandlerDeadlines {

    /** The SDK's per-handler default, {@code ReportHandlerCallbackTimeout} (30 s). */
    static final long SDK_DEFAULT_HANDLER_TIMEOUT_MS = 30_000L;

    /** The SDK's budget less its margin ({@link #marginMs}): 20 s of the default 30 s. */
    static final long LIVE_DEADLINE_MS = 20_000L;

    /** The most the margin ever is, however large the SDK's budget. */
    static final long MAX_MARGIN_MS = 10_000L;

    /**
     * Below this a round trip to Dart and back cannot reliably fit, so the handler is
     * completed at once instead of racing a deadline it will lose.
     */
    static final long MIN_USEFUL_DEADLINE_MS = 1_000L;

    /**
     * {@code BugseeHandlers.REPORT_HANDLER_THREAD_NAME}: the one thread the healthy,
     * waited-for path runs on. A test runs a dispatch on a thread of this name, and
     * another compares it to the SDK's constant when the SDK exposes it.
     */
    static final String LIVE_HANDLER_THREAD = "BugseeReportHandlerThread";

    private ReportHandlerDeadlines() {
    }

    /** The margin kept under an SDK budget of {@code sdkMs}: a third of it, at most {@link #MAX_MARGIN_MS}. */
    static long marginMs(final long sdkMs) {
        return Math.min(MAX_MARGIN_MS, sdkMs / 3L);
    }

    /**
     * The live deadline for the {@code ReportHandlerCallbackTimeout} option, in seconds.
     *
     * <p>{@code null} (unreadable) and {@code 0} (the SDK's per-handler timer is disabled; its 60 s
     * chain cap still applies) both mean the default. The SDK normalises a negative value to
     * {@code 0}, and so does this. Otherwise the option less its margin, never more than
     * {@link #LIVE_DEADLINE_MS}.
     */
    static long liveMs(@Nullable final Integer optionSeconds) {
        if (optionSeconds == null || optionSeconds <= 0) {
            return LIVE_DEADLINE_MS;
        }
        final long sdkMs = optionSeconds * 1000L;
        return Math.min(LIVE_DEADLINE_MS, sdkMs - marginMs(sdkMs));
    }

    /**
     * What is left of a window of {@code budgetMs} once {@code elapsedMs} of it has passed; never
     * negative. Zero means "already over": complete the SDK's callback instead of asking Dart.
     */
    static long remainingMs(final long budgetMs, final long elapsedMs) {
        return Math.max(0L, budgetMs - Math.max(0L, elapsedMs));
    }

    /** Whether {@code threadName} is the SDK's live (waited-for) dispatch thread. */
    static boolean isLive(@Nullable final String threadName) {
        return LIVE_HANDLER_THREAD.equals(threadName);
    }

    /** What the deadline is for a dispatch on {@code threadName}; 0 means "do not ask Dart". */
    static long deadlineMs(
            @Nullable final String threadName,
            final boolean isTerminating,
            @Nullable final Integer optionSeconds
    ) {
        if (isTerminating || !isLive(threadName)) {
            return 0L;
        }
        final long ms = liveMs(optionSeconds);
        return ms < MIN_USEFUL_DEADLINE_MS ? 0L : ms;
    }
}
