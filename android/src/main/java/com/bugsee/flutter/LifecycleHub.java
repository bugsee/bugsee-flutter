package com.bugsee.flutter;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayDeque;
import java.util.ArrayList;
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
 * <p><b>Receivers.</b> Any number may be attached (a UI engine and a background
 * engine); each gets every event, and detaching one leaves the others alone.
 *
 * <p><b>Buffering.</b> While NO receiver is attached, and the first events of a
 * launch ({@code Launching}, {@code Launched}) happen long before a Dart isolate
 * can listen, events are kept, in order, in a buffer of at most
 * {@link #BUFFER_CAPACITY} entries and flushed to the next receiver. When full the
 * <b>oldest</b> event is dropped (the freshest state matters most) and counted in
 * {@link #droppedCount()}; the first drop is logged, then every
 * {@link #DROP_LOG_EVERY}th. The latest status event is also remembered and
 * replayed to every new receiver, so a restarted engine knows the status.
 *
 * <p><b>Limit.</b> The guarantees end at the main-thread hop into the sink. An event
 * sent over the channel while the Dart side has no handler (a Dart hot restart, a
 * torn-down isolate) is held only by Flutter's channel buffer, which by default keeps
 * ONE message per channel; older ones are dropped and only logged. What does
 * recover: the latest status is replayed to every new receiver, report events still in
 * this hub's buffer are flushed to the next receiver, and events in flight to the LAST
 * receiver that detaches go back to the buffer (another receiver still attached has already
 * had them). What does not: an event already SENT over the
 * channel while Dart has no handler is not retried. Consumers must not rely on delivery
 * surviving a restart.
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

    /** Drops are always counted; a warning is logged for the first and then every Nth. */
    static final int DROP_LOG_EVERY = 100;

    /**
     * The only events that are status transitions (4.6). Repeated in Dart
     * ({@code statusTransitionEvents}) and Objective-C; the drift guard compares them.
     */
    private static final Set<String> STATUS_EVENTS = Collections.unmodifiableSet(
            new HashSet<>(Arrays.asList("Launching", "Launched", "Stopping", "Stopped")));

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

    /** One attached receiver and the events posted to it that have not run yet. */
    private static final class Entry {
        final Sink sink;
        final ArrayDeque<Event> inFlight = new ArrayDeque<>();

        Entry(final Sink sink) {
            this.sink = sink;
        }
    }

    private final Object lock = new Object();
    private final MainThread mainThread;
    private final ArrayDeque<Event> buffer = new ArrayDeque<>();
    private final ArrayList<Entry> entries = new ArrayList<>();
    /** The latest Launching/Launched/Stopping/Stopped event, replayed to every new receiver. */
    @Nullable
    private Event lastStatus;
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
                if (STATUS_EVENTS.contains(event.name)) {
                    lastStatus = event;
                }
                if (entries.isEmpty()) {
                    buffer(event);
                } else {
                    for (final Entry e : new ArrayList<>(entries)) {
                        post(e, event);
                    }
                }
            }
        } catch (final Throwable t) {
            Log.w(TAG, "could not forward lifecycle event: " + t.getClass().getName());
        }
    }

    /**
     * Adds {@code newSink} as a receiver (every attached receiver gets every
     * event: a background engine must not take events from the UI engine).
     * Attaching a sink that is already attached does nothing, so nothing is
     * delivered to it twice.
     *
     * <p>The new receiver first gets what it missed, in order: the events
     * buffered while nobody was attached, preceded by the latest status event
     * when the buffer does not already contain it (a receiver that attaches late,
     * or after a restart, still learns the status).
     */
    void attach(@NonNull final Sink newSink) {
        synchronized (lock) {
            for (final Entry e : entries) {
                if (e.sink == newSink) {
                    return;
                }
            }
            final Entry entry = new Entry(newSink);
            entries.add(entry);
            if (lastStatus != null && !buffer.contains(lastStatus)) {
                post(entry, lastStatus);
            }
            Event pending;
            while ((pending = buffer.pollFirst()) != null) {
                post(entry, pending);
            }
        }
    }

    /**
     * Removes only {@code stale}. Events posted to it that have not run yet are
     * not lost: when no receiver remains they go back to the FRONT of the
     * buffer, in their original order (they are older than anything buffered
     * since); other receivers already hold their own copies.
     */
    void detach(@NonNull final Sink stale) {
        synchronized (lock) {
            for (int i = 0; i < entries.size(); i++) {
                final Entry entry = entries.get(i);
                if (entry.sink != stale) {
                    continue;
                }
                entries.remove(i);
                if (entries.isEmpty()) {
                    final ArrayList<Event> back = new ArrayList<>(entry.inFlight);
                    for (int k = back.size() - 1; k >= 0; k--) {
                        buffer.addFirst(back.get(k));
                    }
                    while (buffer.size() > BUFFER_CAPACITY) {
                        buffer.removeFirst();
                        noteDrop();
                    }
                }
                entry.inFlight.clear();
                return;
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
    private void post(@NonNull final Entry entry, @NonNull final Event event) {
        entry.inFlight.addLast(event);
        mainThread.post(() -> deliver(entry));
    }

    /** Runs on the main thread, once per posted event, in posting order. */
    private void deliver(@NonNull final Entry entry) {
        final Event event;
        synchronized (lock) {
            // Empty once detached: detach() cleared it after putting the events back.
            event = entry.inFlight.pollFirst();
        }
        if (event == null) {
            return;
        }
        try {
            entry.sink.onEvent(event);
        } catch (final Throwable t) {
            Log.w(TAG, "lifecycle sink threw for " + event.name + ": " + t.getClass().getName());
        }
    }

    /** Caller holds {@link #lock}. */
    private void buffer(@NonNull final Event event) {
        buffer.addLast(event);
        if (buffer.size() > BUFFER_CAPACITY) {
            buffer.removeFirst();
            noteDrop();
        }
    }

    /** Caller holds {@link #lock}. Counts every drop; logs the first and then every Nth. */
    private void noteDrop() {
        dropped++;
        if (dropped == 1 || dropped % DROP_LOG_EVERY == 0) {
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
