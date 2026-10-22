package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.exchange.NetworkEvent;

import org.junit.Test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * The network wire fixture ({@code test/fixtures/network_wire.json}) against the REAL enums of the
 * pinned {@code bugsee-android}, loaded from the artifact: every stage Dart sends is the SDK's own
 * stage, by its wire name, and every reason Dart sends is one the SDK's enum has, by value. Together
 * with {@code test/network_drift_test.dart} (the fixture against the Dart and the native copies)
 * this makes a divergence in either place visible.
 */
public class NetworkWireParityTest {

    private static String fixture() throws Exception {
        // Unit tests run with the module (android/) as the working directory.
        final File file = new File(new File("").getAbsoluteFile().getParentFile(),
                "test/fixtures/network_wire.json");
        return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
    }

    private static Map<String, String> block(final String json, final String key) {
        final Matcher outer = Pattern.compile("\"" + key + "\"\\s*:\\s*\\{([^}]*)\\}").matcher(json);
        assertTrue("fixture has " + key, outer.find());
        final Map<String, String> result = new LinkedHashMap<>();
        final Matcher entry = Pattern.compile("\"(\\w+)\"\\s*:\\s*\"([^\"]*)\"")
                .matcher(outer.group(1));
        while (entry.find()) {
            result.put(entry.group(1), entry.group(2));
        }
        return result;
    }

    @Test
    public void everyStageDartSendsIsTheSdksOwnByItsWireName() throws Exception {
        final Map<String, String> stages = block(fixture(), "androidStageEnum");
        assertEquals(new ArrayList<>(stages.keySet()), NetworkOps.stageNames());
        for (final Map.Entry<String, String> stage : stages.entrySet()) {
            final NetworkEvent.NetworkEventStage real = NetworkOps.stageOf(stage.getKey());
            assertNotNull(stage.getKey(), real);
            assertEquals(stage.getValue(), real.name());
            assertEquals(stage.getKey(), real.toString());
        }
    }

    @Test
    public void everyReasonDartSendsIsOneTheSdkHas() throws Exception {
        final Map<String, String> reasons = block(fixture(), "noBodyReasons");
        final List<String> sdk = new ArrayList<>();
        for (final NetworkEvent.NetworkBodyAbsenceReason r : NetworkEvent.NetworkBodyAbsenceReason.values()) {
            if (r.getValue() != null) {
                sdk.add(r.getValue());
            }
        }
        for (final String wire : reasons.values()) {
            assertTrue(wire + " is not a reason of the SDK: " + sdk, sdk.contains(wire));
            assertEquals(wire, NetworkOps.reasonOf(wire).getValue());
        }
    }

    @Test
    public void theMaximumAgeIsTheFixtures() throws Exception {
        final Matcher m = Pattern.compile("\"maxAgeMs\"\\s*:\\s*(\\d+)").matcher(fixture());
        assertTrue(m.find());
        assertEquals(Long.parseLong(m.group(1)), NetworkOps.MAX_AGE_MS);
    }
}
