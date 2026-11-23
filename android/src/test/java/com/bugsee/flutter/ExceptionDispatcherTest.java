package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * The SDK call for a Dart error runs off the calling (platform) thread, in order, with a bounded
 * queue that drops and counts (an unhandled report is written by the SDK on the calling thread: a
 * snapshot of the capture ring, up to a couple of seconds).
 */
public class ExceptionDispatcherTest {

    private static final class Recorder implements ExceptionDispatcher.Done {
        final List<String> events = Collections.synchronizedList(new ArrayList<>());
        final CountDownLatch done;

        Recorder(final int expected) {
            done = new CountDownLatch(expected);
        }

        @Override
        public void success(final boolean handedToSdk) {
            events.add("success:" + handedToSdk);
            done.countDown();
        }

        @Override
        public void failure(final String code, final String message) {
            events.add("failure:" + code);
            done.countDown();
        }

        void await() throws InterruptedException {
            assertTrue("completed", done.await(10, TimeUnit.SECONDS));
        }
    }

    private static void hold(final CountDownLatch latch) {
        try {
            latch.await(10, TimeUnit.SECONDS);
        } catch (final InterruptedException e) {
            throw new IllegalStateException(e);
        }
    }

    @Test
    public void theTaskRunsOnAnotherThreadThanTheCaller() throws Exception {
        final ExceptionDispatcher dispatcher = new ExceptionDispatcher(4);
        final Thread caller = Thread.currentThread();
        final Thread[] ranOn = new Thread[1];
        final Recorder recorder = new Recorder(1);
        dispatcher.submit(() -> {
            ranOn[0] = Thread.currentThread();
            return true;
        }, recorder);
        recorder.await();
        assertNotEquals("not the calling thread", caller, ranOn[0]);
        assertEquals("bugsee-flutter-exceptions", ranOn[0].getName());
        assertTrue("a daemon: it never keeps the process alive", ranOn[0].isDaemon());
        assertEquals(Collections.singletonList("success:true"), recorder.events);
    }

    @Test
    public void theCallerIsNotBlockedWhileTheSdkIsBusy() throws Exception {
        final ExceptionDispatcher dispatcher = new ExceptionDispatcher(4);
        final CountDownLatch release = new CountDownLatch(1);
        final Recorder recorder = new Recorder(1);
        final long start = System.nanoTime();
        dispatcher.submit(() -> {
            hold(release);
            return true;
        }, recorder);
        // submit returned although the task is still waiting: the caller was not held.
        assertTrue(TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - start) < 5);
        assertEquals(1, recorder.done.getCount());
        release.countDown();
        recorder.await();
    }

    @Test
    public void callsRunInOrder() throws Exception {
        final ExceptionDispatcher dispatcher = new ExceptionDispatcher(8);
        final List<Integer> order = Collections.synchronizedList(new ArrayList<>());
        final Recorder recorder = new Recorder(5);
        for (int i = 0; i < 5; i++) {
            final int n = i;
            dispatcher.submit(() -> {
                order.add(n);
                return true;
            }, recorder);
        }
        recorder.await();
        assertEquals(java.util.Arrays.asList(0, 1, 2, 3, 4), order);
    }

    @Test
    public void aFullQueueDropsTheCallCountsItAndAnswersFalse() throws Exception {
        final ExceptionDispatcher dispatcher = new ExceptionDispatcher(2);
        final CountDownLatch started = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final Recorder first = new Recorder(3);
        // One running (held), two queued: the queue is full.
        dispatcher.submit(() -> {
            started.countDown();
            hold(release);
            return true;
        }, first);
        assertTrue(started.await(10, TimeUnit.SECONDS));
        dispatcher.submit(() -> true, first);
        dispatcher.submit(() -> true, first);
        assertEquals(0, dispatcher.dropped());

        final Recorder dropped = new Recorder(1);
        dispatcher.submit(() -> {
            throw new AssertionError("a dropped call must not run");
        }, dropped);
        // Answered at once, "not handed to the SDK", and counted.
        assertEquals(Collections.singletonList("success:false"), dropped.events);
        assertEquals(1, dispatcher.dropped());

        release.countDown();
        first.await();
        assertEquals(java.util.Arrays.asList("success:true", "success:true", "success:true"), first.events);
    }

    @Test
    public void aFailureIsReportedWithItsCodeAndTheThreadLivesOn() throws Exception {
        final ExceptionDispatcher dispatcher = new ExceptionDispatcher(4);
        final Recorder recorder = new Recorder(3);
        dispatcher.submit(() -> {
            throw new FacadeOps.Failure(FacadeOps.INVALID_ARGUMENT, "bad");
        }, recorder);
        dispatcher.submit(() -> {
            throw new IllegalStateException("carries user data");
        }, recorder);
        dispatcher.submit(() -> true, recorder);
        recorder.await();
        assertEquals(java.util.Arrays.asList("failure:invalid-argument", "failure:sdk-error", "success:true"),
                recorder.events);
    }

    @Test
    public void theSharedDispatcherIsOneAndBoundedAtTheDocumentedCapacity() {
        assertEquals(ExceptionDispatcher.shared(), ExceptionDispatcher.shared());
        assertEquals(32, ExceptionDispatcher.QUEUE_CAPACITY);
    }
}
