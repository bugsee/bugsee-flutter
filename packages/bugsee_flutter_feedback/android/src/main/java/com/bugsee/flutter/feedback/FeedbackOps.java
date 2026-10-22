package com.bugsee.flutter.feedback;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.feedback.FeedbackListener;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.Executor;

/**
 * What the Dart facade asks of the feedback module, with the SDK behind {@link FeedbackSdk} so
 * the decisions are unit-tested. One instance per Flutter engine.
 *
 * <p>The SDK has ONE listener slot for the process. Every engine that listens gets its own
 * {@link Relay}; a single process-wide listener ({@link #FANOUT}) is installed in the slot while at
 * least one relay exists and hands every event to all of them, so a second engine listening, or
 * detaching, never silences the first.
 *
 * <p>The SDK calls the listener on a worker thread; events are handed to {@code mainThread} before
 * they reach Dart (the platform thread is the only one a Flutter messenger may be used from), and
 * dropped when the relay has been removed in the meantime.
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

    /** Every engine's relay, in the order they were enabled; guarded by {@link #SLOT_LOCK}. */
    private static final List<Relay> RELAYS = new CopyOnWriteArrayList<>();

    /** The one listener the SDK's slot holds while {@link #RELAYS} is not empty. */
    private static final FeedbackListener FANOUT = new FeedbackListener() {
        @Override
        public void onNewMessagesReceived(@Nullable final List<String> newMessages) {
            final List<String> copy = nonNull(newMessages);
            if (copy.isEmpty()) {
                return;
            }
            for (final Relay relay : RELAYS) {
                relay.received(copy);
            }
        }

        @Override
        public void onNewMessageSent(@Nullable final String message) {
            if (message == null) {
                return;
            }
            for (final Relay relay : RELAYS) {
                relay.sent(message);
            }
        }
    };

    /** One engine's way into the fan-out. */
    private static final class Relay {
        private final Executor mainThread;
        private final Sink sink;
        /** False after a removal, so a callback already queued drops. */
        private volatile boolean accepting = true;

        Relay(@NonNull final Executor mainThread, @NonNull final Sink sink) {
            this.mainThread = mainThread;
            this.sink = sink;
        }

        void received(@NonNull final List<String> messages) {
            if (!accepting) {
                return;
            }
            mainThread.execute(() -> {
                if (accepting) {
                    sink.messagesReceived(messages);
                }
            });
        }

        void sent(@NonNull final String message) {
            if (!accepting) {
                return;
            }
            mainThread.execute(() -> {
                if (accepting) {
                    sink.messageSent(message);
                }
            });
        }
    }

    private final FeedbackSdk sdk;
    private final Executor mainThread;
    private final Sink sink;

    /** The relay this instance enabled; guarded by {@link #SLOT_LOCK}. */
    @Nullable
    private Relay mine;

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
        synchronized (SLOT_LOCK) {
            // The previous relay of this engine goes first: a failed install must not leave it
            // listening.
            if (mine != null) {
                mine.accepting = false;
                RELAYS.remove(mine);
                mine = null;
            }
            final Relay relay = new Relay(mainThread, sink);
            if (RELAYS.isEmpty()) {
                // Installs the fan-out (again: harmless if the slot still holds it).
                call(() -> sdk.setListener(FANOUT));
            }
            RELAYS.add(relay);
            mine = relay;
        }
    }

    /** The engine is gone: stop emitting; the SDK slot is released when no engine listens. */
    void detach() {
        clearMine();
    }

    private void clearMine() {
        synchronized (SLOT_LOCK) {
            final Relay ours = mine;
            mine = null;
            if (ours == null) {
                return;
            }
            ours.accepting = false;
            RELAYS.remove(ours);
            if (RELAYS.isEmpty()) {
                try {
                    sdk.setListener(null);
                } catch (final RuntimeException ignored) {
                    // Nothing left to clear: the module is not there.
                }
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

    /** For tests: forget every relay (the process-wide state). */
    static void resetSlotForTesting() {
        synchronized (SLOT_LOCK) {
            for (final Relay relay : RELAYS) {
                relay.accepting = false;
            }
            RELAYS.clear();
        }
    }
}
