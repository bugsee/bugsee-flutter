package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.After;
import org.junit.Test;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

public class LifecycleHubTest {

    private static final String P = "com.bugsee.lifecycle.";

    /** Delivery runs inline; the threading test below uses a real executor. */
    private static LifecycleHub inline() {
        return new LifecycleHub(Runnable::run);
    }

    private static List<LifecycleHub.Event> collect(final LifecycleHub hub) {
        final List<LifecycleHub.Event> seen = new ArrayList<>();
        hub.attach(seen::add);
        return seen;
    }

    private final List<ExecutorService> executors = new ArrayList<>();

    @After
    public void shutdown() {
        for (final ExecutorService e : executors) {
            e.shutdownNow();
        }
    }

    @Test
    public void stripsThePrefixExactlyOnce() {
        assertEquals("Launched", LifecycleHub.parse(P + "Launched", null).name);
        // A second prefix is part of the name; stripping twice would corrupt it.
        assertEquals(P + "Launched", LifecycleHub.parse(P + P + "Launched", null).name);
    }

    @Test
    public void unknownNamesAreForwardedUnchanged() {
        final LifecycleHub hub = inline();
        final List<LifecycleHub.Event> seen = collect(hub);
        hub.dispatch(P + "SomethingNewerSdks Add", null);
        hub.dispatch("no.prefix.at.all", null);
        hub.dispatch("", null);
        hub.dispatch(P, null); // the bare prefix: nothing to strip down to
        assertEquals(4, seen.size());
        assertEquals("SomethingNewerSdks Add", seen.get(0).name);
        assertEquals("no.prefix.at.all", seen.get(1).name);
        assertEquals("", seen.get(2).name);
        assertEquals(P, seen.get(3).name);
    }

    @Test
    public void everyRealSdkNameIsForwardedIncludingFeedbackOnes() {
        final String[] names = {
                "Launching", "Launched", "Stopping", "Stopped", "BlackoutStarted",
                "BlackoutEnded", "RelaunchedAfterCrash", "BeforeReportShown",
                "AfterReportShown", "BeforeReportAssembled", "AfterReportAssembled",
                "ReportAssemblyFailed", "BeforeReportUploaded", "AfterReportUploaded",
                "ReportUploadFailed", "ReportUploadFailedWithFutureRetry",
                // bugsee-android feedback module (FeedbackLifecycleEvents)
                "BeforeFeedbackShown", "AfterFeedbackShown"};
        final LifecycleHub hub = inline();
        final List<LifecycleHub.Event> seen = collect(hub);
        for (final String n : names) {
            hub.dispatch(P + n, null);
        }
        assertEquals(names.length, seen.size());
        for (int i = 0; i < names.length; i++) {
            assertEquals(names[i], seen.get(i).name);
        }
    }

    @Test
    public void onlyTheReportEventsCarryAReportId() {
        final String[] carrying = {
                "BeforeReportAssembled", "AfterReportAssembled", "ReportAssemblyFailed",
                "BeforeReportUploaded", "AfterReportUploaded", "ReportUploadFailed",
                "ReportUploadFailedWithFutureRetry"};
        for (final String n : carrying) {
            assertEquals(n, "r-1", LifecycleHub.parse(P + n, "r-1").reportId);
        }
        // The same payload on any other event is not a report id.
        for (final String n : new String[] {"Launched", "BeforeReportShown", "Whatever"}) {
            assertNull(n, LifecycleHub.parse(P + n, "r-1").reportId);
        }
        assertNull(LifecycleHub.parse(P + "AfterReportUploaded", null).reportId);
        // Carried as is, never interpreted (empty, odd ids included).
        assertEquals("", LifecycleHub.parse(P + "AfterReportUploaded", "").reportId);
    }

    @Test
    public void dataKeepsOnlyStringToStringEntries() {
        final Map<Object, Object> raw = new HashMap<>();
        raw.put("a", "1");
        raw.put("n", 2);
        raw.put(3, "x");
        raw.put("nul", null);
        final LifecycleHub.Event e = LifecycleHub.parse(P + "Future", raw);
        assertEquals(Collections.singletonMap("a", "1"), e.data);
        assertNull(LifecycleHub.parse(P + "Future", Collections.singletonMap("n", 1)).data);
        assertNull(LifecycleHub.parse(P + "Future", new Object()).data);
        assertNull(LifecycleHub.parse(P + "Future", null).data);
    }

    @Test
    public void eventsBeforeAttachAreBufferedAndFlushedInOrder() {
        final LifecycleHub hub = inline();
        hub.dispatch(P + "Launching", null);
        hub.dispatch(P + "Launched", null);
        assertEquals(2, hub.bufferedCount());
        final List<LifecycleHub.Event> seen = collect(hub);
        assertEquals(0, hub.bufferedCount());
        assertEquals("Launching", seen.get(0).name);
        assertEquals("Launched", seen.get(1).name);
        hub.dispatch(P + "Stopping", null);
        assertEquals("Stopping", seen.get(2).name);
    }

    @Test
    public void bufferIsBoundedAndDropsTheOldest() {
        final LifecycleHub hub = inline();
        final int extra = 5;
        for (int i = 0; i < LifecycleHub.BUFFER_CAPACITY + extra; i++) {
            hub.dispatch(P + "E" + i, null);
        }
        assertEquals(LifecycleHub.BUFFER_CAPACITY, hub.bufferedCount());
        assertEquals(extra, hub.droppedCount());
        final List<LifecycleHub.Event> seen = collect(hub);
        assertEquals(LifecycleHub.BUFFER_CAPACITY, seen.size());
        assertEquals("the oldest were dropped", "E" + extra, seen.get(0).name);
        assertEquals("E" + (LifecycleHub.BUFFER_CAPACITY + extra - 1),
                seen.get(seen.size() - 1).name);
    }

    @Test
    public void capacityIsTheDocumentedOne() {
        assertEquals(64, LifecycleHub.BUFFER_CAPACITY);
    }

    @Test
    public void detachedHubBuffersAgainAndAStaleDetachIsIgnored() {
        final LifecycleHub hub = inline();
        final List<LifecycleHub.Event> first = new ArrayList<>();
        final List<LifecycleHub.Event> second = new ArrayList<>();
        final LifecycleHub.Sink a = first::add;
        final LifecycleHub.Sink b = second::add;
        hub.attach(a);
        hub.attach(b); // a second engine
        hub.detach(a); // the first engine goes away: must not silence b
        hub.dispatch(P + "Launched", null);
        assertEquals(0, first.size());
        assertEquals(1, second.size());
        hub.detach(b);
        hub.dispatch(P + "Stopped", null);
        assertEquals(1, second.size());
        assertEquals(1, hub.bufferedCount());
    }

    /** Workbook 4.4: events arrive off the main thread; the sink must be on it. */
    @Test
    public void deliveryHopsToTheMainThread() throws Exception {
        final ExecutorService main = single("fake-main");
        final ExecutorService sdk = single("sdk-worker");
        final LifecycleHub hub = new LifecycleHub(work -> main.execute(work));
        final AtomicReference<String> sinkThread = new AtomicReference<>();
        final AtomicReference<String> sinkSaw = new AtomicReference<>();
        hub.attach(e -> {
            sinkThread.set(Thread.currentThread().getName());
            sinkSaw.set(e.name);
        });
        final Future<String> dispatchedOn = sdk.submit(() -> {
            hub.dispatch(P + "Launched", null);
            return Thread.currentThread().getName();
        });
        assertEquals("sdk-worker", dispatchedOn.get(5, TimeUnit.SECONDS));
        // Drain the fake main thread.
        main.submit(() -> {}).get(5, TimeUnit.SECONDS);
        assertEquals("Launched", sinkSaw.get());
        assertEquals("fake-main", sinkThread.get());
        assertNotEquals(dispatchedOn.get(), sinkThread.get());
    }

    @Test
    public void flushAndLiveEventsStayInOrderAcrossTheHop() throws Exception {
        final ExecutorService main = single("fake-main");
        final LifecycleHub hub = new LifecycleHub(work -> main.execute(work));
        hub.dispatch(P + "A", null);
        hub.dispatch(P + "B", null);
        final List<String> seen = Collections.synchronizedList(new ArrayList<String>());
        hub.attach(e -> seen.add(e.name));
        hub.dispatch(P + "C", null);
        main.submit(() -> {}).get(5, TimeUnit.SECONDS);
        assertEquals(java.util.Arrays.asList("A", "B", "C"), seen);
    }

    @Test
    public void aSinkThatThrowsDoesNotBreakTheNextEventOrTheCaller() {
        final LifecycleHub hub = inline();
        final List<String> seen = new ArrayList<>();
        hub.attach(e -> {
            seen.add(e.name);
            throw new IllegalStateException("dead engine");
        });
        hub.dispatch(P + "A", null);
        hub.dispatch(P + "B", null);
        assertEquals(java.util.Arrays.asList("A", "B"), seen);
    }

    @Test
    public void dispatchNeverThrowsOnNull() {
        final LifecycleHub hub = inline();
        hub.dispatch(null, null);
        assertEquals(0, hub.bufferedCount());
    }

    @Test
    public void anEventPostedBeforeDetachButRunAfterIsKeptNotLost() throws Exception {
        final List<Runnable> queue = new ArrayList<>();
        final LifecycleHub hub = new LifecycleHub(queue::add);
        final List<String> seen = new ArrayList<>();
        final LifecycleHub.Sink sink = e -> seen.add(e.name);
        hub.attach(sink);
        hub.dispatch(P + "Launched", null);
        hub.detach(sink); // engine torn down before the main thread got to it
        for (final Runnable r : queue) {
            r.run();
        }
        assertTrue(seen.isEmpty());
        assertEquals(1, hub.bufferedCount());
    }

    private ExecutorService single(final String name) {
        final ThreadFactory f = r -> new Thread(r, name);
        final ExecutorService e = Executors.newSingleThreadExecutor(f);
        executors.add(e);
        return e;
    }
}
