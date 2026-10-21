package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.HashMap;
import java.util.Map;

/**
 * Dart errors (Phase 5a): what is decided here, with the SDK behind {@link Sdk} so a unit test can
 * see what reaches it. Dart builds the document (doc/exceptions.md); native wraps it in a
 * {@link FlutterManagedException} and calls the SDK's own exception API, handled or unhandled.
 *
 * <p><b>Before launch and after stop</b> the SDK drops the call itself (v7.4.2
 * {@code BugseeInternal.logException} / {@code logUnhandledException}: {@code isRunningOrStaring}
 * gate, a log line); this gates the same way first, so the answer ({@code false}) says it was not
 * handed over. Nothing is queued.
 */
final class ExceptionOps {

    /** The exception class name the backend routes on; compared with Dart's by the drift guard. */
    static final String EXCEPTION_NAME = "FlutterManagedException";

    /** The longest document accepted (UTF-16 units). Compared with Dart's by the drift guard. */
    static final int MAX_PAYLOAD_LENGTH = 262144;

    /** The longest domain accepted. Compared with Dart's by the drift guard. */
    static final int MAX_DOMAIN_LENGTH = 256;

    /** The SDK's {@code ExceptionOptions.Domain} key (the interface is public in the SDK). */
    static final String DOMAIN_KEY = "domain";

    /** The SDK entry points used; the real ones are {@link BugseeExceptionSdk}. */
    interface Sdk {
        /** Whether the SDK is Launching or Launched (Android's gate is Starting or Running). */
        boolean isLaunchedOrLaunching();

        /** {@code Bugsee.logException(Throwable, String domain, int skipFrames)}: an error report. */
        void logException(@NonNull Throwable throwable, @Nullable String domain, int skipFrames);

        /** {@code Bugsee.logUnhandledException(Throwable, Map)}: a crash report, the app lives on. */
        void logUnhandledException(@NonNull Throwable throwable, @Nullable Map<String, Object> options);
    }

    private ExceptionOps() {
    }

    /**
     * @return whether the SDK was handed the exception ({@code false}: it is not launching or launched)
     */
    static boolean log(
            @NonNull final Sdk sdk,
            @Nullable final String payload,
            final boolean handled,
            @Nullable final String domain
    ) throws FacadeOps.Failure {
        if (payload == null || payload.isEmpty()) {
            throw new FacadeOps.Failure(FacadeOps.INVALID_ARGUMENT, "an exception needs its document");
        }
        if (payload.length() > MAX_PAYLOAD_LENGTH) {
            // Never cut JSON in half: Dart keeps below this, so this is not a message of this version.
            throw new FacadeOps.Failure(FacadeOps.INVALID_ARGUMENT,
                    "the exception document is longer than " + MAX_PAYLOAD_LENGTH + " UTF-16 units");
        }
        if (domain != null && (domain.isEmpty() || domain.length() > MAX_DOMAIN_LENGTH)) {
            throw new FacadeOps.Failure(FacadeOps.INVALID_ARGUMENT,
                    "domain must be 1 to " + MAX_DOMAIN_LENGTH + " UTF-16 units");
        }
        try {
            if (!sdk.isLaunchedOrLaunching()) {
                return false;
            }
            final Throwable carrier = new FlutterManagedException(payload);
            if (handled) {
                // skipFrames 0: the Java stack is the carrier's, not the app's; Dart frames are in the document.
                sdk.logException(carrier, domain, 0);
            } else {
                Map<String, Object> options = null;
                if (domain != null) {
                    options = new HashMap<>(2);
                    options.put(DOMAIN_KEY, domain);
                }
                sdk.logUnhandledException(carrier, options);
            }
            return true;
        } catch (final RuntimeException e) {
            // The class only: the SDK's message may carry the document, which holds user data.
            throw new FacadeOps.Failure(FacadeOps.SDK_ERROR,
                    "logException: the SDK threw " + e.getClass().getName(), e);
        }
    }
}
