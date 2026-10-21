package com.bugsee.flutter;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.internal.BugseeWrapper;
import com.bugsee.library.contracts.reporting.Report;

import org.junit.Test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class FlutterWrapperTest {

    @Test
    public void processStartIdentityIsTypeAndVersionOnly() {
        final FlutterWrapper w = FlutterWrapper.atProcessStart();
        assertEquals("flutter", w.getWrapperType());
        assertEquals(BuildConfig.WRAPPER_VERSION, w.getWrapperVersion());
        assertNull(w.getWrapperBuild());
        assertTrue(w.getContext().isEmpty());
    }

    /** The version baked in by build.gradle is the one in pubspec.yaml. */
    @Test
    public void buildConfigVersionMatchesPubspec() throws Exception {
        // Unit tests run with the module (android/) as the working directory.
        final File pubspec = new File(new File("").getAbsoluteFile().getParentFile(), "pubspec.yaml");
        final String text = new String(Files.readAllBytes(pubspec.toPath()), StandardCharsets.UTF_8);
        final Matcher m = Pattern.compile("(?m)^version:[ \\t]*(?!#)(\\S+)[ \\t]*(?:#.*)?$").matcher(text);
        assertTrue(m.find());
        assertEquals(m.group(1), BuildConfig.WRAPPER_VERSION);
    }

    @Test
    public void missingFactsAreUnknownNotEmpty() {
        final FlutterWrapper w = FlutterWrapper.create(null, "", null, null);
        assertEquals("unknown", w.getWrapperType());
        assertEquals("unknown", w.getWrapperVersion());
        assertTrue(w.getContext().isEmpty());
    }

    @Test
    public void contextDropsNonStringsRatherThanStringifyingThem() {
        final Map<Object, Object> raw = new HashMap<>();
        raw.put("flutter", "3.41.0");
        raw.put("count", 3);
        raw.put("nul", null);
        raw.put(7, "numeric key");
        final Map<String, String> ctx = FlutterWrapper.create("flutter", "1", "b", raw).getContext();
        assertEquals(1, ctx.size());
        assertEquals("3.41.0", ctx.get("flutter"));
    }

    @Test
    public void requestDataAnswersNullForEveryTypeAndNeverThrows() {
        final FlutterWrapper w = FlutterWrapper.atProcessStart();
        for (final String type : new String[] {"vh", "", "something-new"}) {
            final AtomicInteger calls = new AtomicInteger();
            final AtomicReference<String> got = new AtomicReference<>("sentinel");
            w.requestData(type, data -> {
                calls.incrementAndGet();
                got.set(data);
            });
            assertEquals(1, calls.get());
            assertNull(got.get());
        }
        // A throwing callback must not escape.
        w.requestData("vh", data -> {
            throw new IllegalStateException("callback failed");
        });
    }

    @Test
    public void lifecycleEventsGoToTheHubAndNeverThrow() {
        final List<LifecycleHub.Event> seen = new ArrayList<>();
        final LifecycleHub hub = new LifecycleHub(Runnable::run);
        hub.attach(seen::add);
        final FlutterWrapper w = FlutterWrapper.create(
                "flutter", "1", null, null, hub,
                new SecureRectangleStore(SecureRectangleStore.UNKNOWN_ENVIRONMENT));
        w.onLifecycleEvent("com.bugsee.lifecycle.Launched", null);
        w.onLifecycleEvent("unknown-future-event", new Object());
        assertEquals(2, seen.size());
        assertEquals("Launched", seen.get(0).name);
        assertEquals("unknown-future-event", seen.get(1).name);
        // The default (process-wide) hub also copes with anything.
        FlutterWrapper.atProcessStart().onLifecycleEvent("x", null);
    }

    private static final class FixedEnvironment implements SecureRectangleStore.Environment {
        @Override
        public double nativePixelRatio(final int display) {
            return 3;
        }

        @Override
        public double unitsPerPhysicalPixel(final int display) {
            return 1;
        }

        @Override
        public int[] displayBounds(final int display) {
            return new int[] {1080, 2400};
        }
    }

    private static void publishOnDisplay(final SecureRectangleStore store, final int display) {
        store.setEnvironment(new FixedEnvironment());
        store.setPlacement(1, 0, SecureRectangleStore.Placement.known(display, 0, 0));
        store.publish(1, 1, 1, Collections.singletonMap(0,
                new SecureRectangleStore.ViewRects(3, new double[] {10, 20, 30, 40})));
    }

    /**
     * Workbook 5.4.2: the wrapper is replaced when Dart refines the identity;
     * what it serves must not live in it.
     */
    @Test
    public void replacingTheWrapperKeepsTheSecureRectangleSet() {
        final SecureRectangleStore store = SecureRectangleStore.shared();
        store.clearForTests();
        try {
            publishOnDisplay(store, 0);
            final int[] set = {1, 1, 30, 60, 90, 120};
            final FlutterWrapper placeholder = FlutterWrapper.atProcessStart();
            assertArrayEquals(set, placeholder.getSecureRectangles(0));
            final FlutterWrapper refined = FlutterWrapper.create(
                    "flutter", "1.0.0", null, Collections.singletonMap("flutter", "3.41.0"));
            assertNotSame(placeholder, refined);
            assertArrayEquals(set, refined.getSecureRectangles(0));
            // Other displays are unaffected.
            assertEquals(0, refined.getSecureRectangles(1)[1]);
        } finally {
            store.clearForTests();
        }
    }

    /** The same through the real replacement path, with the SDK call recorded. */
    @Test
    public void refiningTheIdentityReplacesTheWrapperAndKeepsTheSet() {
        final SecureRectangleStore store = SecureRectangleStore.shared();
        store.clearForTests();
        try {
            publishOnDisplay(store, 2);
            final List<BugseeWrapper> registered = new ArrayList<>();
            FlutterWrapperInitProvider.registerEarly(registered::add);
            final Map<String, String> ctx = new HashMap<>();
            ctx.put("flutter", "3.41.0");
            assertTrue(FlutterWrapperInitProvider.registerRefined(
                    registered::add, "flutter", "1.2.3", "dbg", ctx));
            assertEquals(2, registered.size());
            final BugseeWrapper first = registered.get(0);
            final BugseeWrapper second = registered.get(1);
            assertNotSame(first, second);
            assertNull(first.getWrapperBuild());
            assertEquals("1.2.3", second.getWrapperVersion());
            assertEquals("dbg", second.getWrapperBuild());
            assertEquals("3.41.0", second.getContext().get("flutter"));
            final int[] set = {1, 1, 30, 60, 90, 120};
            assertArrayEquals(set, first.getSecureRectangles(2));
            assertArrayEquals(set, second.getSecureRectangles(2));
            // A change after the replacement reaches the SDK through the new wrapper, and
            // moves the version it sees.
            store.publish(1, 1, 2, Collections.singletonMap(0,
                    new SecureRectangleStore.ViewRects(3, new double[] {10, 20, 31, 40})));
            final int[] changed = second.getSecureRectangles(2);
            assertEquals(2, changed[0]);
            assertEquals(93, changed[4]);
        } finally {
            store.clearForTests();
        }
    }

    /** Both the placeholder and the refined wrapper must feed the SAME process-wide hub. */
    @Test
    public void everyWrapperFeedsTheSharedHub() {
        final LifecycleHub shared = LifecycleHub.shared();
        final List<BugseeWrapper> registered = new ArrayList<>();
        FlutterWrapperInitProvider.registerEarly(registered::add);
        FlutterWrapperInitProvider.registerRefined(
                registered::add, "flutter", "1", null, Collections.singletonMap("a", "b"));
        for (final BugseeWrapper w : registered) {
            // No receiver is attached in a unit test, so the event lands in the buffer
            // (or, when that is full, in the drop counter).
            final int before = shared.bufferedCount() + shared.droppedCount();
            w.onLifecycleEvent("com.bugsee.lifecycle.Launched", null);
            assertEquals(before + 1, shared.bufferedCount() + shared.droppedCount());
        }
    }

    @Test
    public void refiningNeverThrowsEvenWhenTheSdkDoes() {
        assertFalse(FlutterWrapperInitProvider.registerRefined(
                w -> {
                    throw new LinkageError("no SDK");
                }, "flutter", "1", null, null));
    }

    @Test
    public void refinedIdentityWithMissingFactsIsUnknown() {
        final List<BugseeWrapper> registered = new ArrayList<>();
        FlutterWrapperInitProvider.registerRefined(registered::add, null, "", null, "not a map");
        assertEquals("unknown", registered.get(0).getWrapperType());
        assertEquals("unknown", registered.get(0).getWrapperVersion());
        assertTrue(registered.get(0).getContext().isEmpty());
    }

    /** With no Dart handler registered (the default), the SDK is never left waiting. */
    @Test
    public void reportHandlersCompleteImmediatelyWhenNoDartHandlerIsRegistered() {
        final FlutterWrapper w = FlutterWrapper.atProcessStart();
        final AtomicInteger done = new AtomicInteger();
        w.onBeforeReportCreated(null, false, done::incrementAndGet);
        w.onAfterReportCreated(null, true, done::incrementAndGet);
        final Report report = FakeReports.create(new FakeReports.State());
        w.onBeforeReportCreated(report, false, done::incrementAndGet);
        w.onAfterReportCreated(report, false, done::incrementAndGet);
        w.onAfterReportCreated(report, true, done::incrementAndGet);
        assertEquals(5, done.get());
    }

    /** The wrapper is replaced when Dart refines the identity; its answers must not change. */
    @Test
    public void theReplacedWrapperAnswersDataRequestsToo() {
        final List<BugseeWrapper> registered = new ArrayList<>();
        FlutterWrapperInitProvider.registerRefined(
                registered::add, "flutter", "1.2.3", null, Collections.singletonMap("a", "b"));
        final BugseeWrapper refined = registered.get(0);
        for (final String type : new String[] {"vh", "", "something-new"}) {
            final AtomicInteger calls = new AtomicInteger();
            final AtomicReference<String> got = new AtomicReference<>("sentinel");
            refined.requestData(type, data -> {
                calls.incrementAndGet();
                got.set(data);
            });
            assertEquals(type, 1, calls.get());
            assertNull(type, got.get());
        }
        refined.requestData("vh", data -> {
            throw new IllegalStateException("callback failed");
        });
        // A null callback (never expected from the SDK) must not escape either.
        refined.requestData("vh", null);
    }

    /**
     * The report handlers go through the pipeline of the wrapper that was handed in, so a
     * replacement wrapper shares the process-wide one (the engine's Dart end is not in it).
     */
    @Test
    public void everyWrapperRoutesReportHandlersThroughItsPipeline() {
        final List<String> seen = new ArrayList<>();
        final ReportHandlerPipeline pipeline = new ReportHandlerPipeline(
                (task, delay) -> () -> { },
                task -> {
                    task.run();
                    return true;
                },
                () -> null,
                () -> ReportHandlerDeadlines.LIVE_HANDLER_THREAD,
                seen::add);
        final Object owner = new Object();
        final List<ReportHandlerPipeline.Request> requests = new ArrayList<>();
        pipeline.attach(owner, (request, unreachable) -> requests.add(request));
        pipeline.setPhases(owner, true, true);
        final FlutterWrapper w = FlutterWrapper.create(
                "flutter", "1", null, null, LifecycleHub.shared(),
                new SecureRectangleStore(SecureRectangleStore.UNKNOWN_ENVIRONMENT), pipeline);
        final Report report = FakeReports.create(new FakeReports.State());
        final AtomicInteger done = new AtomicInteger();
        w.onBeforeReportCreated(report, false, done::incrementAndGet);
        w.onAfterReportCreated(report, false, done::incrementAndGet);
        assertEquals("both reached Dart and neither is complete", 2, requests.size());
        assertEquals(0, done.get());
        assertFalse(requests.get(0).after);
        assertTrue(requests.get(1).after);
        // Terminating never reaches Dart, whatever is registered.
        w.onBeforeReportCreated(report, true, done::incrementAndGet);
        assertEquals(1, done.get());
        assertEquals(2, requests.size());
        pipeline.complete(requests.get(0).handle);
        pipeline.complete(requests.get(1).handle);
        assertEquals(3, done.get());
    }
}
