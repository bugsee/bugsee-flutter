package com.bugsee.flutter;

import androidx.annotation.NonNull;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Runs the SDK call for a Dart error off the platform (main) thread.
 *
 * <p>An unhandled error is written by the SDK synchronously on the calling thread
 * ({@code BugseeIssueReportingCoordinator.createCrashReportAndUpload}: the payload and the report's
 * snapshot of the capture ring, "up to a couple of seconds" by the SDK's own comment, must be on disk
 * before it returns), and Pigeon calls host methods on the platform thread: a handful a minute would
 * be jank, one slow snapshot an ANR. One background thread, in order, with a BOUNDED queue: when it
 * is full the error is dropped and counted (the Dart side already limits what the installed handlers
 * send, so this is the backstop for explicit calls in a loop), and the caller is answered
 * {@code false}, "not handed to the SDK".
 */
final class ExceptionDispatcher {

    /** How many calls may wait for the thread; one more is dropped. */
    static final int QUEUE_CAPACITY = 32;

    /** The work: answers whether the SDK was handed the error. */
    interface Task {
        boolean run() throws FacadeOps.Failure;
    }

    /** The outcome, delivered on the dispatcher's thread (or inline when the queue was full). */
    interface Done {
        void success(boolean handedToSdk);

        void failure(@NonNull String code, @NonNull String message);
    }

    private static final ExceptionDispatcher SHARED = new ExceptionDispatcher(QUEUE_CAPACITY);

    @NonNull
    static ExceptionDispatcher shared() {
        return SHARED;
    }

    private final ThreadPoolExecutor executor;
    private final AtomicInteger dropped = new AtomicInteger();

    ExceptionDispatcher(final int capacity) {
        executor = new ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<Runnable>(capacity), runnable -> {
                    final Thread thread = new Thread(runnable, "bugsee-flutter-exceptions");
                    thread.setDaemon(true);
                    return thread;
                });
    }

    /** How many calls were dropped for a full queue so far. */
    int dropped() {
        return dropped.get();
    }

    void submit(@NonNull final Task task, @NonNull final Done done) {
        try {
            executor.execute(() -> {
                try {
                    done.success(task.run());
                } catch (final FacadeOps.Failure failure) {
                    done.failure(failure.code, failure.getMessage());
                } catch (final Throwable t) {
                    // The class only: nothing that carries user data, and the thread must live on.
                    done.failure(FacadeOps.SDK_ERROR, "logException: " + t.getClass().getName());
                }
            });
        } catch (final RejectedExecutionException full) {
            dropped.incrementAndGet();
            done.success(false);
        }
    }
}
