package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.Serializable;
import java.util.Locale;
import java.util.Map;

/**
 * Launch, stop and status (workbook Part 8, 4.6): what is decided here, with the SDK behind a
 * seam so a unit test can see what reaches it.
 *
 * <p><b>Auto-init.</b> The SDK launches itself from {@code BugseeInitProvider}, before
 * {@code Application.onCreate}, when the manifest has {@code com.bugsee.app-token} meta-data (and
 * {@code com.bugsee.auto-init} is not {@code false}). A {@code Bugsee.launch} after that
 * early-returns "success" and drops its options, with only a log line; the callback cannot tell it
 * from a real launch. So the status is read FIRST: Launching or Launched is answered
 * {@link #ALREADY_RUNNING} without calling the SDK, and Dart says the options were not applied.
 * Stopping is refused here as the SDK would (a launch during a stop is refused by it, and its
 * completion would otherwise overwrite the new state). Otherwise the SDK is launched and answered
 * from its own callback, which it runs after capture started.
 */
final class LaunchOps {

    /** The strings of {@code LaunchOutcomeMessage}; test/launch_drift_test.dart compares them with Dart. */
    static final String LAUNCHED = "launched";
    static final String ALREADY_RUNNING = "already-running";
    static final String DEFERRED = "deferred";
    static final String REFUSED = "refused";
    static final String INVALID_TOKEN = "invalid-token";
    static final String STOPPING = "stopping";
    static final String FAILED = "failed";
    static final String ERROR_CODE = "launch-failed";

    /** The SDK entry points this uses; the real ones are {@link #SDK}. */
    interface Sdk {
        /** The status by NAME, lower case: {@code stopped}, {@code launching}, {@code launched}, {@code stopping}. */
        @NonNull
        String status();

        /** Launches; {@code done} gets whether the SDK reports it is running (it may be called on any thread). */
        void launch(@NonNull String token, @NonNull Map<String, Serializable> options, @NonNull Done done);

        /** Stops; {@code done} runs when stopped (at once if it already is; any thread). */
        void stop(@NonNull Runnable done);

        @NonNull
        Map<String, ? extends Serializable> launchOptions(boolean hostOnly);
    }

    interface Done {
        void run(boolean running);
    }

    /** Where an exception from the SDK goes. Its own interface: {@code java.util.function} needs API 24, minSdk is 21. */
    interface ErrorSink {
        void error(@NonNull Throwable error);
    }

    /** The answer to a launch request. */
    interface Reply {
        void outcome(@NonNull String outcome, @Nullable String reason);
    }

    private LaunchOps() {
    }

    /**
     * Never throws: an exception from the SDK is reported through {@code error} (Dart sees a
     * PlatformException {@link #ERROR_CODE}), and {@code reply} is called exactly once otherwise.
     */
    static void launch(
            @NonNull final Sdk sdk,
            @Nullable final String token,
            @Nullable final Map<?, ?> flatOptions,
            @NonNull final Reply reply,
            @NonNull final ErrorSink error
    ) {
        try {
            if (token == null || token.trim().isEmpty()) {
                reply.outcome(REFUSED, INVALID_TOKEN);
                return;
            }
            final String status = sdk.status();
            if ("launching".equals(status) || "launched".equals(status)) {
                reply.outcome(ALREADY_RUNNING, null);
                return;
            }
            if ("stopping".equals(status)) {
                reply.outcome(REFUSED, STOPPING);
                return;
            }
            final Map<String, Serializable> options = LaunchOptionValues.toSdk(flatOptions);
            sdk.launch(token, options, running -> {
                if (running) {
                    reply.outcome(LAUNCHED, null);
                } else {
                    reply.outcome(REFUSED, FAILED);
                }
            });
        } catch (final Throwable t) {
            error.error(t);
        }
    }

    static void stop(
            @NonNull final Sdk sdk,
            @NonNull final Runnable done,
            @NonNull final ErrorSink error
    ) {
        try {
            sdk.stop(done);
        } catch (final Throwable t) {
            error.error(t);
        }
    }

    @NonNull
    static String status(@NonNull final Sdk sdk) {
        return sdk.status();
    }

    @NonNull
    static Map<String, Object> launchOptions(@NonNull final Sdk sdk, final boolean hostOnly) {
        return LaunchOptionValues.fromSdk(sdk.launchOptions(hostOnly));
    }

    /** The status as the bridge carries it: the SDK's constant NAME, lower case (never the ordinal). */
    @NonNull
    static String statusName(@NonNull final Enum<?> status) {
        return status.name().toLowerCase(Locale.ROOT);
    }
}
