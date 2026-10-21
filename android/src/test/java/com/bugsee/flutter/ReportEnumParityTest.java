package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.IssueType;

import org.junit.Test;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Compares the fixture {@code test/fixtures/report_enums.json} (extracted from the SDK SOURCE by
 * {@code scripts/extract_report_enums.dart}) with the REAL enums of the pinned
 * {@code bugsee-android}, loaded here from the artifact. Together with
 * {@code test/report_enum_parity_test.dart}, which compares the fixture with the iOS values, the
 * Dart enums and the Java/ObjC copies, this makes a divergence in either SDK visible (workbook
 * 7.4.2, 7.4.3). By value, never by ordinal.
 */
public class ReportEnumParityTest {

    private static String fixture() throws Exception {
        // Unit tests run with the module (android/) as the working directory.
        final File file = new File(new File("").getAbsoluteFile().getParentFile(),
                "test/fixtures/report_enums.json");
        return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
    }

    /** The object that follows {@code "key": {} } in the fixture, as name -> raw value text. */
    private static Map<String, String> block(final String json, final String key) {
        final Matcher outer = Pattern.compile("\"" + key + "\"\\s*:\\s*\\{([^}]*)\\}").matcher(json);
        assertTrue("fixture has " + key, outer.find());
        final Map<String, String> result = new LinkedHashMap<>();
        final Matcher entry = Pattern.compile("\"(\\w+)\"\\s*:\\s*(\"[^\"]*\"|-?\\d+)")
                .matcher(outer.group(1));
        while (entry.find()) {
            result.put(entry.group(1), entry.group(2).replace("\"", ""));
        }
        return result;
    }

    @Test
    public void severityIsTheSdksByValue() throws Exception {
        final Map<String, String> expected = block(fixture(), "IssueSeverity");
        final Map<String, String> actual = new LinkedHashMap<>();
        for (final IssueSeverity s : IssueSeverity.values()) {
            actual.put(s.name(), Integer.toString(s.getValue()));
        }
        assertEquals(expected, actual);
    }

    @Test
    public void issueTypeIsTheSdksWireString() throws Exception {
        final Map<String, String> expected = block(fixture(), "IssueType");
        final Map<String, String> actual = new LinkedHashMap<>();
        for (final IssueType t : IssueType.values()) {
            actual.put(t.name(), t.toString());
        }
        assertEquals(expected, actual);
    }

    @Test
    public void theMappingTheWrapperUsesRoundTripsEveryValue() throws Exception {
        for (final IssueSeverity s : IssueSeverity.values()) {
            assertEquals(s, ReportOps.severity(s.getValue()));
        }
    }
}
