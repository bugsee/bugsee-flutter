package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.reporting.Report;

import org.junit.Test;

import java.io.Serializable;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

public class CreatedReportOpsTest {

    private final FakeReports.State state = new FakeReports.State();
    private final Report report = FakeReports.create(state);

    private void assertBad(final CreatedReportOps.Patch patch) {
        try {
            CreatedReportOps.apply(report, patch);
            fail("expected BadArgument");
        } catch (final ReportOps.BadArgument expected) {
            // Nothing may have changed.
        }
        assertEquals(Collections.<String>emptyList(), state.mutations());
    }

    @Test
    public void aSummaryOfNullClearsItAndAnAbsentOneLeavesIt() throws Exception {
        state.summary = "old";
        state.description = "old d";
        final CreatedReportOps.Patch clear = new CreatedReportOps.Patch();
        clear.setSummary = true;
        CreatedReportOps.apply(report, clear);
        assertEquals(null, state.summary);
        assertEquals("the description was not part of the patch", "old d", state.description);
    }

    @Test
    public void severityCrossesByValueAndLabelsAreReplacedInOneCall() throws Exception {
        final CreatedReportOps.Patch p = new CreatedReportOps.Patch();
        p.severity = 4L;
        p.labels = Arrays.asList("a", "b");
        CreatedReportOps.apply(report, p);
        assertEquals(IssueSeverity.Critical, state.severity);
        assertEquals(Arrays.asList("a", "b"), state.labels);
        assertTrue(state.calls.contains("setLabels"));
        assertTrue("never clear-then-add", !state.calls.contains("clearLabels") && !state.calls.contains("addLabels"));
    }

    @Test
    public void oneBadFieldChangesNothingAtAll() {
        final CreatedReportOps.Patch bad = new CreatedReportOps.Patch();
        bad.setSummary = true;
        bad.summary = "would be applied";
        bad.severity = 9L;
        assertBad(bad);

        final CreatedReportOps.Patch badLabels = new CreatedReportOps.Patch();
        badLabels.setSummary = true;
        badLabels.labels = Arrays.asList("ok", 3);
        assertBad(badLabels);

        final CreatedReportOps.Patch badValue = new CreatedReportOps.Patch();
        badValue.setSummary = true;
        final Map<String, Object> attrs = new LinkedHashMap<>();
        attrs.put("fine", 1);
        attrs.put("bad", Double.NaN);
        badValue.attributes = attrs;
        assertBad(badValue);

        final CreatedReportOps.Patch badName = new CreatedReportOps.Patch();
        badName.setSummary = true;
        badName.removeAttributes = Arrays.asList("x", "");
        assertBad(badName);
    }

    @Test
    public void attributesAreClearedThenSetThenRemoved() throws Exception {
        state.attributes.put("old", "x");
        state.attributes.put("gone", "y");
        final CreatedReportOps.Patch p = new CreatedReportOps.Patch();
        p.clearAttributes = true;
        final Map<String, Object> attrs = new LinkedHashMap<>();
        attrs.put("a", 1);
        attrs.put("b", "two");
        attrs.put("gone", true);
        p.attributes = attrs;
        p.removeAttributes = Arrays.asList("gone");
        CreatedReportOps.apply(report, p);
        final Map<String, Serializable> expected = new LinkedHashMap<>();
        expected.put("a", 1);
        expected.put("b", "two");
        assertEquals(expected, state.attributes);
    }

    @Test
    public void readNamesTheAttachmentsAndTheScreenshotDisplays() throws Exception {
        ReportOps.addBytes(report, new byte[1], "x.txt", null);
        state.screenshots.put(0, new Object[] {new Object(), Boolean.FALSE});
        final CreatedReportOps.Snapshot s = CreatedReportOps.read(report);
        assertEquals("report-1", s.id);
        assertEquals("bug", s.type);
        assertEquals(Arrays.asList("x.txt"), s.attachmentNames);
        assertEquals(Arrays.asList(0), s.screenshotDisplayIds);
    }

    @Test
    public void discardDeletesTheAppsAttachmentsAndNeverThrows() throws Exception {
        ReportOps.addBytes(report, new byte[1], "x.txt", null);
        CreatedReportOps.discard(report);
        assertEquals(0, state.attachments.size());
        CreatedReportOps.discard(null);
        CreatedReportOps.discard((Report) java.lang.reflect.Proxy.newProxyInstance(
                Report.class.getClassLoader(), new Class<?>[] {Report.class},
                (p, m, a) -> {
                    throw new IllegalStateException("boom");
                }));
    }
}
