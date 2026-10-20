package com.bugsee.flutter;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.internal.BugseeWrapper;

import org.junit.Test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
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
        final Matcher m = Pattern.compile("(?m)^version:\\s*(\\S+)\\s*$").matcher(text);
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
    public void lifecycleEventIsANoOp() {
        final FlutterWrapper w = FlutterWrapper.atProcessStart();
        w.onLifecycleEvent("com.bugsee.lifecycle.Launched", null);
        w.onLifecycleEvent("unknown-future-event", new Object());
    }

    @Test
    public void secureRectanglesAreEmptyWithTheUnknownVersion() {
        final int[] a = FlutterWrapper.atProcessStart().getSecureRectangles(0);
        assertEquals(2, a.length);
        assertEquals("a constant real version would be cached by the SDK and could "
                + "mask a replacement wrapper's rectangles",
                BugseeWrapper.SECURE_RECTANGLES_VERSION_UNKNOWN, a[0]);
        assertEquals("count", 0, a[1]);
        assertArrayEquals(a, FlutterWrapper.atProcessStart().getSecureRectangles(3));
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
