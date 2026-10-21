package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.Bugsee;
import com.bugsee.library.contracts.common.Callback1;
import com.bugsee.library.contracts.reporting.Report;
import com.bugsee.library.contracts.reporting.ReportCreationListener;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The file operations on a report and the {@code createReport} flow (Phase 6), with every collaborator
 * injected so the rules are unit-tested without Flutter or an Android runtime.
 *
 * <h3>Threads</h3>
 * Pigeon calls a host method on the platform thread. A file operation (a copy, a move, an image
 * decode, deleting attachments) costs I/O proportional to the file, which the SDKs say not to do on
 * the UI thread, so it is queued on the {@link Worker} (one thread, in call order) and the reply is
 * posted back through {@link Main}. Nothing here ever waits for another thread.
 *
 * <h3>A handler's report</h3>
 * The report is CLAIMED on the platform thread ({@link ReportHandlerPipeline#acquire}): a handle that is
 * live when the call is made stays valid for the operation, and the SDK's completion for the handler
 * waits for the claim to end instead of racing it. A handle that is not live answers {@code not-live}
 * and the call changes nothing.
 *
 * <h3>A created report</h3>
 * One at a time ({@link CreatedReports}), with a deadline at each stage. Operations on it, its upload
 * and its discard all go through the same one-thread worker, so the order Dart called in is the order
 * the SDK sees.
 */
final class ReportFileFlow {

    /** What a flow operation answers; the plugin adapts it to a Pigeon result. */
    interface Reply<T> {
        void success(@Nullable T value);

        void error(@NonNull String code, @NonNull String message);
    }

    /** Posts to the platform (main) thread. */
    interface Main {
        void post(@NonNull Runnable task);
    }

    /** Runs file work off the platform thread, in order; false when it has no room. */
    interface Worker {
        boolean execute(@NonNull Runnable task);
    }

    /** The SDK's entry points for a created report. */
    interface Sdk {
        void createReport(@NonNull ReportCreationListener listener);

        void upload(@NonNull Report report, @NonNull Callback1<Boolean> done);
    }

    /** One file operation on a report; refuses with a reply code, or rejects its argument. */
    interface FileOp {
        void apply(@NonNull Report report) throws ReportOps.BadArgument, ReportOps.Refused;
    }

    /** The reply codes of {@code createReport} (PlatformException codes; Dart: ReportWire). */
    static final String CREATE_BUSY = "create-busy";
    static final String CREATE_TIMEOUT = "create-timeout";

    /** How long the SDK may take to answer {@code createReport}: it runs the before handler (20 s) first. */
    static final long CREATE_TIMEOUT_MS = 45_000L;

    private static final class Holder {
        static final ReportFileFlow INSTANCE = new ReportFileFlow(
                ReportHandlerPipeline.shared(),
                CreatedReports.shared(),
                ReportFileWorker.shared()::execute,
                BugseeFlutterPlugin::postToMain,
                new BitmapImages(),
                new Sdk() {
                    @Override
                    public void createReport(@NonNull final ReportCreationListener listener) {
                        Bugsee.createReport(listener);
                    }

                    @Override
                    public void upload(@NonNull final Report report, @NonNull final Callback1<Boolean> done) {
                        Bugsee.upload(report, done);
                    }
                },
                CREATE_TIMEOUT_MS);
    }

    @NonNull
    static ReportFileFlow shared() {
        return Holder.INSTANCE;
    }

    private final ReportHandlerPipeline pipeline;
    private final CreatedReports created;
    private final Worker worker;
    private final Main main;
    private final ReportOps.ImageDecoder images;
    private final Sdk sdk;
    private final long createTimeoutMs;

    ReportFileFlow(
            @NonNull final ReportHandlerPipeline pipeline,
            @NonNull final CreatedReports created,
            @NonNull final Worker worker,
            @NonNull final Main main,
            @NonNull final ReportOps.ImageDecoder images,
            @NonNull final Sdk sdk,
            final long createTimeoutMs
    ) {
        this.pipeline = pipeline;
        this.created = created;
        this.worker = worker;
        this.main = main;
        this.images = images;
        this.sdk = sdk;
        this.createTimeoutMs = createTimeoutMs;
    }

    // ---- shared plumbing -----------------------------------------------------------------------

    private <T> void answer(@NonNull final Reply<T> reply, @Nullable final T value) {
        main.post(() -> reply.success(value));
    }

    private <T> void fail(@NonNull final Reply<T> reply, @NonNull final String code, @NonNull final String message) {
        main.post(() -> reply.error(code, message));
    }

    /** The reply of a file operation that threw: a refusal is a code, anything else an error reply. */
    private void failure(@NonNull final Reply<String> reply, @NonNull final Throwable t) {
        if (t instanceof ReportOps.BadArgument) {
            fail(reply, FacadeOps.INVALID_ARGUMENT, String.valueOf(t.getMessage()));
        } else if (t instanceof ReportOps.Refused) {
            answer(reply, ((ReportOps.Refused) t).code);
        } else {
            // The class only: nothing that carries a path or user data.
            fail(reply, FacadeOps.SDK_ERROR, "report file operation: " + t.getClass().getName());
        }
    }

    void setScreenshot(
            @NonNull final Report report,
            @NonNull final String path,
            final long displayId,
            final boolean annotated
    ) throws ReportOps.BadArgument, ReportOps.Refused {
        ReportOps.setScreenshot(report, images, path, displayId, annotated);
    }

    // ---- a handler's report ----------------------------------------------------------------------

    void handlerOp(
            @NonNull final String handle,
            @NonNull final FileOp op,
            @NonNull final Reply<String> reply
    ) {
        final ReportHandlerPipeline.Lease lease = pipeline.acquire(handle);
        if (lease == null) {
            answer(reply, ReportOps.NOT_LIVE);
            return;
        }
        final boolean queued = worker.execute(() -> {
            try {
                op.apply(lease.report());
                answer(reply, null);
            } catch (final Throwable t) {
                failure(reply, t);
            } finally {
                lease.release();
            }
        });
        if (!queued) {
            lease.release();
            answer(reply, ReportOps.BUSY);
        }
    }

    // ---- a created report ------------------------------------------------------------------------

    private final CreatedReports.Expiry expiry = new CreatedReports.Expiry() {
        @Override
        public void createTimedOut() {
            // Per reservation: see create().
        }

        @Override
        public void expired(@NonNull final Report report) {
            discardBehindQueue(report);
        }
    };

    /** The discard waits behind any file operation already queued for the report. */
    private void discardBehindQueue(@NonNull final Report report) {
        if (!worker.execute(() -> CreatedReportOps.discard(report))) {
            CreatedReportOps.discard(report);
        }
    }

    void create(final long ttlMs, @NonNull final Reply<String> reply) {
        final AtomicBoolean answered = new AtomicBoolean();
        // The slot is taken before the SDK is asked: its listener answers later, on its own thread.
        final int stamp = created.reserve(createTimeoutMs, new CreatedReports.Expiry() {
            @Override
            public void createTimedOut() {
                if (answered.compareAndSet(false, true)) {
                    fail(reply, CREATE_TIMEOUT, "the SDK did not answer createReport in time");
                }
            }

            @Override
            public void expired(@NonNull final Report report) {
                // A reservation holds no report.
            }
        });
        if (stamp == 0) {
            // On the caller's thread, already the platform thread.
            reply.error(CREATE_BUSY, "a created report is already outstanding");
            return;
        }
        try {
            sdk.createReport(report -> {
                String handle = null;
                try {
                    handle = created.fulfil(stamp, report, ttlMs, expiry);
                } catch (final Throwable ignored) {
                    // Nothing to register; the report is discarded below.
                }
                if (handle == null && report != null) {
                    // Refused (timed out, or cleared by a reset): nobody will use this report.
                    discardBehindQueue(report);
                }
                final String minted = handle;
                if (answered.compareAndSet(false, true)) {
                    answer(reply, minted);
                } else if (minted != null) {
                    // The caller was already told it timed out: release what was just registered.
                    final Report late = created.take(minted);
                    if (late != null) {
                        discardBehindQueue(late);
                    }
                }
            });
        } catch (final Throwable t) {
            created.fulfil(stamp, null, 0L, expiry);
            if (answered.compareAndSet(false, true)) {
                fail(reply, FacadeOps.SDK_ERROR, "createReport: " + t.getClass().getName());
            }
        }
    }

    @Nullable
    CreatedReportOps.Snapshot read(@NonNull final String handle) {
        final Report report = created.get(handle);
        return report == null ? null : CreatedReportOps.read(report);
    }

    /** False when the handle is not live. */
    boolean apply(@NonNull final String handle, @NonNull final CreatedReportOps.Patch patch)
            throws ReportOps.BadArgument {
        final Report report = created.get(handle);
        if (report == null) {
            return false;
        }
        CreatedReportOps.apply(report, patch);
        return true;
    }

    void createdOp(
            @NonNull final String handle,
            @NonNull final FileOp op,
            @NonNull final Reply<String> reply
    ) {
        // Looked up NOW, on the platform thread, in call order: an operation called before an upload
        // or a discard belongs to the report and lands before either (they queue behind it), one
        // called after finds nothing.
        final Report report = created.get(handle);
        if (report == null) {
            answer(reply, ReportOps.NOT_LIVE);
            return;
        }
        final boolean queued = worker.execute(() -> {
            try {
                op.apply(report);
                answer(reply, null);
            } catch (final Throwable t) {
                failure(reply, t);
            }
        });
        if (!queued) {
            answer(reply, ReportOps.BUSY);
        }
    }

    /** Copied, never moved: a created report has no move (iOS cannot, and the report may be discarded). */
    void createdAddFile(
            @NonNull final String handle,
            @NonNull final String path,
            @NonNull final String name,
            @Nullable final String mimeType,
            @NonNull final Reply<String> reply
    ) {
        createdOp(handle, report -> ReportOps.addFile(report, path, name, mimeType, false), reply);
    }

    /** Non-empty only: iOS would drop an empty one at upload, so neither platform takes it. */
    void createdAddBytes(
            @NonNull final String handle,
            @NonNull final byte[] data,
            @NonNull final String name,
            @Nullable final String mimeType,
            @NonNull final Reply<String> reply
    ) {
        createdOp(handle, report -> {
            if (data.length == 0) {
                throw new ReportOps.BadArgument("a created-report attachment must not be empty");
            }
            ReportOps.addBytes(report, data, name, mimeType);
        }, reply);
    }

    void upload(@NonNull final String handle, @NonNull final Reply<Boolean> reply) {
        // Taken at once, on the platform thread: the slot is free whatever the SDK answers, and a
        // second upload (or any later call) finds nothing.
        final Report report = created.take(handle);
        if (report == null) {
            answer(reply, false);
            return;
        }
        final AtomicBoolean answered = new AtomicBoolean();
        final Runnable send = () -> {
            try {
                sdk.upload(report, ok -> {
                    if (answered.compareAndSet(false, true)) {
                        answer(reply, Boolean.TRUE.equals(ok));
                    }
                });
            } catch (final Throwable t) {
                if (answered.compareAndSet(false, true)) {
                    fail(reply, FacadeOps.SDK_ERROR, "upload: " + t.getClass().getName());
                }
            }
        };
        // Behind the file operations already queued for this report, so an attachment the app did or
        // did not await is in the report when the SDK processes it.
        if (!worker.execute(send)) {
            send.run();
        }
    }

    void discard(@NonNull final String handle) {
        final Report report = created.take(handle);
        if (report != null) {
            discardBehindQueue(report);
        }
    }

    /** A new Dart isolate: the old one's created report is released now, not at its deadline. */
    void reset() {
        final Report orphan = created.clear();
        if (orphan != null) {
            discardBehindQueue(orphan);
        }
    }
}
