package com.bugsee.flutter;

import androidx.annotation.NonNull;

import java.util.concurrent.atomic.AtomicLong;

/**
 * Lets the SDK's pull (its capture thread, 2-3 times a second) ask for a
 * placement refresh without ever blocking or flooding the main thread: at most
 * one request per {@link #MIN_INTERVAL_MS}, and a request only hands a task to
 * the executor (which posts to the main thread).
 *
 * <p>Needed because the Flutter view can move on the screen with no relayout
 * (freeform or desktop windowing, split-screen resize, picture-in-picture), and
 * nothing then tells Dart or the layout listener; without the pull-driven
 * refresh the old position would keep being served.
 */
final class PullThrottle {

    static final long MIN_INTERVAL_MS = 100;

    interface Clock {
        long nowMs();
    }

    private static final long NEVER = Long.MIN_VALUE;

    private final Clock clock;
    private final java.util.concurrent.Executor executor;
    private final Runnable task;
    private final AtomicLong last = new AtomicLong(NEVER);

    PullThrottle(
            @NonNull final Clock clock,
            @NonNull final java.util.concurrent.Executor executor,
            @NonNull final Runnable task
    ) {
        this.clock = clock;
        this.executor = executor;
        this.task = task;
    }

    /** Called on every pull. Never throws. */
    void request() {
        try {
            final long now = clock.nowMs();
            final long before = last.get();
            if (before != NEVER && now - before < MIN_INTERVAL_MS) {
                return;
            }
            // One winner per window when several displays are pulled together.
            if (!last.compareAndSet(before, now)) {
                return;
            }
            executor.execute(task);
        } catch (Throwable ignored) {
            // The pull is answered regardless.
        }
    }
}
