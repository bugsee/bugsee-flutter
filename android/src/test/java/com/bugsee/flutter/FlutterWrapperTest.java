package com.bugsee.flutter;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.internal.BugseeWrapper;

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
                "flutter", "1", null, null, hub, new SecureRectangleStore());
        w.onLifecycleEvent("com.bugsee.lifecycle.Launched", null);
        w.onLifecycleEvent("unknown-future-event", new Object());
        assertEquals(2, seen.size());
        assertEquals("Launched", seen.get(0).name);
        assertEquals("unknown-future-event", seen.get(1).name);
        // The default (process-wide) hub also copes with anything.
        FlutterWrapper.atProcessStart().onLifecycleEvent("x", null);
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
            final int[] set = {7, 1, 10, 20, 30, 40};
            store.publish(0, set);
            final FlutterWrapper placeholder = FlutterWrapper.atProcessStart();
            assertArrayEquals(set, placeholder.getSecureRectangles(0));
            final FlutterWrapper refined = FlutterWrapper.create(
                    "flutter", "1.0.0", null, Collections.singletonMap("flutter", "3.41.0"));
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
            store.publish(2, new int[] {9, 1, 1, 2, 3, 4});
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
            assertArrayEquals(new int[] {9, 1, 1, 2, 3, 4}, first.getSecureRectangles(2));
            assertArrayEquals(new int[] {9, 1, 1, 2, 3, 4}, second.getSecureRectangles(2));
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

    @Test
    public void reportHandlersCompleteImmediately() {
        final FlutterWrapper w = FlutterWrapper.atProcessStart();
        final AtomicInteger done = new AtomicInteger();
        w.onBeforeReportCreated(null, false, done::incrementAndGet);
        w.onAfterReportCreated(null, true, done::incrementAndGet);
        assertEquals(2, done.get());
    }
}
