package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.internal.LogSource;
import com.bugsee.library.contracts.options.LogLevel;

import org.junit.Test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The log wire fixture ({@code test/fixtures/log_wire.json}) against the REAL enums of the pinned
 * {@code bugsee-android}, loaded from the artifact: the source the wrapper claims is the SDK's
 * {@code Custom}, 98, and not one the SDK reserves; every level Dart sends is the SDK's own, by value.
 * Together with {@code test/logs_drift_test.dart} (the fixture against the Dart and the native
 * copies) a divergence in either place is visible.
 */
public class LogWireParityTest {

    private static String fixture() throws Exception {
        // Unit tests run with the module (android/) as the working directory.
        final File file = new File(new File("").getAbsoluteFile().getParentFile(),
                "test/fixtures/log_wire.json");
        return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
    }

    private static Map<String, String> strings(final String json, final String key) {
        final Matcher outer = Pattern.compile("\"" + key + "\"\\s*:\\s*\\{([^}]*)\\}").matcher(json);
        assertTrue("fixture has " + key, outer.find());
        final Map<String, String> result = new LinkedHashMap<>();
        final Matcher entry = Pattern.compile("\"(\\w+)\"\\s*:\\s*\"([^\"]*)\"").matcher(outer.group(1));
        while (entry.find()) {
            result.put(entry.group(1), entry.group(2));
        }
        return result;
    }

    private static Map<String, Integer> numbers(final String json, final String key) {
        final Matcher outer = Pattern.compile("\"" + key + "\"\\s*:\\s*\\{([^}]*)\\}").matcher(json);
        assertTrue("fixture has " + key, outer.find());
        final Map<String, Integer> result = new LinkedHashMap<>();
        final Matcher entry = Pattern.compile("\"(\\w+)\"\\s*:\\s*(\\d+)").matcher(outer.group(1));
        while (entry.find()) {
            result.put(entry.group(1), Integer.valueOf(entry.group(2)));
        }
        return result;
    }

    private static int number(final String json, final String key) {
        final Matcher m = Pattern.compile("\"" + key + "\"\\s*:\\s*(\\d+)").matcher(json);
        assertTrue("fixture has " + key, m.find());
        return Integer.parseInt(m.group(1));
    }

    @Test
    public void theSourceTheWrapperClaimsIsTheSdksCustom98() throws Exception {
        final String json = fixture();
        assertEquals(number(json, "source"), LogSource.Custom.getValue());
        assertSame(LogSource.Custom, LogOps.WRAPPER_SOURCE);
        assertEquals("Custom", LogOps.WRAPPER_SOURCE.name());
    }

    @Test
    public void theSourceIsNotOneTheSdkKeepsForItself() {
        // BugseeWrapperChannelImpl.toWrapperSource accepts Custom, WebView, StdOut, StdErr and
        // Unknown and records everything else as Custom; claiming a reserved one would be coerced
        // (and reported) and Bugsee in particular is the app's own Bugsee.log.
        for (final LogSource reserved
                : new LogSource[] {LogSource.Bugsee, LogSource.Internal, LogSource.LogCat}) {
            assertTrue(reserved != LogOps.WRAPPER_SOURCE);
        }
        assertEquals(4, LogSource.Bugsee.getValue());
        assertEquals(99, LogSource.Internal.getValue());
        assertEquals(3, LogSource.LogCat.getValue());
    }

    @Test
    public void everyLevelDartSendsIsTheSdksOwnByValue() throws Exception {
        final String json = fixture();
        final Map<String, Integer> levels = numbers(json, "levels");
        final Map<String, String> names = strings(json, "androidLevelEnum");
        assertEquals(5, levels.size());
        for (final Map.Entry<String, Integer> level : levels.entrySet()) {
            final LogLevel real = LogLevel.fromRawValue(level.getValue().byteValue());
            assertNotNull(level.getKey(), real);
            assertEquals(names.get(level.getKey()), real.name());
            assertEquals(level.getValue().intValue(), real.getValue());
        }
    }

    @Test
    public void theRangeNativeAcceptsIsExactlyTheSdksRange() throws Exception {
        final String json = fixture();
        assertEquals(number(json, "minLevel"), LogOps.MIN_LEVEL);
        assertEquals(number(json, "maxLevel"), LogOps.MAX_LEVEL);
        assertNull(LogLevel.fromRawValue((byte) (LogOps.MIN_LEVEL - 1)));
        assertNotNull(LogLevel.fromRawValue((byte) LogOps.MIN_LEVEL));
        assertNotNull(LogLevel.fromRawValue((byte) LogOps.MAX_LEVEL));
        assertNull(LogLevel.fromRawValue((byte) (LogOps.MAX_LEVEL + 1)));
    }
}
