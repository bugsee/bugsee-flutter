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
    private final Queue createdWorker = new Queue();
    private final ManualScheduler uploadTimers = new ManualScheduler();
    private final Object owner = new Object();
    private final long[] clockMs = {0L};
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
                }, () -> null, () -> ReportHandlerDeadlines.LIVE_HANDLER_THREAD, line -> { }, () -> clockMs[0]);
        flow = new ReportFileFlow(
                pipeline, new CreatedReports(createdTimers, () -> 0L), worker::execute, createdWorker::execute, main::execute,
                (f, max) -> {
                    throw new ReportOps.Refused(ReportOps.IMAGE_UNDECODABLE);
                },
                sdk, uploadTimers, 45_000L, 45_000L);
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
        createdWorker.drain();
        main.drain();
    }

    // ---- a handler's report ------------------------------------------------------------------------

    @Test
    public void aHandlersFileOperationRunsOnTheWorkerAndRepliesOnTheMainThread() throws Exception {
        final String handle = liveHandle();
        final Replies<String> reply = new Replies<>();
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, file.getPath(), "a", null, false, w), reply);
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
        flow.handlerOp("rh-nope", (r, w) -> ReportOps.addFile(r, file.getPath(), "a", null, true, w), reply);
        assertEquals(0, worker.tasks.size());
        main.drain();
        assertEquals(List.of(ReportOps.NOT_LIVE), reply.got);
        assertTrue(file.exists());
    }

    @Test
    public void aRefusalIsACodeAndABadArgumentAnErrorReply() throws Exception {
        final String handle = liveHandle();
        final Replies<String> reply = new Replies<>();
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, "/no/such/file", "a", null, false, w), reply);
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, "relative", "a", null, false, w), reply);
        flow.handlerOp(handle, (r, w) -> {
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
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, file.getPath(), "a", null, true, w), reply);
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
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, file.getPath(), "a", null, false, w), reply);
        // The handler returns (Dart completes the handle) BEFORE the worker got to the copy.
        assertTrue(pipeline.complete(handle));
        assertEquals("the completion waits for the claim", 0, completions.get());
        assertNull("and the handle is no longer live for new edits", pipeline.reportFor(handle));
        final Replies<String> late = new Replies<>();
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, file.getPath(), "late", null, false, w), late);
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
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, file.getPath(), "a", null, false, w), new Replies<>());
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
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, file.getPath(), "1", null, false, w), new Replies<>());
        flow.handlerOp(handle, (r, w) -> ReportOps.addBytes(r, new byte[1], "2", null, w), new Replies<>());
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
        flow.create(owner, 600_000L, reply);
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
        flow.create(owner, 1000L, second);
        assertEquals("answered inline, no hop", List.of("error:create-busy"), second.got);
    }

    @Test
    public void whenTheSdkMakesNoReportTheAnswerIsNullAndTheSlotFree() {
        final Replies<String> reply = new Replies<>();
        flow.create(owner, 1000L, reply);
        sdk.listener.onCreated(null);
        main.drain();
        assertEquals(List.of("ok"), reply.got);
        final Replies<String> again = new Replies<>();
        flow.create(owner, 1000L, again);
        assertNotNull("not busy", sdk.listener);
    }

    @Test
    public void anSdkThatThrowsFreesTheSlotAndIsAnErrorReply() {
        sdk.throwOnCreate = true;
        final Replies<String> reply = new Replies<>();
        flow.create(owner, 1000L, reply);
        main.drain();
        assertEquals(List.of("error:sdk-error"), reply.got);
        sdk.throwOnCreate = false;
        final Replies<String> again = new Replies<>();
        flow.create(owner, 1000L, again);
        assertTrue("the slot is free", again.got.isEmpty() && sdk.listener != null);
    }

    @Test
    public void anSdkThatNeverAnswersTimesOutAndItsLateReportIsDiscardedNotPublished() throws Exception {
        final Replies<String> reply = new Replies<>();
        flow.create(owner, 1000L, reply);
        final ReportCreationListener late = sdk.listener;
        createdTimers.tasks.get(0).run(); // the create timeout
        main.drain();
        assertEquals(List.of("error:create-timeout"), reply.got);
        // The SDK answers after all.
        ReportOps.addBytes(FakeReports.create(createdState), new byte[1], "kept", null, ReportOps.OPEN);
        late.onCreated(FakeReports.create(createdState));
        createdWorker.drain();
        main.drain();
        assertEquals("no second reply", 1, reply.got.size());
        assertTrue("its attachments were deleted", createdState.calls.contains("clearAttachments"));
        // And the slot is not held by it.
        final Replies<String> next = new Replies<>();
        flow.create(owner, 1000L, next);
        assertTrue(next.got.isEmpty());
    }

    @Test
    public void createdFileOperationsRunOnTheWorkerInOrderAndNeverMove() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<String> reply = new Replies<>();
        flow.createdAddFile(handle, file.getPath(), "a", "text/plain", reply);
        flow.createdAddBytes(handle, new byte[] {9}, "b", null, reply);
        assertEquals(2, createdWorker.tasks.size());
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
        assertEquals(0, createdWorker.tasks.size());
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

        createdWorker.drain();
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
        assertEquals("not 'the SDK declined': the report is gone", List.of("error:not-live"), second.got);
        createdWorker.drain();
        assertEquals(1, sdk.uploaded.size());
        sdk.uploadDone.run(false);
        main.drain();
        assertEquals("the SDK's own false is passed on", List.of(false), first.got);
        final Replies<String> next = new Replies<>();
        flow.create(owner, 1000L, next);
        assertTrue("not busy", next.got.isEmpty());
    }

    @Test
    public void anUploadWhoseQueueIsFullStillReachesTheSdkOnAnotherThread() throws Exception {
        final String handle = create(new Replies<>());
        createdWorker.accept = false;
        flow.upload(handle, new Replies<>());
        final long deadline = System.currentTimeMillis() + 5000;
        while (sdk.uploaded.isEmpty() && System.currentTimeMillis() < deadline) {
            Thread.sleep(10);
        }
        assertEquals(1, sdk.uploaded.size());
    }

    @Test
    public void anSdkThatThrowsOnUploadIsAnErrorReplyAndTheReportIsGone() throws Exception {
        final String handle = create(new Replies<>());
        sdk.throwOnUpload = true;
        final Replies<Boolean> reply = new Replies<>();
        flow.upload(handle, reply);
        createdWorker.drain();
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
        assertEquals("the add is queued before the discard", 2, createdWorker.tasks.size());
        createdWorker.drain();
        assertEquals("the add landed, and the discard behind it deleted it", 1, createdState.adds.size());
        assertEquals(0, createdState.attachments.size());
        assertEquals(1, java.util.Collections.frequency(createdState.calls, "clearAttachments"));
    }

    @Test
    public void theTimeToLiveDiscardsAndFreesTheSlot() throws Exception {
        final String handle = create(new Replies<>());
        createdTimers.tasks.get(0).run(); // the ttl timer (the create timer was cancelled)
        createdWorker.drain();
        assertNull(flow.read(handle));
        assertTrue(createdState.calls.contains("clearAttachments"));
        final Replies<String> next = new Replies<>();
        flow.create(owner, 1000L, next);
        assertTrue("not busy", next.got.isEmpty());
    }

    @Test
    public void aResetReleasesTheOrphan() throws Exception {
        final String handle = create(new Replies<>());
        flow.reset(owner);
        createdWorker.drain();
        assertNull(flow.read(handle));
        assertTrue(createdState.calls.contains("clearAttachments"));
        flow.reset(owner); // nothing held: harmless
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

    // ---- Phase 6 review ------------------------------------------------------------------------------

    @Test
    public void anUploadTheSdkNeverAnswersFailsClosedAndALateCallbackIsIgnored() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<Boolean> reply = new Replies<>();
        flow.upload(handle, reply);
        createdWorker.drain();
        assertEquals(1, uploadTimers.tasks.size());
        uploadTimers.tasks.get(0).run();
        main.drain();
        assertEquals(List.of("error:upload-timeout"), reply.got);
        sdk.uploadDone.run(true); // the SDK answers after all
        main.drain();
        assertEquals("exactly one answer", 1, reply.got.size());
    }

    @Test
    public void anAnsweredUploadCancelsItsTimerAndALateTimerDoesNothing() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<Boolean> reply = new Replies<>();
        flow.upload(handle, reply);
        createdWorker.drain();
        final Runnable timer = uploadTimers.tasks.get(0);
        sdk.uploadDone.run(true);
        main.drain();
        assertEquals(List.of(true), reply.got);
        assertTrue("the timer was cancelled", uploadTimers.tasks.isEmpty());
        timer.run(); // already started when the cancel came
        main.drain();
        assertEquals(List.of(true), reply.got);
    }

    @Test
    public void anSdkThatThrowsOnUploadCancelsTheTimerToo() throws Exception {
        final String handle = create(new Replies<>());
        sdk.throwOnUpload = true;
        final Replies<Boolean> reply = new Replies<>();
        flow.upload(handle, reply);
        createdWorker.drain();
        main.drain();
        assertEquals(List.of("error:sdk-error"), reply.got);
        assertTrue(uploadTimers.tasks.isEmpty());
    }

    @Test
    public void aHandlerOperationQueuedBehindASlowCopyDoesNotStartOnceTheWindowClosed() throws Exception {
        final String handle = liveHandle();
        final Replies<String> reply = new Replies<>();
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, file.getPath(), "late", null, true, w), reply);
        clockMs[0] = 25_000L; // the slow copy ahead of it took the handler's window (20 s) and more
        worker.drain();
        main.drain();
        assertEquals(List.of(ReportOps.NOT_LIVE), reply.got);
        assertEquals("nothing was imported", 0, handlerState.adds.size());
        assertTrue("and nothing was consumed", file.exists());
    }

    @Test
    public void anAddThatFinishesAfterTheWindowClosedIsRefusedAndTheMovedSourceSurvives() throws Exception {
        final String handle = liveHandle();
        // The SDK's own handler timer fires during the import (the model SDK still registers the attachment).
        handlerState.duringAdd = () -> clockMs[0] = 25_000L;
        final Replies<String> reply = new Replies<>();
        flow.handlerOp(handle, (r, w) -> ReportOps.addFile(r, file.getPath(), "orphan", null, true, w), reply);
        drainAll();
        assertEquals(List.of(ReportOps.REJECTED), reply.got);
        assertTrue("the user's file was not lost", file.exists());
        assertEquals(java.util.Collections.singletonList("orphan"), handlerState.deleted);
    }

    @Test
    public void aSlowHandlerCopyDoesNotHoldUpACreatedReport() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<String> handlerReply = new Replies<>();
        flow.handlerOp(liveHandle(), (r, w) -> ReportOps.addFile(r, file.getPath(), "slow", null, false, w), handlerReply);
        // The handler worker has not run (a slow copy is ahead of it); the created report's work is separate.
        final Replies<String> createdReply = new Replies<>();
        flow.createdAddBytes(handle, new byte[] {1}, "b", null, createdReply);
        createdWorker.drain();
        main.drain();
        assertEquals(List.of("ok"), createdReply.got);
        assertEquals(1, createdState.adds.size());
        assertEquals(1, worker.tasks.size());
        assertTrue(handlerReply.got.isEmpty());
    }

    @Test
    public void anotherEnginesResetKeepsMyCreatedReport() throws Exception {
        final String handle = create(new Replies<>());
        flow.reset(new Object());
        assertNotNull(flow.read(handle));
        final Replies<String> busy = new Replies<>();
        flow.create(new Object(), 1000L, busy);
        assertEquals(List.of("error:create-busy"), busy.got);
        flow.reset(owner);
        assertNull(flow.read(handle));
    }

    @Test
    public void anInFlightCreateSurvivesAnotherEnginesReset() throws Exception {
        final Replies<String> reply = new Replies<>();
        flow.create(owner, 600_000L, reply);
        flow.reset(new Object());
        sdk.listener.onCreated(FakeReports.create(createdState));
        main.drain();
        assertEquals(List.of("cr-1"), reply.got);
    }

    @Test
    public void anInFlightCreateIsReleasedByItsOwnEnginesReset() throws Exception {
        final Replies<String> reply = new Replies<>();
        flow.create(owner, 600_000L, reply);
        flow.reset(owner);
        sdk.listener.onCreated(FakeReports.create(createdState));
        createdWorker.drain();
        main.drain();
        assertTrue("the late report is discarded, not published", createdState.calls.contains("clearAttachments"));
        assertEquals(List.of("ok"), reply.got); // answered with none
    }

    @Test
    public void tooManyCreatesAreRateLimitedWithATypedCode() throws Exception {
        for (int i = 0; i < CreatedReports.RATE_LIMIT; i++) {
            final String handle = create(new Replies<>());
            flow.discard(handle);
            sdk.listener = null;
        }
        final Replies<String> reply = new Replies<>();
        flow.create(owner, 1000L, reply);
        assertEquals(List.of("error:create-rate-limited"), reply.got);
        assertNull("the SDK was not asked", sdk.listener);
    }

    @Test
    public void aDiscardWithAFullQueueNeverRunsOnTheCallingThread() throws Exception {
        final String handle = create(new Replies<>());
        createdWorker.accept = false;
        final Thread caller = Thread.currentThread();
        final Thread[] ranOn = new Thread[1];
        createdState.onClear = () -> ranOn[0] = Thread.currentThread();
        flow.discard(handle);
        final long deadline = System.currentTimeMillis() + 5000;
        while (ranOn[0] == null && System.currentTimeMillis() < deadline) {
            Thread.sleep(10);
        }
        assertNotNull(ranOn[0]);
        assertTrue("not inline", ranOn[0] != caller);
    }

    @Test
    public void createdEmptyFileIsRefusedLikeEmptyBytes() throws Exception {
        final String handle = create(new Replies<>());
        final File empty = tmp.newFile("empty.txt");
        final Replies<String> reply = new Replies<>();
        flow.createdAddFile(handle, empty.getPath(), "e", null, reply);
        drainAll();
        assertEquals(List.of("error:invalid-argument"), reply.got);
        assertEquals(0, createdState.adds.size());
    }

    @Test
    public void createdOperationsLeaveRoomForTheUploadAndTheDiscardBehindThem() throws Exception {
        final String handle = create(new Replies<>());
        final Replies<String> accepted = new Replies<>();
        for (int i = 0; i < ReportFileFlow.CREATED_OPS_LIMIT; i++) {
            flow.createdAddBytes(handle, new byte[] {1}, "b" + i, null, accepted);
        }
        final Replies<String> over = new Replies<>();
        flow.createdAddBytes(handle, new byte[] {1}, "one too many", null, over);
        main.drain();
        assertEquals(List.of(ReportOps.BUSY), over.got);
        assertEquals(ReportFileFlow.CREATED_OPS_LIMIT, createdWorker.tasks.size());
        // The upload is queued behind every operation the app called first, not started beside them.
        final Replies<Boolean> up = new Replies<>();
        flow.upload(handle, up);
        assertEquals(ReportFileFlow.CREATED_OPS_LIMIT + 1, createdWorker.tasks.size());
        assertTrue(sdk.uploaded.isEmpty());
        createdWorker.drain();
        assertEquals("every add landed before the SDK was handed the report",
                ReportFileFlow.CREATED_OPS_LIMIT, createdState.adds.size());
        assertEquals(1, sdk.uploaded.size());
        main.drain();
        assertEquals(ReportFileFlow.CREATED_OPS_LIMIT, accepted.got.size());
    }

    @Test
    public void theBudgetIsGivenBackWhenOperationsFinish() throws Exception {
        final String handle = create(new Replies<>());
        for (int round = 0; round < 3; round++) {
            for (int i = 0; i < ReportFileFlow.CREATED_OPS_LIMIT; i++) {
                flow.createdAddBytes(handle, new byte[] {1}, "b", null, new Replies<>());
            }
            createdWorker.drain();
            main.drain();
        }
        final Replies<String> again = new Replies<>();
        flow.createdAddBytes(handle, new byte[] {1}, "still fine", null, again);
        createdWorker.drain();
        main.drain();
        assertEquals(List.of("ok"), again.got);
    }
}
