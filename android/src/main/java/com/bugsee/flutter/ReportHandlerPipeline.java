package com.bugsee.flutter;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.Bugsee;
import com.bugsee.library.contracts.options.Options;
import com.bugsee.library.contracts.reporting.Report;

import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Routes the SDK's report-handler callbacks to Dart and back (workbook Part 7),
 * through a table of opaque handles.
 *
 * <h3>The invariant</h3>
 * Every dispatch ends in exactly ONE run of the SDK's completion, whichever gets
 * there first: Dart completing the handle, the handle's deadline, the engine
 * detaching, a failure to reach Dart, or an error in here (7.1.2). The guard is one
 * lock-guarded flag per handle plus an {@link AtomicBoolean} around the SDK's completion itself, so
 * even a path this class did not think of cannot run it twice. Nothing in here throws
 * into the SDK.
 *
 * <h3>Why nothing here ever waits (the deadlock)</h3>
 * A report handler may be called on any thread, and Dart's reply is delivered by the
 * platform (main) thread. A native thread that BLOCKED for the reply would deadlock
 * whenever it is the platform thread itself (it can never deliver the reply it waits
 * for), and would stall the SDK's dispatch thread for nothing otherwise. So
 * {@link #dispatch} only registers the handle, arms the deadline, posts the request to
 * the platform thread and RETURNS; the SDK is already waiting for the completion on its
 * own timer, which is the non-blocking wait this needs. The completion runs later, on
 * whichever thread finishes the handle. {@code ReportHandlerPipelineTest} runs a
 * dispatch on the platform thread itself and fails if a dispatch ever waits.
 *
 * <h3>When Dart is not asked at all</h3>
 * {@code isTerminating} (7.1.1: the process dies when this returns and the Dart runtime
 * may already be gone, so there is nothing to wait for and nothing to do natively
 * either), no registered Dart handler for the phase (no waiting), a dispatch the SDK
 * does not wait on (see {@link ReportHandlerDeadlines}), or a deadline too short to fit
 * a round trip: the completion runs at once.
 *
 * <h3>The window, and what it cannot know</h3>
 * Dart's window is the SDK's budget less a margin ({@link ReportHandlerDeadlines}), measured from
 * the handler's ENTRY. The SDK starts its own timer when it QUEUES the handler, which cannot be
 * observed, so an edit made after the SDK has moved on (the handler queued behind another report's
 * slow handler for longer than the margin) can still be accepted: this class guarantees only that
 * an accepted edit was applied BEFORE this class ran the completion. The wait for the platform
 * thread after entry is observed and deducted: Dart is told what is left ({@code Request.deadlineMs}),
 * and a window that is already over is not offered to Dart at all.
 *
 * <h3>Check and apply are one step</h3>
 * An edit holds the handle's lock while it checks that the handle is live AND applies the change,
 * and the deadline (or Dart, or a detach) flips {@code done} under the same lock. So an edit that
 * was reported as applied really landed before the completion ran. The lock covers only the report's
 * own setters (short, they never call back into this class or Dart); the SDK's completion, Dart and
 * the scheduler are always called OUTSIDE it, and nothing else is locked while it is held.
 *
 * <h3>A late Dart edit</h3>
 * The proxy is live only until the completion runs (7.3.4). {@link #reportFor} answers
 * null from then on, so a late mutation is refused natively, and the Dart side raises an
 * error for it instead of letting it vanish.
 *
 * <p>Process-wide, like {@link LifecycleHub}: the wrapper object that calls in is
 * replaced when Dart refines the identity, and engines come and go.
 */
final class ReportHandlerPipeline {

    private static final String TAG = FlutterWrapperInitProvider.TAG;

    enum Phase {
        BEFORE(false),
        AFTER(true);

        final boolean after;

        Phase(final boolean after) {
            this.after = after;
        }

        String wire() {
            return after ? "after" : "before";
        }
    }

    /** What reaches Dart for one delivery. */
    static final class Request {
        @NonNull final String handle;
        @NonNull final String deliveryId;
        final boolean after;
        @NonNull final String reportId;
        @NonNull final String type;
        final long deadlineMs;

        Request(
                @NonNull final String handle,
                @NonNull final String deliveryId,
                final boolean after,
                @NonNull final String reportId,
                @NonNull final String type,
                final long deadlineMs
        ) {
            this.handle = handle;
            this.deliveryId = deliveryId;
            this.after = after;
            this.reportId = reportId;
            this.type = type;
            this.deadlineMs = deadlineMs;
        }
    }

    /** Sends a delivery to one engine's Dart isolate. Runs on the platform thread. */
    interface Sink {
        /**
         * @param unreachable run it when Dart cannot be reached (an error reply, such as
         *                    no handler on the Dart side after a hot restart)
         */
        void deliver(@NonNull Request request, @NonNull Runnable unreachable);
    }

    /** The platform (main) thread. A seam: JUnit has no Looper. */
    interface PlatformThread {
        /** @return false if the task could not be queued */
        boolean post(@NonNull Runnable task);
    }

    interface Cancellable {
        void cancel();
    }

    /** Arms a handle's deadline. Injectable so a test controls time. */
    interface Scheduler {
        Cancellable schedule(@NonNull Runnable task, long delayMs);
    }

    /** Its own interface: {@code java.util.function} needs API 24, minSdk is 21. */
    interface OptionSeconds {
        @Nullable
        Integer read();
    }

    /** Milliseconds on a monotonic clock; injectable so a test controls time. */
    interface Clock {
        long nowMs();
    }

    interface ThreadName {
        @Nullable
        String current();
    }

    /** One-line outcome of every dispatch; logcat in production, injectable for tests. */
    interface OutcomeLog {
        void line(@NonNull String message);
    }

    private static final class Registration {
        final Object owner;
        final Sink sink;
        volatile boolean before;
        volatile boolean after;

        Registration(final Object owner, final Sink sink) {
            this.owner = owner;
            this.sink = sink;
        }
    }

    private static final class Handle {
        final String id;
        final Report report;
        final Runnable sdkCompletion;
        final Object owner;
        /** {@link Clock#nowMs} when the SDK called us; the window is measured from here. */
        final long enteredAtMs;
        final long deadlineMs;
        /**
         * The exactly-once guard of this handle. Flipped only while holding the handle's monitor
         * (the same one an edit holds across check-and-apply); whoever flips it runs the completion,
         * after releasing it.
         */
        volatile boolean done;
        volatile Cancellable timer;
        /**
         * Long operations (a file copy, an image decode) that started while the handle was live and
         * have not finished; guarded by the handle's monitor. The SDK's completion is held back until
         * they have, never the other way round: nothing here blocks a thread for them.
         */
        int leases;
        /** Set (under the monitor) when {@link #done} was flipped while {@link #leases} was not zero. */
        boolean completionDeferred;

        Handle(
                final String id,
                final Report report,
                final Runnable sdkCompletion,
                final Object owner,
                final long enteredAtMs,
                final long deadlineMs
        ) {
            this.id = id;
            this.report = report;
            this.sdkCompletion = sdkCompletion;
            this.owner = owner;
            this.enteredAtMs = enteredAtMs;
            this.deadlineMs = deadlineMs;
        }
    }

    private static final class Holder {
        static final ReportHandlerPipeline INSTANCE = new ReportHandlerPipeline(
                new DaemonScheduler(),
                new MainThread(),
                ReportHandlerPipeline::optionFromLaunchOptions,
                () -> Thread.currentThread().getName(),
                message -> Log.i(TAG, message),
                () -> System.nanoTime() / 1_000_000L);
    }

    @NonNull
    static ReportHandlerPipeline shared() {
        return Holder.INSTANCE;
    }

    private final Scheduler scheduler;
    private final PlatformThread platform;
    private final OptionSeconds option;
    private final ThreadName threadName;
    private final OutcomeLog outcomes;
    private final Clock clock;
    /** Most recently attached first. */
    private final List<Registration> registrations = new CopyOnWriteArrayList<>();
    private final Map<String, Handle> handles = new ConcurrentHashMap<>();
    private final AtomicLong counter = new AtomicLong();

    ReportHandlerPipeline(
            @NonNull final Scheduler scheduler,
            @NonNull final PlatformThread platform,
            @NonNull final OptionSeconds option,
            @NonNull final ThreadName threadName,
            @NonNull final OutcomeLog outcomes
    ) {
        this(scheduler, platform, option, threadName, outcomes, () -> System.nanoTime() / 1_000_000L);
    }

    ReportHandlerPipeline(
            @NonNull final Scheduler scheduler,
            @NonNull final PlatformThread platform,
            @NonNull final OptionSeconds option,
            @NonNull final ThreadName threadName,
            @NonNull final OutcomeLog outcomes,
            @NonNull final Clock clock
    ) {
        this.clock = clock;
        this.scheduler = scheduler;
        this.platform = platform;
        this.option = option;
        this.threadName = threadName;
        this.outcomes = outcomes;
    }

    /** Attaches one engine's Dart end. It registers no phase until it says so. */
    void attach(@NonNull final Object owner, @NonNull final Sink sink) {
        detach(owner);
        registrations.add(0, new Registration(owner, sink));
    }

    /** What the Dart isolate of {@code owner} has a handler for. */
    void setPhases(@NonNull final Object owner, final boolean before, final boolean after) {
        for (final Registration r : registrations) {
            if (r.owner == owner) {
                r.before = before;
                r.after = after;
            }
        }
    }

    /**
     * A new Dart isolate is up on this engine (a hot restart): nothing in it knows the deliveries
     * handed to the previous one, so complete them now instead of leaving each report to wait for
     * its deadline, and forget which phases had a handler.
     */
    void reset(@NonNull final Object owner) {
        setPhases(owner, false, false);
        for (final Handle handle : handles.values()) {
            if (handle.owner == owner) {
                finish(handle, "reset");
            }
        }
    }

    /**
     * The engine is gone. Completes every handle emitted to it, because nothing in any
     * other isolate knows them and waiting for their deadlines would only delay the reports.
     */
    void detach(@NonNull final Object owner) {
        for (final Registration r : registrations) {
            if (r.owner == owner) {
                registrations.remove(r);
            }
        }
        for (final Handle handle : handles.values()) {
            if (handle.owner == owner) {
                finish(handle, "detach");
            }
        }
    }

    /**
     * The SDK's entry point. Returns promptly on every path, never blocks, never throws,
     * and arranges for {@code sdkCompletion} to run exactly once.
     */
    void dispatch(
            @NonNull final Phase phase,
            @Nullable final Report report,
            final boolean isTerminating,
            @Nullable final Runnable sdkCompletion
    ) {
        final Runnable once = once(sdkCompletion);
        try {
            dispatchOnce(phase, report, isTerminating, once);
        } catch (final Throwable t) {
            // Whatever went wrong, the SDK must not wait for us.
            Log.w(TAG, "report handler dispatch failed: " + t.getClass().getName());
            once.run();
        }
    }

    private void dispatchOnce(
            @NonNull final Phase phase,
            @Nullable final Report report,
            final boolean isTerminating,
            @NonNull final Runnable completion
    ) {
        if (report == null) {
            completeUnminted(phase, null, completion, "no-report");
            return;
        }
        // The process dies when this returns; nothing asynchronous survives it and the
        // Dart runtime may already be gone.
        if (isTerminating) {
            // Not even read: the cheapest thing on a dying process is to touch nothing.
            completeUnminted(phase, null, completion, "terminating");
            return;
        }
        final long deadlineMs = ReportHandlerDeadlines.deadlineMs(
                threadName.current(), false, readOption());
        if (deadlineMs <= 0L) {
            // A path the SDK does not wait on (recovery), or no time for a round trip.
            completeUnminted(phase, report, completion, "not-awaited");
            return;
        }
        final Registration target = registrationFor(phase);
        if (target == null) {
            completeUnminted(phase, report, completion, "no-handler");
            return;
        }

        final String reportId = safeId(report);
        final String handleId = "rh-" + counter.incrementAndGet();
        final Request request = new Request(
                handleId,
                // Stable for one report and phase, so Dart recognises a re-delivery; unique
                // (never shared) when the id is unreadable, so distinct reports never collide.
                reportId.isEmpty() ? phase.wire() + ":?" + handleId : phase.wire() + ":" + reportId,
                phase.after,
                reportId,
                ReportOps.typeOf(report),
                deadlineMs);
        final Handle handle = new Handle(
                handleId, report, completion, target.owner, clock.nowMs(), deadlineMs);
        handles.put(handleId, handle);
        // A detach that ran after the lookup above swept the table before this handle was in
        // it: detach removes the registration first and sweeps second, so whichever side comes
        // second catches the handle.
        if (!registrations.contains(target)) {
            finish(handle, "detach");
            return;
        }
        try {
            final Cancellable timer = scheduler.schedule(() -> finish(handle, "deadline"), deadlineMs);
            handle.timer = timer;
            if (handle.done) {
                cancelQuietly(timer);
                return;
            }
            outcomes.line("report handler " + handleId + " phase=" + phase.wire()
                    + " deadline=" + deadlineMs);
            // To the platform thread, never inline and never waited for. Dart's reply needs
            // that thread; see the class comment.
            if (!platform.post(() -> deliver(handle, target, request))) {
                finish(handle, "no-handler");
            }
        } catch (final Throwable t) {
            // The handle is in the table: finishing it runs the completion and makes the
            // report refuse edits, instead of leaving a live proxy nobody will complete.
            Log.w(TAG, "report handler " + handleId + " could not be set up: "
                    + t.getClass().getName());
            finish(handle, "error");
        }
    }

    private void deliver(
            @NonNull final Handle handle,
            @NonNull final Registration target,
            @NonNull final Request request
    ) {
        if (handle.done) {
            return;
        }
        // What is observable of the SDK's own wait: how long this request sat before the platform
        // thread took it. Deduct it; a window that is already over is not offered to Dart.
        final long gapMs = Math.max(0L, clock.nowMs() - handle.enteredAtMs);
        final long remainingMs = ReportHandlerDeadlines.remainingMs(handle.deadlineMs, gapMs);
        outcomes.line("report handler " + handle.id + " delivery gap=" + gapMs
                + " ms remaining=" + remainingMs + " ms");
        if (remainingMs <= 0L) {
            finish(handle, "expired");
            return;
        }
        final Request live = new Request(
                request.handle, request.deliveryId, request.after, request.reportId,
                request.type, remainingMs);
        try {
            target.sink.deliver(live, () -> finish(handle, "unreachable"));
        } catch (final Throwable t) {
            // A dead bridge throws from the send. Dart will never answer, so answer for it.
            Log.w(TAG, "report handler " + handle.id + " could not reach Dart: "
                    + t.getClass().getName());
            finish(handle, "unreachable");
        }
    }

    /** @return true only for the call that ran the SDK completion. */
    boolean complete(@NonNull final String handleId) {
        final Handle handle = handles.get(handleId);
        return handle != null && finish(handle, "dart");
    }

    /** The live report behind {@code handleId}, or null once it is completed or unknown. */
    @Nullable
    Report reportFor(@Nullable final String handleId) {
        if (handleId == null) {
            return null;
        }
        final Handle handle = handles.get(handleId);
        return handle == null || handle.done ? null : handle.report;
    }

    /** One change to a live report; may refuse its argument before touching anything. */
    interface Edit {
        void apply(@NonNull Report report) throws ReportOps.BadArgument;
    }

    /**
     * Applies {@code edit} to the live report behind {@code handleId}.
     *
     * @return false, having touched nothing, when the handle is not live (7.3.4): Dart turns
     *         that into an error, and the report is not changed
     * @throws ReportOps.BadArgument when the SDK cannot take the argument; nothing changed
     */
    boolean edit(@Nullable final String handleId, @NonNull final Edit edit)
            throws ReportOps.BadArgument {
        final Handle handle = handleId == null ? null : handles.get(handleId);
        if (handle == null) {
            return false;
        }
        // Check and apply under the handle's lock: finish() flips `done` under the same one, so a
        // deadline cannot fall between the check and the apply and leave an edit "applied" after
        // the SDK's completion ran.
        synchronized (handle) {
            if (handle.done) {
                return false;
            }
            edit.apply(handle.report);
            return true;
        }
    }

    /**
     * A claim on a live report for an operation that must not run under the handle's monitor (a file
     * copy can take as long as the disk does): while it is held the report stays valid for the
     * operation even if the handle completes, and the SDK's completion waits for {@link #release}.
     */
    final class Lease {
        private final Handle handle;
        private boolean released;

        private Lease(@NonNull final Handle handle) {
            this.handle = handle;
        }

        @NonNull
        Report report() {
            return handle.report;
        }

        /**
         * Whether the handler's window (the SDK's budget less our margin, measured from the handler's
         * entry) has passed. The SDK's own timer moves on regardless of this claim, and Android 7.4.2
         * does not re-check that it is still taking attachments after the file is imported
         * ({@code IssueReport.addAttachment}), so an add that returns once this is true may have been
         * registered on a report whose processing was already scheduled: the caller must undo it.
         * Work that has not started must not start.
         */
        boolean windowClosed() {
            return clock.nowMs() - handle.enteredAtMs >= handle.deadlineMs;
        }

        /** Idempotent. Runs the SDK's completion if the handle completed meanwhile and this was the last. */
        void release() {
            final boolean runCompletion;
            synchronized (handle) {
                if (released) {
                    return;
                }
                released = true;
                handle.leases--;
                runCompletion = handle.leases == 0 && handle.completionDeferred;
                if (runCompletion) {
                    handle.completionDeferred = false;
                }
            }
            if (runCompletion) {
                outcomes.line("report handler " + handle.id + " completion released by its last file operation");
                runQuietly(handle.sdkCompletion);
            }
        }
    }

    /**
     * Claims the live report behind {@code handleId} for a long operation, or null (nothing claimed)
     * when it is not live (7.3.4).
     */
    @Nullable
    Lease acquire(@Nullable final String handleId) {
        final Handle handle = handleId == null ? null : handles.get(handleId);
        if (handle == null) {
            return null;
        }
        synchronized (handle) {
            if (handle.done) {
                return null;
            }
            handle.leases++;
        }
        return new Lease(handle);
    }

    private boolean finish(@NonNull final Handle handle, @NonNull final String by) {
        final boolean runNow;
        synchronized (handle) {
            if (handle.done) {
                return false;
            }
            handle.done = true;
            // A long operation that started while the handle was live still owns the report: the
            // SDK's completion runs when the last of them ends (release()), so an operation reported
            // as applied landed BEFORE the completion, exactly like a short edit.
            runNow = handle.leases == 0;
            handle.completionDeferred = !runNow;
        }
        // Outside the lock from here: the SDK's completion, the timer and the log never run
        // while an edit could be waiting on it.
        handles.remove(handle.id, handle);
        final Cancellable timer = handle.timer;
        if (timer != null) {
            cancelQuietly(timer);
        }
        outcomes.line("report handler " + handle.id + " completed by=" + by
                + (runNow ? "" : " (deferred until its file operation ends)"));
        if (runNow) {
            runQuietly(handle.sdkCompletion);
        }
        return true;
    }

    /** No handle was minted; the line still carries the report for correlation. */
    private void completeUnminted(
            @NonNull final Phase phase,
            @Nullable final Report report,
            @NonNull final Runnable completion,
            @NonNull final String by
    ) {
        outcomes.line("report handler - completed by=" + by + " phase=" + phase.wire()
                + " report=" + (report == null ? null : safeId(report)));
        runQuietly(completion);
    }

    @Nullable
    private Registration registrationFor(@NonNull final Phase phase) {
        for (final Registration r : registrations) {
            if (phase.after ? r.after : r.before) {
                return r;
            }
        }
        return null;
    }

    @Nullable
    private Integer readOption() {
        try {
            return option.read();
        } catch (final Throwable t) {
            return null;
        }
    }

    /** At most once, and a null completion (never expected) is a no-op. */
    @NonNull
    private static Runnable once(@Nullable final Runnable completion) {
        final AtomicBoolean ran = new AtomicBoolean();
        return () -> {
            if (completion != null && ran.compareAndSet(false, true)) {
                completion.run();
            }
        };
    }

    /** The SDK's own fault must not escape into Dart's thread or the timer's. */
    private static void runQuietly(@NonNull final Runnable completion) {
        try {
            completion.run();
        } catch (final Throwable t) {
            Log.w(TAG, "report handler completion threw: " + t.getClass().getName());
        }
    }

    private static void cancelQuietly(@NonNull final Cancellable timer) {
        try {
            timer.cancel();
        } catch (final Throwable t) {
            Log.w(TAG, "report handler timer cancel threw: " + t.getClass().getName());
        }
    }

    /** Empty when unreadable: the empty string is also what marks a delivery un-dedupable. */
    @NonNull
    private static String safeId(@NonNull final Report report) {
        try {
            final String id = report.getId();
            return id == null ? "" : id;
        } catch (final Throwable t) {
            return "";
        }
    }

    /**
     * The {@code ReportHandlerCallbackTimeout} option in effect, read at each dispatch
     * because a relaunch can change it. Any failure reads as "unknown", which is the
     * default deadline.
     */
    @Nullable
    private static Integer optionFromLaunchOptions() {
        try {
            final Object value = Bugsee.getLaunchOptions().getOption(Options.ReportHandlerCallbackTimeout);
            if (value instanceof Number) {
                return ((Number) value).intValue();
            }
        } catch (final Throwable t) {
            Log.w(TAG, "could not read the report handler timeout option: " + t.getClass().getName());
        }
        return null;
    }

    /** One daemon thread, started on first use, for every handle's deadline. */
    static final class DaemonScheduler implements Scheduler {
        private final ScheduledThreadPoolExecutor executor;

        DaemonScheduler() {
            executor = new ScheduledThreadPoolExecutor(1, runnable -> {
                final Thread thread = new Thread(runnable, "BugseeFlutter-ReportDeadline");
                thread.setDaemon(true);
                return thread;
            });
            // A handle completed by Dart should not leave 25 s of dead task queued.
            executor.setRemoveOnCancelPolicy(true);
        }

        @Override
        public Cancellable schedule(@NonNull final Runnable task, final long delayMs) {
            final ScheduledFuture<?> future = executor.schedule(task, delayMs, TimeUnit.MILLISECONDS);
            return () -> future.cancel(false);
        }
    }

    /** The Android main looper. Created on first use, so JUnit never touches it. */
    private static final class MainThread implements PlatformThread {
        private volatile android.os.Handler handler;

        @Override
        public boolean post(@NonNull final Runnable task) {
            android.os.Handler h = handler;
            if (h == null) {
                h = new android.os.Handler(android.os.Looper.getMainLooper());
                handler = h;
            }
            return h.post(task);
        }
    }
}
