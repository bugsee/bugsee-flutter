package com.bugsee.flutter.feedback;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.feedback.FeedbackListener;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executor;

/**
 * What the Dart facade asks of the feedback module, with the SDK behind {@link FeedbackSdk} so
 * the decisions are unit-tested. One instance per Flutter engine.
 *
 * <p>The SDK has ONE listener slot for the process. An instance installs its own listener and
 * clears the slot only while the slot still holds it, so a newer engine's listener (a second
 * engine, or a hot restart that attached before the old one detached) is never silenced by an
 * older one's detach. The most recently enabled engine wins.
 *
 * <p>The SDK calls the listener on a worker thread; events are handed to {@code mainThread} before
 * they reach Dart (the platform thread is the only one a Flutter messenger may be used from), and
 * dropped when the instance has been disabled in the meantime.
 */
final class FeedbackOps {

    /** Wire codes (a FlutterError's code), repeated in lib/src/errors.dart (FeedbackWire). */
    static final String NOT_REGISTERED = "not-registered";
    static final String SDK_ERROR = "sdk-error";

    /** Where events go once on the platform thread. */
    interface Sink {
        void messagesReceived(@NonNull List<String> messages);

        void messageSent(@NonNull String message);
    }

    private static final Object SLOT_LOCK = new Object();

    /** The listener the process's SDK slot holds, if one of ours. */
    @Nullable
    private static FeedbackListener installed;

    private final FeedbackSdk sdk;
    private final Executor mainThread;
    private final Sink sink;

    /** The listener this instance installed; guarded by {@link #SLOT_LOCK}. */
    @Nullable
    private FeedbackListener mine;

    /** False after a disable or detach, so a callback already queued drops. */
    private volatile boolean accepting;

    FeedbackOps(
            @NonNull final FeedbackSdk sdk,
            @NonNull final Executor mainThread,
            @NonNull final Sink sink) {
        this.sdk = sdk;
        this.mainThread = mainThread;
        this.sink = sink;
    }

    /** Forgets a listener a previous isolate of this engine installed; whether the module is there. */
    boolean attach() {
        clearMine();
        return sdk.isRegistered();
    }

    void show() {
        call(sdk::show);
    }

    void setGreeting(@Nullable final String greeting) {
        call(() -> sdk.setGreeting(greeting));
    }

    void setListenerEnabled(final boolean enabled) {
        if (!enabled) {
            clearMine();
            return;
        }
        final FeedbackListener listener = new FeedbackListener() {
            @Override
            public void onNewMessagesReceived(@Nullable final List<String> newMessages) {
                if (!accepting) {
                    return;
                }
                final List<String> copy = nonNull(newMessages);
                if (copy.isEmpty()) {
                    return;
                }
                mainThread.execute(() -> {
                    if (accepting) {
                        sink.messagesReceived(copy);
                    }
                });
            }

            @Override
            public void onNewMessageSent(@Nullable final String message) {
                if (!accepting || message == null) {
                    return;
                }
                mainThread.execute(() -> {
                    if (accepting) {
                        sink.messageSent(message);
                    }
                });
            }
        };
        synchronized (SLOT_LOCK) {
            // Dropped first: a failed install must not leave this instance accepting events.
            accepting = false;
            call(() -> sdk.setListener(listener));
            mine = listener;
            installed = listener;
            accepting = true;
        }
    }

    /** The engine is gone: stop emitting and release the SDK slot if it is still ours. */
    void detach() {
        clearMine();
    }

    private void clearMine() {
        synchronized (SLOT_LOCK) {
            accepting = false;
            final FeedbackListener ours = mine;
            mine = null;
            if (ours == null || installed != ours) {
                return;
            }
            installed = null;
            try {
                sdk.setListener(null);
            } catch (final RuntimeException ignored) {
                // Nothing left to clear: the module is not there.
            }
        }
    }

    /** Messages in the order the SDK handed them over, without nulls. */
    @NonNull
    static List<String> nonNull(@Nullable final List<String> messages) {
        final List<String> out = new ArrayList<>();
        if (messages != null) {
            for (final String m : messages) {
                if (m != null) {
                    out.add(m);
                }
            }
        }
        return out;
    }

    private static void call(@NonNull final Runnable body) {
        try {
            body.run();
        } catch (final FeedbackException e) {
            throw e;
        } catch (final Throwable t) {
            // The class only: the SDK's message can quote the user's chat text or greeting.
            throw new FeedbackException(SDK_ERROR, "the SDK threw " + t.getClass().getName());
        }
    }

    /** For tests: forget the process-wide slot. */
    static void resetSlotForTesting() {
        synchronized (SLOT_LOCK) {
            installed = null;
        }
    }
}
