package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import com.bugsee.flutter.ReportHandlerPipeline.Phase;
import com.bugsee.library.contracts.reporting.Report;

import org.junit.Before;
import org.junit.Test;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The one property everything here protects: the SDK's completion runs exactly once for
 * every dispatch, whichever of Dart, the deadline, a detach, a failure or an error gets
 * there first (workbook 7.1.2). Running it twice advances the SDK's chain twice; never
 * running it stalls the report until the SDK's own timeout.
 */
public class ReportHandlerPipelineTest {

    /** Runs a task only when the test says so; the delay is the injected "clock". */
    private static final class ManualScheduler implements ReportHandlerPipeline.Scheduler {
        static final class Task implements ReportHandlerPipeline.Cancellable {
            final Runnable runnable;
            final long delayMs;
            boolean cancelled;

            Task(final Runnable runnable, final long delayMs) {
                this.runnable = runnable;
                this.delayMs = delayMs;
            }

            @Override
            public void cancel() {
                cancelled = true;
            }
        }

        final List<Task> tasks = new ArrayList<>();
        boolean throwOnSchedule;

        @Override
        public ReportHandlerPipeline.Cancellable schedule(final Runnable task, final long delayMs) {
            if (throwOnSchedule) {
                throw new IllegalStateException("scheduler is gone");
            }
            final Task t = new Task(task, delayMs);
            tasks.add(t);
            return t;
        }

        /** The real race: the timer thread already started the task when cancel() arrives. */
        void fireEvenIfCancelled() {
            for (final Task t : new ArrayList<>(tasks)) {
                t.runnable.run();
            }
        }

        void fireDue() {
            for (final Task t : new ArrayList<>(tasks)) {
                if (!t.cancelled) {
                    t.runnable.run();
                }
            }
        }
    }

    /** A platform thread whose tasks run when the test drains it. */
    private static final class QueuePlatform implements ReportHandlerPipeline.PlatformThread {
        final ArrayDeque<Runnable> queue = new ArrayDeque<>();
        boolean accept = true;
        boolean throwOnPost;

        @Override
        public boolean post(final Runnable task) {
            if (throwOnPost) {
                throw new IllegalStateException("looper is gone");
            }
            if (accept) {
                queue.add(task);
            }
            return accept;
        }

        void drain() {
            while (!queue.isEmpty()) {
                queue.poll().run();
            }
        }
    }

    private static final class RecordingSink implements ReportHandlerPipeline.Sink {
        final List<ReportHandlerPipeline.Request> requests = new ArrayList<>();
        final List<Runnable> unreachable = new ArrayList<>();
        boolean throwOnDeliver;

        @Override
        public void deliver(final ReportHandlerPipeline.Request request, final Runnable onUnreachable) {
            if (throwOnDeliver) {
                throw new IllegalStateException("bridge is dead");
            }
            requests.add(request);
            unreachable.add(onUnreachable);
        }
    }

    private final ManualScheduler scheduler = new ManualScheduler();
    private final QueuePlatform platform = new QueuePlatform();
    private final AtomicReference<String> thread =
            new AtomicReference<>(ReportHandlerDeadlines.LIVE_HANDLER_THREAD);
    private final AtomicReference<Integer> option = new AtomicReference<>();
    private final List<String> log = Collections.synchronizedList(new ArrayList<>());
    private final RecordingSink sink = new RecordingSink();
    private final Object owner = new Object();
    private final FakeReports.State state = new FakeReports.State();
    private final Report report = FakeReports.create(state);
    private final AtomicInteger completions = new AtomicInteger();
    private ReportHandlerPipeline pipeline;

    @Before
    public void setUp() {
        pipeline = new ReportHandlerPipeline(
                scheduler, platform, option::get, thread::get, log::add);
        pipeline.attach(owner, sink);
        pipeline.setPhases(owner, true, true);
    }

    private void dispatch(final Phase phase, final boolean terminating) {
        pipeline.dispatch(phase, report, terminating, completions::incrementAndGet);
    }

    private ReportHandlerPipeline.Request delivered() {
        platform.drain();
        assertEquals(1, sink.requests.size());
        return sink.requests.get(0);
    }

    // ---- exactly once, on every path ---------------------------------------------------

    @Test
    public void dartCompletingRunsTheCompletionOnce() {
        dispatch(Phase.BEFORE, false);
        assertEquals("the SDK is waiting for us; nothing has completed yet", 0, completions.get());
        final ReportHandlerPipeline.Request request = delivered();
        assertTrue(pipeline.complete(request.handle));
        assertEquals(1, completions.get());
        // Everything else that can still arrive is harmless.
        assertFalse(pipeline.complete(request.handle));
        scheduler.fireEvenIfCancelled();
        pipeline.detach(owner);
        assertEquals(1, completions.get());
    }

    @Test
    public void theDeadlineCompletesWhenDartNeverReplies() {
        dispatch(Phase.AFTER, false);
        delivered();
        assertEquals(0, completions.get());
        scheduler.fireDue();
        assertEquals(1, completions.get());
        scheduler.fireEvenIfCancelled();
        assertEquals(1, completions.get());
    }

    @Test
    public void aLateReplyAfterTheDeadlineDoesNothing() {
        dispatch(Phase.AFTER, false);
        final ReportHandlerPipeline.Request request = delivered();
        scheduler.fireDue();
        assertEquals(1, completions.get());
        assertFalse("the handle is gone; Dart's late completion is a no-op",
                pipeline.complete(request.handle));
        assertEquals(1, completions.get());
    }

    @Test
    public void anUnreachableDartCompletesAtOnce() {
        dispatch(Phase.BEFORE, false);
        delivered();
        sink.unreachable.get(0).run();
        assertEquals(1, completions.get());
        sink.unreachable.get(0).run();
        scheduler.fireEvenIfCancelled();
        assertEquals(1, completions.get());
    }

    @Test
    public void aSinkThatThrowsCompletesAtOnce() {
        sink.throwOnDeliver = true;
        dispatch(Phase.BEFORE, false);
        platform.drain();
        assertEquals(1, completions.get());
    }

    @Test
    public void aPlatformThreadThatCannotQueueCompletesAtOnce() {
        platform.accept = false;
        dispatch(Phase.BEFORE, false);
        assertEquals(1, completions.get());
        platform.accept = true;
        platform.throwOnPost = true;
        dispatch(Phase.BEFORE, false);
        assertEquals(2, completions.get());
        assertNull(pipeline.reportFor("rh-1"));
        assertNull(pipeline.reportFor("rh-2"));
    }

    @Test
    public void aSchedulerThatThrowsCompletesAtOnceAndLeavesNoLiveProxy() {
        scheduler.throwOnSchedule = true;
        dispatch(Phase.BEFORE, false);
        assertEquals(1, completions.get());
        assertNull("a handle nobody will complete must not stay live", pipeline.reportFor("rh-1"));
    }

    @Test
    public void detachingTheEngineCompletesWhatWasHandedToIt() {
        dispatch(Phase.BEFORE, false);
        delivered();
        pipeline.detach(owner);
        assertEquals(1, completions.get());
        scheduler.fireEvenIfCancelled();
        assertEquals(1, completions.get());
    }

    @Test
    public void aDetachBeforeTheRequestReachedDartSkipsDelivery() {
        dispatch(Phase.BEFORE, false);
        pipeline.detach(owner);
        platform.drain();
        assertEquals(1, completions.get());
        assertTrue("Dart is never asked about a handle that is already over", sink.requests.isEmpty());
    }

    @Test
    public void aThrowingSdkCompletionNeverEscapes() {
        pipeline.dispatch(Phase.BEFORE, report, true, () -> {
            throw new IllegalStateException("sdk fault");
        });
        dispatch(Phase.BEFORE, false);
        delivered();
        final ReportHandlerPipeline pipelineThatThrows = pipeline;
        pipelineThatThrows.dispatch(Phase.AFTER, report, false, () -> {
            throw new IllegalStateException("sdk fault");
        });
        platform.drain();
        scheduler.fireDue();
    }

    @Test
    public void aNullReportAndANullCompletionNeverThrow() {
        pipeline.dispatch(Phase.BEFORE, null, false, completions::incrementAndGet);
        assertEquals(1, completions.get());
        pipeline.dispatch(Phase.BEFORE, report, false, null);
        pipeline.dispatch(Phase.AFTER, report, true, null);
    }

    @Test
    public void aReportThatThrowsWhenReadStillCompletesOnce() {
        state.idThrows = true;
        dispatch(Phase.BEFORE, false);
        assertEquals(0, completions.get());
        final ReportHandlerPipeline.Request request = delivered();
        assertEquals("", request.reportId);
        assertTrue(pipeline.complete(request.handle));
        assertEquals(1, completions.get());
    }

    // ---- when Dart is not asked ---------------------------------------------------------

    @Test
    public void terminatingNeverReachesDartAndCompletesAtOnce() {
        dispatch(Phase.BEFORE, true);
        dispatch(Phase.AFTER, true);
        assertEquals(2, completions.get());
        assertTrue(scheduler.tasks.isEmpty());
        assertTrue(platform.queue.isEmpty());
        platform.drain();
        assertTrue(sink.requests.isEmpty());
        assertEquals("nothing was read from the report either", Collections.emptyList(), state.calls);
    }

    @Test
    public void noRegisteredHandlerCompletesAtOnceWithoutWaiting() {
        pipeline.setPhases(owner, false, false);
        dispatch(Phase.BEFORE, false);
        dispatch(Phase.AFTER, false);
        assertEquals(2, completions.get());
        assertTrue(scheduler.tasks.isEmpty());
        assertTrue(platform.queue.isEmpty());
    }

    @Test
    public void onlyTheRegisteredPhaseReachesDart() {
        pipeline.setPhases(owner, false, true);
        dispatch(Phase.BEFORE, false);
        assertEquals(1, completions.get());
        dispatch(Phase.AFTER, false);
        assertEquals(1, completions.get());
        assertEquals(1, delivered().deadlineMs > 0 ? 1 : 0);
        assertTrue(delivered().after);
    }

    @Test
    public void noAttachedDartCompletesAtOnce() {
        pipeline.detach(owner);
        dispatch(Phase.BEFORE, false);
        assertEquals(1, completions.get());
    }

    @Test
    public void aDispatchTheSdkDoesNotWaitOnCompletesAtOnce() {
        // Early-crash recovery runs on a spawned thread, the SDK waits only for the handler
        // to return and the completion is a no-op, so a round trip cannot be waited for.
        for (final String name : new String[] {
                "bugsee-report-handler-bounded", "main", "BugseeBackground", "", null}) {
            thread.set(name);
            dispatch(Phase.AFTER, false);
        }
        assertEquals(5, completions.get());
        assertTrue(scheduler.tasks.isEmpty());
        assertTrue(platform.queue.isEmpty());
    }

    @Test
    public void aReportThatLooksLikeARecoveredCrashIsNotTreatedAsOne() {
        // 7.2.3: type + isTerminating say nothing about recovery. A crash-typed report on
        // the live path is delivered like any other, with its type passed through verbatim.
        state.type = com.bugsee.library.contracts.options.IssueType.Crash;
        dispatch(Phase.AFTER, false);
        final ReportHandlerPipeline.Request request = delivered();
        assertEquals("crash", request.type);
        assertEquals(0, completions.get());
    }

    // ---- the deadline is inside the SDK's ------------------------------------------------

    @Test
    public void theDefaultDeadlineIsInsideTheSdksThirtySeconds() {
        dispatch(Phase.BEFORE, false);
        assertEquals(1, scheduler.tasks.size());
        final long delay = scheduler.tasks.get(0).delayMs;
        assertEquals(25_000L, delay);
        assertTrue(delay < ReportHandlerDeadlines.SDK_DEFAULT_HANDLER_TIMEOUT_MS);
        assertEquals(delay, delivered().deadlineMs);
    }

    @Test
    public void theDeadlineFollowsTheOptionAndStaysInsideIt() {
        for (int seconds = 2; seconds <= 120; seconds++) {
            option.set(seconds);
            final ManualScheduler s = new ManualScheduler();
            final ReportHandlerPipeline p = new ReportHandlerPipeline(
                    s, platform, option::get, thread::get, log::add);
            p.attach(owner, sink);
            p.setPhases(owner, true, true);
            p.dispatch(Phase.BEFORE, report, false, () -> { });
            assertEquals(1, s.tasks.size());
            final long delay = s.tasks.get(0).delayMs;
            assertTrue("deadline " + delay + " must be inside the " + seconds + " s timeout",
                    delay < seconds * 1000L);
            assertTrue(delay <= ReportHandlerDeadlines.LIVE_DEADLINE_MS);
            assertTrue(delay >= ReportHandlerDeadlines.MIN_USEFUL_DEADLINE_MS);
        }
    }

    @Test
    public void anOptionTooShortForARoundTripCompletesAtOnce() {
        option.set(1);
        dispatch(Phase.BEFORE, false);
        assertEquals(1, completions.get());
        assertTrue(scheduler.tasks.isEmpty());
    }

    @Test
    public void anUnreadableOptionOrOneThatIsDisabledUsesTheDefault() {
        option.set(0);
        dispatch(Phase.BEFORE, false);
        assertEquals(25_000L, scheduler.tasks.get(0).delayMs);
        option.set(-5);
        dispatch(Phase.BEFORE, false);
        assertEquals(25_000L, scheduler.tasks.get(1).delayMs);
        final ReportHandlerPipeline throwing = new ReportHandlerPipeline(
                scheduler, platform, () -> {
                    throw new IllegalStateException("not launched");
                }, thread::get, log::add);
        throwing.attach(owner, sink);
        throwing.setPhases(owner, true, true);
        throwing.dispatch(Phase.BEFORE, report, false, () -> { });
        assertEquals(25_000L, scheduler.tasks.get(2).delayMs);
    }

    // ---- the proxy is live only until the completion runs (7.3.4) -------------------------

    @Test
    public void aMutationBeforeCompletionAppliesAndAfterItIsIgnored() throws Exception {
        dispatch(Phase.BEFORE, false);
        final ReportHandlerPipeline.Request request = delivered();
        assertTrue(pipeline.edit(request.handle, r -> r.setSummary("early")));
        assertEquals("early", state.summary);

        pipeline.complete(request.handle);
        assertFalse(pipeline.edit(request.handle, r -> r.setSummary("late")));
        assertEquals("early", state.summary);
        assertNull(pipeline.reportFor(request.handle));
    }

    @Test
    public void aMutationAfterTheDeadlineIsIgnoredToo() throws Exception {
        dispatch(Phase.BEFORE, false);
        final ReportHandlerPipeline.Request request = delivered();
        scheduler.fireDue();
        assertFalse(pipeline.edit(request.handle, r -> r.setSummary("late")));
        assertNull(state.summary);
        assertEquals(Collections.singletonList("getId"), onlyReads(state.calls));
    }

    private static List<String> onlyReads(final List<String> calls) {
        final List<String> reads = new ArrayList<>();
        for (final String c : calls) {
            if (c.startsWith("get") && !reads.contains(c)) {
                reads.add(c);
            }
        }
        reads.remove("getType");
        return reads;
    }

    @Test
    public void anUnknownHandleIsRefusedNotAnError() throws Exception {
        assertFalse(pipeline.edit("rh-999", r -> r.setSummary("x")));
        assertFalse(pipeline.edit(null, r -> r.setSummary("x")));
        assertNull(pipeline.reportFor("nope"));
    }

    @Test
    public void aBadArgumentChangesNothingAndLeavesTheHandleLive() throws Exception {
        dispatch(Phase.BEFORE, false);
        final ReportHandlerPipeline.Request request = delivered();
        try {
            pipeline.edit(request.handle, r -> ReportOps.setSeverity(r, 0));
            org.junit.Assert.fail();
        } catch (final ReportOps.BadArgument expected) {
            // refused
        }
        assertEquals(Collections.emptyList(), state.mutations());
        assertNotNull(pipeline.reportFor(request.handle));
    }

    // ---- identity of a delivery ----------------------------------------------------------

    @Test
    public void aDeliveryIdIsStableForOneReportAndPhaseAndTheHandleIsNot() {
        dispatch(Phase.AFTER, false);
        dispatch(Phase.AFTER, false);
        dispatch(Phase.BEFORE, false);
        platform.drain();
        final ReportHandlerPipeline.Request a = sink.requests.get(0);
        final ReportHandlerPipeline.Request b = sink.requests.get(1);
        final ReportHandlerPipeline.Request c = sink.requests.get(2);
        assertEquals("after:report-1", a.deliveryId);
        assertEquals(a.deliveryId, b.deliveryId);
        assertNotEquals(a.handle, b.handle);
        assertEquals("before:report-1", c.deliveryId);
        assertTrue(a.after);
        assertFalse(c.after);
    }

    @Test
    public void anUnreadableIdIsNeverShared() {
        state.idThrows = true;
        dispatch(Phase.AFTER, false);
        dispatch(Phase.AFTER, false);
        platform.drain();
        assertNotEquals(sink.requests.get(0).deliveryId, sink.requests.get(1).deliveryId);
    }

    // ---- several engines -----------------------------------------------------------------

    @Test
    public void theMostRecentEngineWithAHandlerGetsTheDelivery() {
        final Object second = new Object();
        final RecordingSink secondSink = new RecordingSink();
        pipeline.attach(second, secondSink);
        pipeline.setPhases(second, true, false);
        dispatch(Phase.BEFORE, false);
        platform.drain();
        assertEquals(1, secondSink.requests.size());
        assertTrue(sink.requests.isEmpty());
        dispatch(Phase.AFTER, false);
        platform.drain();
        assertEquals("the second engine has no after handler; the first does", 1, sink.requests.size());
    }

    @Test
    public void detachingOneEngineLeavesTheOthersHandlesAlone() {
        final Object second = new Object();
        final RecordingSink secondSink = new RecordingSink();
        pipeline.attach(second, secondSink);
        pipeline.setPhases(second, true, true);
        dispatch(Phase.BEFORE, false);
        platform.drain();
        pipeline.detach(owner);
        assertEquals("the handle belongs to the second engine", 0, completions.get());
        pipeline.detach(second);
        assertEquals(1, completions.get());
    }

    // ---- threads ---------------------------------------------------------------------------

    /**
     * The deadlock the design exists to avoid. The "platform thread" is a single thread that
     * must run Dart's reply. If a dispatch waited for that reply while ON that thread (iOS
     * calls handlers on main; Android's crash paths can), nothing could ever deliver it. Here
     * the dispatch runs ON the platform thread and the reply is queued behind it.
     */
    @Test(timeout = 10_000)
    public void dispatchingOnThePlatformThreadItselfNeverWaitsForDart() throws Exception {
        final ExecutorService main = Executors.newSingleThreadExecutor();
        try {
            final CountDownLatch completed = new CountDownLatch(1);
            final AtomicReference<String> handle = new AtomicReference<>();
            final ReportHandlerPipeline p = new ReportHandlerPipeline(
                    scheduler,
                    task -> {
                        main.execute(task);
                        return true;
                    },
                    option::get, thread::get, log::add);
            // "Dart": answers on the platform thread, as the real reply is delivered there.
            p.attach(owner, (request, unreachable) -> {
                handle.set(request.handle);
                main.execute(() -> p.complete(request.handle));
            });
            p.setPhases(owner, true, true);

            final Future<Boolean> returnedBeforeCompletion = main.submit(() -> {
                final long start = System.nanoTime();
                p.dispatch(Phase.BEFORE, report, false, completed::countDown);
                final long elapsedMs = (System.nanoTime() - start) / 1_000_000L;
                // A wait that gave up after a timeout would still "return", so time it.
                return completed.getCount() == 1 && elapsedMs < 500;
            });
            assertTrue("dispatch returned at once, before the completion ran",
                    returnedBeforeCompletion.get(5, TimeUnit.SECONDS));
            assertTrue("and Dart's reply, queued on the same thread, then completed it",
                    completed.await(5, TimeUnit.SECONDS));
        } finally {
            main.shutdownNow();
        }
    }

    /** The SDK's own thread is never held up by a busy or blocked platform thread either. */
    @Test(timeout = 10_000)
    public void aBlockedPlatformThreadDoesNotBlockTheSdkThread() throws Exception {
        final ExecutorService main = Executors.newSingleThreadExecutor();
        final CountDownLatch release = new CountDownLatch(1);
        try {
            main.execute(() -> {
                try {
                    release.await();
                } catch (final InterruptedException ignored) {
                    Thread.currentThread().interrupt();
                }
            });
            final ReportHandlerPipeline p = new ReportHandlerPipeline(
                    scheduler, task -> {
                        main.execute(task);
                        return true;
                    }, option::get, thread::get, log::add);
            p.attach(owner, sink);
            p.setPhases(owner, true, true);
            final CountDownLatch done = new CountDownLatch(1);
            final ExecutorService sdk = Executors.newSingleThreadExecutor();
            try {
                final long start = System.nanoTime();
                sdk.submit(() -> p.dispatch(Phase.BEFORE, report, false, done::countDown))
                        .get(5, TimeUnit.SECONDS);
                assertTrue("the SDK thread was not held up",
                        (System.nanoTime() - start) / 1_000_000L < 500);
            } finally {
                sdk.shutdownNow();
            }
            assertEquals("the SDK thread came back while main was still blocked", 1, done.getCount());
            // The deadline still ends it, with main blocked the whole time.
            scheduler.fireDue();
            assertTrue(done.await(5, TimeUnit.SECONDS));
        } finally {
            release.countDown();
            main.shutdownNow();
        }
    }

    @Test(timeout = 20_000)
    public void everyRaceForTheCompletionRunsItOnce() throws Exception {
        final int rounds = 100;
        final ExecutorService pool = Executors.newFixedThreadPool(4);
        try {
            for (int i = 0; i < rounds; i++) {
                final ManualScheduler s = new ManualScheduler();
                final AtomicInteger ran = new AtomicInteger();
                final ReportHandlerPipeline p = new ReportHandlerPipeline(
                        s, task -> {
                            task.run();
                            return true;
                        }, option::get, thread::get, log::add);
                final RecordingSink rs = new RecordingSink();
                final Object o = new Object();
                p.attach(o, rs);
                p.setPhases(o, true, true);
                p.dispatch(Phase.BEFORE, report, false, ran::incrementAndGet);
                final String handle = rs.requests.get(0).handle;
                final CountDownLatch go = new CountDownLatch(1);
                final List<Future<?>> all = new ArrayList<>();
                all.add(pool.submit(() -> { await(go); p.complete(handle); }));
                all.add(pool.submit(() -> { await(go); s.fireEvenIfCancelled(); }));
                all.add(pool.submit(() -> { await(go); p.detach(o); }));
                all.add(pool.submit(() -> { await(go); rs.unreachable.get(0).run(); }));
                go.countDown();
                for (final Future<?> f : all) {
                    f.get(5, TimeUnit.SECONDS);
                }
                assertEquals("round " + i, 1, ran.get());
            }
        } finally {
            pool.shutdownNow();
        }
    }

    private static void await(final CountDownLatch latch) {
        try {
            latch.await();
        } catch (final InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    // ---- the outcome is logged -------------------------------------------------------------

    @Test
    public void everyOutcomeIsOneLogLine() {
        dispatch(Phase.BEFORE, true);
        assertEquals(1, log.size());
        assertTrue(log.get(0).contains("completed by=terminating"));
        dispatch(Phase.AFTER, false);
        delivered();
        pipeline.complete(sink.requests.get(0).handle);
        assertTrue(log.get(log.size() - 1).contains("completed by=dart"));
    }
}
