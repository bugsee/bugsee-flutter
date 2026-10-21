package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.common.Callback1;
import com.bugsee.library.contracts.reporting.Report;
import com.bugsee.library.contracts.reporting.ReportCreationListener;

import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.nio.file.Files;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * The file operations and the createReport flow with the threads made explicit: the worker and the
 * platform thread are queues the test drains, so what runs where, and in what order, is asserted
 * instead of hoped for.
 */
public class ReportFileFlowTest {

    @Rule public TemporaryFolder tmp = new TemporaryFolder();

    // ---- the seams ----------------------------------------------------------------------------

    private static final class Queue {
        final ArrayDeque<Runnable> tasks = new ArrayDeque<>();
        boolean accept = true;

        boolean execute(final Runnable task) {
            if (accept) {
                tasks.add(task);
            }
            return accept;
        }

        int drain() {
            int n = 0;
            while (!tasks.isEmpty()) {
                tasks.poll().run();
                n++;
            }
            return n;
        }
    }

    private static final class Replies<T> implements ReportFileFlow.Reply<T> {
        final List<Object> got = new ArrayList<>();

        @Override
        public void success(final T value) {
            got.add(value == null ? "ok" : value);
        }

        @Override
        public void error(final String code, final String message) {
            got.add("error:" + code);
        }
    }

    private static final class FakeSdk implements ReportFileFlow.Sdk {
        ReportCreationListener listener;
        final List<Report> uploaded = new ArrayList<>();
        Callback1<Boolean> uploadDone;
        boolean throwOnCreate;
        boolean throwOnUpload;

        @Override
        public void createReport(final ReportCreationListener l) {
            if (throwOnCreate) {
                throw new IllegalStateException("sdk is gone");
            }
            listener = l;
        }

        @Override
        public void upload(final Report report, final Callback1<Boolean> done) {
            if (throwOnUpload) {
                throw new IllegalStateException("sdk is gone");
            }
            uploaded.add(report);
            uploadDone = done;
        }
    }

    private static final class ManualScheduler implements ReportHandlerPipeline.Scheduler {
        final List<Runnable> tasks = new ArrayList<>();

        @Override
        public ReportHandlerPipeline.Cancellable schedule(final Runnable task, final long delayMs) {
            tasks.add(task);
            return () -> tasks.remove(task);
        }
    }

    private final Queue worker = new Queue();
    private final Queue main = new Queue();
    private final FakeSdk sdk = new FakeSdk();
    private final ManualScheduler createdTimers = new ManualScheduler();
    private final ManualScheduler pipelineTimers = new ManualScheduler();
    private final FakeReports.State handlerState = new FakeReports.State();
    private final FakeReports.State createdState = new FakeReports.State();
    private final AtomicInteger completions = new AtomicInteger();
    private ReportHandlerPipeline pipeline;
    private ReportFileFlow flow;
    private File file;

    @Before
    public void setUp() throws Exception {
        pipeline = new ReportHandlerPipeline(
                pipelineTimers, task -> {
                    task.run();
                    return true;
                }, () -> null, () -> ReportHandlerDeadlines.LIVE_HANDLER_THREAD, line -> { });
        flow = new ReportFileFlow(
                pipeline, new CreatedReports(createdTimers), worker::execute, main::execute,
                (f, max) -> {
                    throw new ReportOps.Refused(ReportOps.IMAGE_UNDECODABLE);
                },
                sdk, 45_000L);
        handlerState.storage = tmp.newFolder("handler-storage");
        createdState.storage = tmp.newFolder("created-storage");
        file = tmp.newFile("a.txt");
        Files.write(file.toPath(), new byte[] {1, 2, 3});
    }

    /** Delivers a report to the pipeline with a registered Dart end and returns the live handle. */
    private String liveHandle() {
        final String[] handle = new String[1];
        final Object owner = new Object();
        pipeline.attach(owner, (request, unreachable) -> handle[0] = request.handle);
        pipeline.setPhases(owner, true, true);
        pipeline.dispatch(ReportHandlerPipeline.Phase.BEFORE, FakeReports.create(handlerState), false,
                completions::incrementAndGet);
        return handle[0];
    }

    private void drainAll() {
        worker.drain();
        main.drain();
    }

    // ---- a handler's report ------------------------------------------------------------------------

    @Test
    public void aHandlersFileOperationRunsOnTheWorkerAndRepliesOnTheMainThread() throws Exception {
        final String handle = liveHandle();
        final Replies<String> reply = new Replies<>();
        flow.handlerOp(handle, r -> ReportOps.addFile(r, file.getPath(), "a", null, false), reply);
        assertTrue("nothing ran on the calling (platform) thread", handlerState.adds.isEmpty());
        assertEquals(1, worker.tasks.size());
        worker.drain();
        assertEquals("the work ran, the reply is queued for the platform thread", 1, handlerState.adds.size());
        assertTrue(reply.got.isEmpty());
        main.drain();
        assertEquals(List.of("ok"), reply.got);
    }

    @Test
    public void aHandleThatIsNotLiveAnswersNotLiveAndTouchesNothing() {
        final Replies<String> reply = new Replies<>();
        flow.handlerOp("rh-nope", r -> ReportOps.addFile(r, file.getPath(), "a", null, true), reply);
        assertEquals(0, worker.tasks.size());
        main.drain();
        assertEquals(List.of(ReportOps.NOT_LIVE), reply.got);
        assertTrue(file.exists());
    }

    @Test
    public void aRefusalIsACodeAndABadArgumentAnErrorReply() throws Exception {
        final String handle = liveHandle();
        final Replies<String> reply = new Replies<>();
        flow.handlerOp(handle, r -> ReportOps.addFile(r, "/no/such/file", "a", null, false), reply);
        flow.handlerOp(handle, r -> ReportOps.addFile(r, "relative", "a", null, false), reply);
        flow.handlerOp(handle, r -> {
            throw new IllegalStateException("the SDK threw with /secret/path in it");
        }, reply);
        drainAll();
        assertEquals(List.of(ReportOps.FILE_NOT_FOUND, "error:invalid-argument", "error:sdk-error"), reply.got);
    }

    @Test
    public void aFullQueueAnswersBusyAndReleasesTheClaim() throws Exception {
        final String handle = liveHandle();
        worker.accept = false;
        final Replies<String> reply = new Replies<>();
        flow.handlerOp(handle, r -> ReportOps.addFile(r, file.getPath(), "a", null, true), reply);
        main.drain();
        assertEquals(List.of(ReportOps.BUSY), reply.got);
        assertTrue("a refused move did not consume the file", file.exists());
        // The claim ended: the handle completes at once instead of waiting for it.
        assertTrue(pipeline.complete(handle));
        assertEquals(1, completions.get());
    }

    @Test
    public void theSdksCompletionWaitsForAFileOperationThatStartedWhileTheHandleWasLive() throws Exception {
        final String handle = liveHandle();
        final Replies<String> reply = new Replies<>();
        flow.handlerOp(handle, r -> ReportOps.addFile(r, file.getPath(), "a", null, false), reply);
        // The handler returns (Dart completes the handle) BEFORE the worker got to the copy.
        assertTrue(pipeline.complete(handle));
        assertEquals("the completion waits for the claim", 0, completions.get());
        assertNull("and the handle is no longer live for new edits", pipeline.reportFor(handle));
        final Replies<String> late = new Replies<>();
        flow.handlerOp(handle, r -> ReportOps.addFile(r, file.getPath(), "late", null, false), late);
        main.drain();
        assertEquals(List.of(ReportOps.NOT_LIVE), late.got);

        worker.drain();
        assertEquals("the copy landed before the completion", 1, handlerState.adds.size());
        assertEquals("a", handlerState.adds.get(0)[1]);
        assertEquals("the last claim released the completion", 1, completions.get());
        main.drain();
        assertEquals(List.of("ok"), reply.got);
    }

    @Test
    public void theDeadlineAlsoWaitsForTheClaimAndRunsTheCompletionOnce() throws Exception {
        final String handle = liveHandle();
        flow.handlerOp(handle, r -> ReportOps.addFile(r, file.getPath(), "a", null, false), new Replies<>());
        for (final Runnable timer : new ArrayList<>(pipelineTimers.tasks)) {
            timer.run();
        }
        assertEquals(0, completions.get());
        worker.drain();
        assertEquals(1, completions.get());
        assertFalse("a second complete is a no-op", pipeline.complete(handle));
        assertEquals(1, completions.get());
    }

    @Test
    public void twoOperationsOnOneHandleCompleteAfterTheLastOne() throws Exception {
        final String handle = liveHandle();
        flow.handlerOp(handle, r -> ReportOps.addFile(r, file.getPath(), "1", null, false), new Replies<>());
        flow.handlerOp(handle, r -> ReportOps.addBytes(r, new byte[1], "2", null), new Replies<>());
        pipeline.complete(handle);
        final Runnable first = worker.tasks.poll();
        first.run();
        assertEquals("one claim is still held", 0, completions.get());
        worker.drain();
        assertEquals(1, completions.get());
        assertEquals(2, handlerState.adds.size());
    }

    // ---- createReport ---------------------------------------------------------------------------------

    private String create(final Replies<String> reply) {
        flow.create(600_000L, reply);
        assertNotNull("the SDK was asked", sdk.listener);
        sdk.listener.onCreated(FakeReports.create(createdState));
        main.drain();
        return (String) reply.got.get(reply.got.size() - 1);
    }

    @Test
    public void createMintsAHandleAndReadsTheReport() {
        final Replies<String> reply = new Replies<>();
        final String handle = create(reply);
        assertEquals("cr-1", handle);
        final CreatedReportOps.Snapshot s = flow.read(handle);
        assertEquals("report-1", s.id);
        assertNull(flow.read("cr-9"));
    }

    @Test
    public void aSecondCreateWhileOneIsOutstandingIsBusyOnTheCallingThread() {
        final Replies<String> first = new Replies<>();
        create(first);
        final Replies<String> second = new Replies<>();
        flow.create(1000L, second);
        assertEquals("answered inline, no hop", List.of("error:create-busy"), second.got);
    }

    @Test
    public void whenTheSdkMakesNoReportTheAnswerIsNullAndTheSlotFree() {
        final Replies<String> reply = new Replies<>();
        flow.create(1000L, reply);
        sdk.listener.onCreated(null);
        main.drain();
        assertEquals(List.of("ok"), reply.got);
        final Replies<String> again = new Replies<>();
        flow.create(1000L, again);
        assertNotNull("not busy", sdk.listener);
    }

    @Test
    public void anSdkThatThrowsFreesTheSlotAndIsAnErrorReply() {
        sdk.throwOnCreate = true;
        final Replies<String> reply = new Replies<>();
        flow.create(1000L, reply);
        main.drain();
        assertEquals(List.of("error:sdk-error"), reply.got);
        sdk.throwOnCreate = false;
        final Replies<String> again = new Replies<>();
        flow.create(1000L, again);
        assertTrue("the slot is free", again.got.isEmpty() && sdk.listener != null);
    }

    @Test
    public void anSdkThatNeverAnswersTimesOutAndItsLateReportIsDiscardedNotPublished() throws Exception {
        final Replies<String> reply = new Replies<>();
        flow.create(1000L, reply);
        final ReportCreationListener late = sdk.listener;
        createdTimers.tasks.get(0).run(); // the create timeout
        main.drain();
        assertEquals(List.of("error:create-timeout"), reply.got);
        // The SDK answers after all.
        ReportOps.addBytes(FakeReports.create(createdState), new byte[1], "kept", null);
        late.onCreated(FakeReports.create(createdState));
        worker.drain();
        main.drain();
        assertEquals("no second reply", 1, reply.got.size());
        assertTrue("its attachments were deleted", createdState.calls.contains("clearAttachments"));
        // And the slot is not held by it.
        final Replies<String> next = new Replies<>();
        flow.create(1000L, next);
        assertTrue(next.got.isEmpty());
    }

    @Test
    public void createdFileOperationsRunOnTheWorkerInOrderAndNeverMove() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<String> reply = new Replies<>();
        flow.createdAddFile(handle, file.getPath(), "a", "text/plain", reply);
        flow.createdAddBytes(handle, new byte[] {9}, "b", null, reply);
        assertEquals(2, worker.tasks.size());
        assertTrue(createdState.adds.isEmpty());
        drainAll();
        assertEquals(List.of("ok", "ok"), reply.got);
        assertEquals(Boolean.FALSE, createdState.adds.get(0)[3]);
        assertTrue("a created report copies: the source stays", file.exists());
        assertEquals("a", createdState.adds.get(0)[1]);
        assertEquals("b", createdState.adds.get(1)[1]);
    }

    @Test
    public void createdEmptyBytesAreAnArgumentError() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<String> reply = new Replies<>();
        flow.createdAddBytes(handle, new byte[0], "b", null, reply);
        drainAll();
        assertEquals(List.of("error:invalid-argument"), reply.got);
        assertTrue(createdState.adds.isEmpty());
    }

    @Test
    public void aCreatedOperationOnADeadHandleIsNotLive() throws Exception {
        final Replies<String> reply = new Replies<>();
        flow.createdAddFile("cr-77", file.getPath(), "a", null, reply);
        main.drain();
        assertEquals(List.of(ReportOps.NOT_LIVE), reply.got);
        assertEquals(0, worker.tasks.size());
    }

    @Test
    public void anOperationQueuedBeforeAnUploadStillLandsAndOneQueuedAfterIsNotLive() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<String> add = new Replies<>();
        flow.createdAddFile(handle, file.getPath(), "a", null, add);
        final Replies<Boolean> up = new Replies<>();
        flow.upload(handle, up);
        final Replies<String> after = new Replies<>();
        flow.createdAddFile(handle, file.getPath(), "after", null, after);
        main.drain();
        assertEquals("a call after the upload finds nothing", List.of(ReportOps.NOT_LIVE), after.got);

        worker.drain();
        assertEquals("the add ran first, then the SDK was handed the report", 1, createdState.adds.size());
        assertEquals(1, sdk.uploaded.size());
        assertNotNull(sdk.uploadDone);
        sdk.uploadDone.run(true);
        main.drain();
        assertEquals(List.of("ok"), add.got);
        assertEquals(List.of(true), up.got);
    }

    @Test
    public void uploadFreesTheSlotAtOnceAndASecondUploadIsFalse() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<Boolean> first = new Replies<>();
        flow.upload(handle, first);
        final Replies<Boolean> second = new Replies<>();
        flow.upload(handle, second);
        main.drain();
        assertEquals(List.of(false), second.got);
        worker.drain();
        assertEquals(1, sdk.uploaded.size());
        sdk.uploadDone.run(false);
        main.drain();
        assertEquals("the SDK's own false is passed on", List.of(false), first.got);
        final Replies<String> next = new Replies<>();
        flow.create(1000L, next);
        assertTrue("not busy", next.got.isEmpty());
    }

    @Test
    public void anUploadWhoseQueueIsFullStillReachesTheSdk() throws Exception {
        final String handle = create(new Replies<>());
        worker.accept = false;
        flow.upload(handle, new Replies<>());
        assertEquals(1, sdk.uploaded.size());
    }

    @Test
    public void anSdkThatThrowsOnUploadIsAnErrorReplyAndTheReportIsGone() throws Exception {
        final String handle = create(new Replies<>());
        sdk.throwOnUpload = true;
        final Replies<Boolean> reply = new Replies<>();
        flow.upload(handle, reply);
        worker.drain();
        main.drain();
        assertEquals(List.of("error:sdk-error"), reply.got);
        assertNull(flow.read(handle));
    }

    @Test
    public void discardReleasesOnceAndDeletesTheAttachmentsBehindTheQueue() throws Exception {
        final String handle = create(new Replies<>());
        flow.createdAddBytes(handle, new byte[] {1}, "b", null, new Replies<>());
        flow.discard(handle);
        flow.discard(handle);
        assertNull(flow.read(handle));
        assertEquals("the add is queued before the discard", 2, worker.tasks.size());
        worker.drain();
        assertEquals("the add landed, and the discard behind it deleted it", 1, createdState.adds.size());
        assertEquals(0, createdState.attachments.size());
        assertEquals(1, java.util.Collections.frequency(createdState.calls, "clearAttachments"));
    }

    @Test
    public void theTimeToLiveDiscardsAndFreesTheSlot() throws Exception {
        final String handle = create(new Replies<>());
        createdTimers.tasks.get(0).run(); // the ttl timer (the create timer was cancelled)
        worker.drain();
        assertNull(flow.read(handle));
        assertTrue(createdState.calls.contains("clearAttachments"));
        final Replies<String> next = new Replies<>();
        flow.create(1000L, next);
        assertTrue("not busy", next.got.isEmpty());
    }

    @Test
    public void aResetReleasesTheOrphan() throws Exception {
        final String handle = create(new Replies<>());
        flow.reset();
        worker.drain();
        assertNull(flow.read(handle));
        assertTrue(createdState.calls.contains("clearAttachments"));
        flow.reset(); // nothing held: harmless
    }

    @Test
    public void applyIsFalseForADeadHandleAndAppliesToALiveOne() throws Exception {
        final String handle = create(new Replies<>());
        final CreatedReportOps.Patch p = new CreatedReportOps.Patch();
        p.setSummary = true;
        p.summary = "s";
        assertTrue(flow.apply(handle, p));
        assertEquals("s", createdState.summary);
        assertFalse(flow.apply("cr-9", p));
    }
}
