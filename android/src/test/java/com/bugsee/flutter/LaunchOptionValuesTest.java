package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.options.FrameRate;
import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.LogLevel;
import com.bugsee.library.contracts.options.VideoMode;
import com.bugsee.library.contracts.options.VideoQuality;

import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;

import java.io.File;
import java.io.Serializable;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;

/**
 * The Android half of the option translation (workbook Part 8), against the vendored Android
 * manifest ({@code test/fixtures/option_manifests/android.json}, the SDK's own published
 * manifest) and the REAL enums of the pinned {@code bugsee-android}.
 *
 * <p>The reason this class exists is that the SDK drops a number given for an enum option: so the
 * table of enum options has to be complete and exact, and each of these tests breaks when it is
 * not.
 */
public class LaunchOptionValuesTest {

    private static final Set<String> BUNDLED = new HashSet<>(
            java.util.Arrays.asList("bugsee-android", "bugsee-android-ndk"));

    private static JSONObject manifest() throws Exception {
        // Unit tests run with the module (android/) as the working directory.
        final File file = new File(new File("").getAbsoluteFile().getParentFile(),
                "test/fixtures/option_manifests/android.json");
        return new JSONObject(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8));
    }

    /** Enum option key to its manifest {@code values}, for the modules this plugin bundles. */
    private static Map<String, JSONObject> enumOptions() throws Exception {
        final Map<String, JSONObject> result = new HashMap<>();
        final JSONArray options = manifest().getJSONArray("options");
        for (int i = 0; i < options.length(); i++) {
            final JSONObject option = options.getJSONObject(i);
            if (option.has("enum") && BUNDLED.contains(option.getString("module"))) {
                result.put(option.getString("key"), option.getJSONObject("enum").getJSONObject("values"));
            }
        }
        return result;
    }

    @Test
    public void theTableHasAnEntryForEveryEnumOptionOfTheBundledModulesAndNothingElse() throws Exception {
        assertEquals(enumOptions().keySet(), LaunchOptionValues.ENUM_OPTIONS.keySet());
        assertEquals("the manifest has 7 such options at 7.4.2", 7, enumOptions().size());
    }

    @Test
    public void everyManifestValueIsTheSdkConstantOfThatNameAndValue() throws Exception {
        for (final Map.Entry<String, JSONObject> option : enumOptions().entrySet()) {
            final LaunchOptionValues.EnumCodec codec = LaunchOptionValues.ENUM_OPTIONS.get(option.getKey());
            final JSONObject values = option.getValue();
            final Iterator<String> names = values.keys();
            int count = 0;
            Class<?> enumClass = null;
            while (names.hasNext()) {
                final String name = names.next();
                final int value = values.getInt(name);
                final Object constant = codec.fromValue(value);
                assertNotNull(option.getKey() + " has no constant for " + value, constant);
                assertEquals(option.getKey() + " value " + value, name, ((Enum<?>) constant).name());
                assertEquals(Integer.valueOf(value), codec.toValue(constant));
                enumClass = ((Enum<?>) constant).getDeclaringClass();
                count++;
            }
            // The SDK has no constant the manifest lacks (the manifest comes from its registry).
            assertEquals(option.getKey(), count, enumClass.getEnumConstants().length);
        }
    }

    @Test
    public void aNumberIsAnInternalValueNeverAnOrdinal() {
        // VideoMode: Fullscreen is value 20 at ordinal 3; 3 is NOT Fullscreen (nor anything).
        assertEquals(VideoMode.Fullscreen,
                LaunchOptionValues.toSdk(map("com.bugsee.option.capture.video.mode", 20))
                        .get("com.bugsee.option.capture.video.mode"));
        assertNull(LaunchOptionValues.toSdk(map("com.bugsee.option.capture.video.mode", 3))
                .get("com.bugsee.option.capture.video.mode"));
        // LogLevel.Error is value 1 at ordinal 0; value 0 is nothing.
        assertEquals(LogLevel.Error,
                LaunchOptionValues.toSdk(map("com.bugsee.option.capture.logs.level", 1))
                        .get("com.bugsee.option.capture.logs.level"));
        assertNull(LaunchOptionValues.toSdk(map("com.bugsee.option.capture.logs.level", 0))
                .get("com.bugsee.option.capture.logs.level"));
        // FrameRate.Raw is value 4 (Android only).
        assertEquals(FrameRate.Raw,
                LaunchOptionValues.toSdk(map("com.bugsee.option.capture.video.frame-rate", 4L))
                        .get("com.bugsee.option.capture.video.frame-rate"));
        assertEquals(VideoQuality.Default,
                LaunchOptionValues.toSdk(map("com.bugsee.option.capture.video.quality", 0))
                        .get("com.bugsee.option.capture.video.quality"));
        assertEquals(IssueSeverity.Blocker,
                LaunchOptionValues.toSdk(map("com.bugsee.option.reporting.defaults.crash-priority", 5))
                        .get("com.bugsee.option.reporting.defaults.crash-priority"));
    }

    @Test
    public void everythingElseIsPassedAsItIs() {
        final Map<String, Object> flat = new HashMap<>();
        flat.put("com.bugsee.option.capture.logs", Boolean.TRUE);
        flat.put("com.bugsee.option.config.duration", 45);
        flat.put("com.bugsee.option.capture.video.scale", 0.5d);
        flat.put("com.bugsee.option.config.build-type", "debug");
        flat.put("com.bugsee.option.detect.memory_leaks.mode", "DEEP_DEBUG_ONLY");
        flat.put("com.bugsee.option.capture.network", null);
        flat.put("not-a-string-key-ish", new Object());
        final Map<String, Serializable> out = LaunchOptionValues.toSdk(flat);
        assertEquals(Boolean.TRUE, out.get("com.bugsee.option.capture.logs"));
        assertEquals(45, out.get("com.bugsee.option.config.duration"));
        assertEquals(0.5d, out.get("com.bugsee.option.capture.video.scale"));
        assertEquals("debug", out.get("com.bugsee.option.config.build-type"));
        assertEquals("DEEP_DEBUG_ONLY", out.get("com.bugsee.option.detect.memory_leaks.mode"));
        assertFalse(out.containsKey("com.bugsee.option.capture.network"));
        assertFalse(out.containsKey("not-a-string-key-ish"));
        assertTrue(LaunchOptionValues.toSdk(null).isEmpty());
    }

    @Test
    public void theEndpointKeyReachesTheSdkUntouched() {
        // Both SDKs read the hidden com.bugsee.option.$$ENDPOINT, without the API version.
        final Map<String, Serializable> out = LaunchOptionValues.toSdk(
                map("com.bugsee.option.$$ENDPOINT", "https://bugsee.example.com"));
        assertEquals("https://bugsee.example.com", out.get("com.bugsee.option.$$ENDPOINT"));
        assertEquals(1, out.size());
    }

    // ---- what the SDK reports back ----
    //
    // The SDK's own option container cannot be built in a plain JUnit run (its registry needs an
    // Android runtime: the same call throws a NullPointerException inside it), so what the SDK
    // does with this map is shown on a device instead (PLAN.md, Phase 4a runtime verification);
    // here the enum constants are the real ones of the pinned SDK.

    @Test
    public void theReadBackIsTheSameIntegersAndOnlyPrimitives() {
        final Map<String, Serializable> sdk = new HashMap<>();
        sdk.put("com.bugsee.option.capture.video.mode", VideoMode.DirectBuffers);
        sdk.put("com.bugsee.option.capture.logs.level", LogLevel.Verbose);
        sdk.put("com.bugsee.option.capture.video.frame-rate", FrameRate.Raw);
        sdk.put("com.bugsee.option.reporting.defaults.crash-priority", IssueSeverity.Blocker);
        sdk.put("com.bugsee.option.capture.video.scale", 0.5f);
        sdk.put("com.bugsee.option.config.duration", 33);
        sdk.put("com.bugsee.option.capture.logs", Boolean.TRUE);
        sdk.put("com.bugsee.option.config.build-type", "debug");
        sdk.put("com.bugsee.option.$$ENDPOINT", null);
        sdk.put("com.bugsee.option.$$WRAPPER", new HashMap<String, String>());
        final Map<String, Object> back = LaunchOptionValues.fromSdk(sdk);
        assertEquals(21, back.get("com.bugsee.option.capture.video.mode"));
        assertEquals(5, back.get("com.bugsee.option.capture.logs.level"));
        assertEquals(4, back.get("com.bugsee.option.capture.video.frame-rate"));
        assertEquals(5, back.get("com.bugsee.option.reporting.defaults.crash-priority"));
        assertEquals(0.5d, back.get("com.bugsee.option.capture.video.scale"));
        assertEquals(33, back.get("com.bugsee.option.config.duration"));
        assertEquals(Boolean.TRUE, back.get("com.bugsee.option.capture.logs"));
        assertEquals("debug", back.get("com.bugsee.option.config.build-type"));
        assertFalse("a null is left out", back.containsKey("com.bugsee.option.$$ENDPOINT"));
        assertFalse("a map is not a primitive", back.containsKey("com.bugsee.option.$$WRAPPER"));
        for (final Map.Entry<String, Object> e : back.entrySet()) {
            final Object v = e.getValue();
            assertTrue(e.getKey() + " is " + v.getClass(), v instanceof Boolean || v instanceof String
                    || v instanceof Integer || v instanceof Long || v instanceof Double);
        }
    }

    @Test
    public void anEnumOfAModuleTheTableDoesNotKnowIsReportedByItsToString() {
        // bugsee-android-leak's string-valued enum: not in the table (the module is not bundled).
        final Map<String, Serializable> sdk = new HashMap<>();
        sdk.put("com.bugsee.option.detect.memory_leaks.mode", java.util.concurrent.TimeUnit.SECONDS);
        assertEquals("SECONDS", LaunchOptionValues.fromSdk(sdk).get("com.bugsee.option.detect.memory_leaks.mode"));
    }

    private static Map<String, Object> map(final String key, final Object value) {
        final Map<String, Object> m = new HashMap<>();
        m.put(key, value);
        return m;
    }
}
