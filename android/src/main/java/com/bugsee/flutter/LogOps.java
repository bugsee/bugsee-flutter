package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.internal.LogSource;

import java.util.List;

/**
 * Log lines the Dart capture ({@code lib/src/logs}: {@code print}, {@code debugPrint}, {@code
 * Bugsee.forwardLog}) hands to the SDK (Phase 5d).
 *
 * <p>The SDK is behind {@link Sdk} so a unit test can see what reaches it. Every decision the SDK
 * would make for a wrapper-channel line is mirrored here, so the wrapper never hands over what the
 * SDK would drop (and says how many it did hand over):
 *
 * <ul>
 *   <li><b>gate</b>: {@code BugseeInternal.log} (v7.4.2) accepts while the SDK is started or
 *       starting ({@code Launching} or {@code Launched}), and the capture provider drops a
 *       wrapper-channel line when {@code capture.logs} is off
 *       ({@code BugseeCaptureDataProviderLog.mConsoleEventLogger}: "the wrapper channel carries
 *       output the wrapper captured on its own ... which is automatic capture");</li>
 *   <li><b>source</b>: always {@link LogSource#Custom} ("the host runtime's own logs; the default
 *       for forwarded host output"). {@code BugseeWrapperChannelImpl.toWrapperSource} accepts five
 *       values (Custom, WebView, StdOut, StdErr, Unknown) and records every other as Custom; this
 *       wrapper claims only Custom, so it never depends on the coercion and never triggers the SDK's
 *       once-per-process "reserved source" report. It is never {@link LogSource#Bugsee}, the app's
 *       own {@code Bugsee.log}, which would also skip the app's log filter;</li>
 *   <li><b>filtering</b>: the channel's lines are always run through the app's log filter, if it set
 *       one ({@code runFilter = logSource != Bugsee || requiresFiltering}); there is nothing to pass.
 *       The filter runs on the calling thread, which is the plugin's serial background thread (the
 *       Pigeon method has a task queue), and an exception it throws propagates to the caller: it is
 *       caught per line here, the line is dropped and the batch goes on;</li>
 *   <li><b>level</b>: the SDK's {@code LogLevel} value (1 error .. 5 verbose); {@code
 *       capture.logs.level} is applied by Dart (Android's provider only applies it to what it reads
 *       from logcat, not to channel lines);</li>
 *   <li><b>tag</b>: recorded ({@code log.json} {@code tag}, omitted when empty).</li>
 * </ul>
 *
 * <p>Neither the channel nor the SDK takes a timestamp: a line is stamped when it reaches the SDK
 * ({@code TimeUtils.monotonicWallTimeMillis}), so Dart hands lines over promptly and in order.
 * {@link NetworkChannelHolder} keeps the channel the SDK hands the current wrapper registration (the
 * one the network events use); a retired channel drops silently.
 */
final class LogOps {

    /** The source the wrapper claims; compared with the SDK's enum by the parity test. */
    static final LogSource WRAPPER_SOURCE = LogSource.Custom;

    /** The SDK's level range; compared with Dart's {@code LogWire} by the drift guard. */
    static final int MIN_LEVEL = 1;
    static final int MAX_LEVEL = 5;

    /** What a single line is refused for, to tell a bug from a drop in tests. */
    enum Outcome {
        HANDED,
        /** The SDK is not launching or launched, or {@code capture.logs} is off. */
        NOT_ACCEPTING,
        /** Malformed (an empty message, a level outside 1..5): a message not from this Dart. */
        INVALID,
        /** The wrapper holds no channel yet, or the app's filter threw. */
        NOT_SUBMITTED
    }

    /** The SDK entry points injection uses; the real ones are {@link BugseeLogSdk}. */
    interface Sdk {
        /** {@code Launching} or {@code Launched}, and {@code capture.logs} on. */
        boolean acceptsLogs();

        /**
         * {@code channel.log(tag, message, level, LogSource.Custom)}; false when the wrapper holds
         * no channel (it is delivered at {@code setWrapper}, so this only happens before
         * registration) or the level is not the SDK's.
         */
        boolean submit(@Nullable String tag, @NonNull String message, int level);
    }

    private LogOps() {
    }

    /**
     * Hands every line of the batch to the SDK, in order, and returns how many it took. Nothing
     * throws: an SDK or filter exception for one line is caught (the app's log filter runs on THIS
     * thread, and a throw there must not take the plugin down; the line is dropped, fail closed) and
     * the rest of the batch goes on.
     */
    static int addAll(@NonNull final Sdk sdk, @Nullable final List<Messages.LogLineMessage> lines) {
        if (lines == null || lines.isEmpty()) {
            return 0;
        }
        final boolean accepting;
        try {
            accepting = sdk.acceptsLogs();
        } catch (final RuntimeException e) {
            return 0;
        }
        if (!accepting) {
            return 0;
        }
        int handed = 0;
        for (final Messages.LogLineMessage line : lines) {
            if (add(sdk, line) == Outcome.HANDED) {
                handed++;
            }
        }
        return handed;
    }

    /** One line. The gate is the caller's ({@link #addAll}). */
    @NonNull
    static Outcome add(@NonNull final Sdk sdk, @Nullable final Messages.LogLineMessage line) {
        if (line == null) {
            return Outcome.INVALID;
        }
        final String message = line.getMessage();
        final long level = line.getLevel();
        if (message == null || message.isEmpty() || level < MIN_LEVEL || level > MAX_LEVEL) {
            return Outcome.INVALID;
        }
        final String tag = line.getTag();
        try {
            return sdk.submit(tag == null || tag.isEmpty() ? null : tag, message, (int) level)
                    ? Outcome.HANDED
                    : Outcome.NOT_SUBMITTED;
        } catch (final RuntimeException e) {
            // The app's native log filter (or the SDK) threw on this thread: the line is dropped.
            return Outcome.NOT_SUBMITTED;
        }
    }
}
