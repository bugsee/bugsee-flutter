package com.bugsee.flutter;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * Carries the SDK's lifecycle events from the registered wrapper to the Dart
 * side (workbook Part 4).
 *
 * <p>Process-wide and independent of the wrapper object, which is registered at
 * process start and replaced when Dart refines the identity; and independent of
 * the Flutter engine, which appears later and can come and go. Neither end
 * holds the other.
 *
 * <p><b>Threading.</b> The SDK calls {@code onLifecycleEvent} from its own
 * worker thread (4.4), never the main thread. Flutter channels must be used on
 * the platform (main) thread, so every delivery to the sink is posted through
 * {@link MainThread}; the sink itself is therefore always invoked on it.
 *
 * <p><b>Buffering.</b> Until Dart attaches there is no sink, and the first
 * events of a launch ({@code Launching}, {@code Launched}) happen long before
 * a Dart isolate can listen. Events are kept, in order, in a buffer of at most
 * {@link #BUFFER_CAPACITY} entries and flushed on {@link #attach}. When full the
 * <b>oldest</b> event is dropped (the freshest state matters most) and counted
 * in {@link #droppedCount()}; a drop is logged. With the cap far above the number
 * of events one launch produces, a drop means Dart never attached.
 *
 * <p><b>Names.</b> The {@code com.bugsee.lifecycle.} prefix is stripped once,
 * here. A name the wrapper does not know, or one without the prefix, is
 * forwarded unchanged (4.3): a newer SDK adding an event must reach Dart
 * through an older wrapper. Nothing here decides what an event means.
 */
final class LifecycleHub {

    private static final String TAG = "BugseeFlutter";

    /** The prefix both SDKs put on every lifecycle event name. */
    static final String PREFIX = "com.bugsee.lifecycle.";

    /** At most this many events are kept while no Dart side is attached. */
    static final int BUFFER_CAPACITY = 64;

    /**
     * The events whose payload is the report's id (4.5). Repeated in Dart
     * ({@code reportIdEvents}) and Objective-C; test/lifecycle_drift_test.dart
     * compares the copies.
     */
    private static final Set<String> REPORT_ID_EVENTS = Collections.unmodifiableSet(
            new HashSet<>(Arrays.asList(
                    "BeforeReportAssembled",
                    "AfterReportAssembled",
                    "ReportAssemblyFailed",
                    "BeforeReportUploaded",
                    "AfterReportUploaded",
                    "ReportUploadFailed",
                    "ReportUploadFailedWithFutureRetry")));

    /** An event as handed to Dart. */
    static final class Event {
        @NonNull
        final String name;
        /** Set only for {@link #REPORT_ID_EVENTS} whose payload was a string. */
        @Nullable
        final String reportId;
        /** String-to-string payload entries; {@code null} when there are none. */
        @Nullable
        final Map<String, String> data;

        Event(@NonNull final String name, @Nullable final String reportId,
              @Nullable final Map<String, String> data) {
            this.name = name;
            this.reportId = reportId;
            this.data = data;
        }
    }

    /** Receives events; always invoked on the {@link MainThread}. */
    interface Sink {
        void onEvent(@NonNull Event event);
    }

    /** Runs work on the platform thread; a seam so a test controls it. */
    interface MainThread {
        void post(@NonNull Runnable work);
    }

    private static volatile LifecycleHub shared;

    /** The process-wide hub the wrapper and the plugin share. */
    @NonNull
    static LifecycleHub shared() {
        LifecycleHub hub = shared;
        if (hub == null) {
            synchronized (LifecycleHub.class) {
                hub = shared;
                if (hub == null) {
                    final android.os.Handler handler =
                            new android.os.Handler(android.os.Looper.getMainLooper());
                    hub = new LifecycleHub(handler::post);
                    shared = hub;
                }
            }
        }
        return hub;
    }

    private final Object lock = new Object();
    private final MainThread mainThread;
    private final ArrayDeque<Event> buffer = new ArrayDeque<>();
    @Nullable
    private Sink sink;
    private int dropped;

    LifecycleHub(@NonNull final MainThread mainThread) {
        this.mainThread = mainThread;
    }

    /**
     * Called by the wrapper from the SDK's thread. Never throws: a throw here
     * would be the wrapper's fault reaching into the SDK's dispatch.
     */
    void dispatch(@Nullable final String rawName, @Nullable final Object data) {
        if (rawName == null) {
            return;
        }
        try {
            final Event event = parse(rawName, data);
            synchronized (lock) {
                final Sink current = sink;
                if (current == null) {
                    buffer(event);
                } else {
                    post(current, event);
                }
            }
        } catch (final Throwable t) {
            Log.w(TAG, "could not forward lifecycle event: " + t.getClass().getName());
        }
    }

    /**
     * Makes {@code newSink} the receiver and flushes the buffer to it, in
     * order, ahead of any event dispatched afterwards.
     */
    void attach(@NonNull final Sink newSink) {
        synchronized (lock) {
            sink = newSink;
            Event pending;
            while ((pending = buffer.pollFirst()) != null) {
                post(newSink, pending);
            }
        }
    }

    /**
     * Detaches {@code stale} only while it is still the receiver: a second
     * engine may have attached already. Events buffer again until the next
     * {@link #attach}.
     */
    void detach(@NonNull final Sink stale) {
        synchronized (lock) {
            if (sink == stale) {
                sink = null;
            }
        }
    }

    /** How many events have been dropped because the buffer was full. */
    int droppedCount() {
        synchronized (lock) {
            return dropped;
        }
    }

    int bufferedCount() {
        synchronized (lock) {
            return buffer.size();
        }
    }

    /** Caller holds {@link #lock}. */
    private void post(@NonNull final Sink target, @NonNull final Event event) {
        mainThread.post(() -> deliver(target, event));
    }

    private void deliver(@NonNull final Sink target, @NonNull final Event event) {
        synchronized (lock) {
            if (sink != target) {
                // Detached between the post and now: keep it for the next
                // attach rather than send into a dead engine.
                buffer(event);
                return;
            }
        }
        try {
            target.onEvent(event);
        } catch (final Throwable t) {
            Log.w(TAG, "lifecycle sink threw for " + event.name + ": " + t.getClass().getName());
        }
    }

    /** Caller holds {@link #lock}. */
    private void buffer(@NonNull final Event event) {
        buffer.addLast(event);
        if (buffer.size() > BUFFER_CAPACITY) {
            buffer.removeFirst();
            dropped++;
            Log.w(TAG, "lifecycle buffer full (" + BUFFER_CAPACITY
                    + "), dropped the oldest event; total dropped " + dropped);
        }
    }

    @NonNull
    static Event parse(@NonNull final String rawName, @Nullable final Object data) {
        // Once. A name that merely starts with the prefix twice keeps the second.
        // The bare prefix has no name to strip down to, so it is forwarded as is.
        final String name = rawName.startsWith(PREFIX) && rawName.length() > PREFIX.length()
                ? rawName.substring(PREFIX.length())
                : rawName;
        String reportId = null;
        Map<String, String> payload = null;
        if (data instanceof String) {
            // Carried, not interpreted; and only by the events that carry one.
            if (REPORT_ID_EVENTS.contains(name)) {
                reportId = (String) data;
            }
        } else if (data instanceof Map) {
            final Map<String, String> cleaned = new HashMap<>();
            for (final Map.Entry<?, ?> e : ((Map<?, ?>) data).entrySet()) {
                if (e.getKey() instanceof String && e.getValue() instanceof String) {
                    cleaned.put((String) e.getKey(), (String) e.getValue());
                }
            }
            if (!cleaned.isEmpty()) {
                payload = cleaned;
            }
        }
        return new Event(name, reportId, payload);
    }
}
