package com.bugsee.flutter;

import androidx.annotation.NonNull;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/**
 * Runs a report's file work (a copy, a move, an image decode, the deletion of attachments) off the
 * platform thread, in order.
 *
 * <p>The SDKs say these calls cost I/O proportional to the file and must not run on the UI thread
 * with large files (report-contract, Attachments, Timing); Pigeon calls host methods on the platform
 * thread, so the work is handed over here and the reply goes back to the platform thread. ONE thread,
 * so the order Dart called in is the order the SDK sees (an add, then the upload that must see it),
 * and a BOUNDED queue so a loop of adds cannot grow without limit: a full queue refuses the call
 * ({@code busy}) instead of holding it.
 */
final class ReportFileWorker {

    /** How many operations may wait for the thread. */
    static final int QUEUE_CAPACITY = 64;

    private static final ReportFileWorker SHARED = new ReportFileWorker(QUEUE_CAPACITY, "bugsee-flutter-report-files");
    private static final ReportFileWorker CREATED = new ReportFileWorker(QUEUE_CAPACITY, "bugsee-flutter-created-report");

    /** A handler report's file work. */

    @NonNull
    static ReportFileWorker shared() {
        return SHARED;
    }

    /**
     * A created report's operations, upload and discards: a second thread, so a slow copy for a handler
     * report never holds up the report the app is filling in (nor the other way round).
     */
    @NonNull
    static ReportFileWorker created() {
        return CREATED;
    }

    private final ThreadPoolExecutor executor;

    ReportFileWorker(final int capacity, @NonNull final String threadName) {
        executor = new ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<Runnable>(capacity), runnable -> {
                    final Thread thread = new Thread(runnable, threadName);
                    thread.setDaemon(true);
                    return thread;
                });
    }

    /**
     * Queues {@code task}.
     *
     * @return false, having queued nothing, when the queue is full: the caller answers {@code busy}
     *         and releases whatever it claimed for the task
     */
    boolean execute(@NonNull final Runnable task) {
        try {
            executor.execute(task);
            return true;
        } catch (final RejectedExecutionException full) {
            return false;
        }
    }
}
