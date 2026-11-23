package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.IssueType;
import com.bugsee.library.contracts.reporting.Report;

import org.junit.Test;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;

public class ReportOpsTest {

    private final FakeReports.State state = new FakeReports.State();
    private final Report report = FakeReports.create(state);

    private void assertBad(final ReportHandlerPipeline.Edit edit) {
        try {
            edit.apply(report);
            fail("expected BadArgument");
        } catch (final ReportOps.BadArgument expected) {
            // The refusal is the point; what matters next is that nothing changed.
        }
        assertEquals(Collections.<String>emptyList(), state.mutations());
    }

    @Test
    public void severityCrossesByValueNeverByOrdinal() throws Exception {
        for (int wire = 1; wire <= 5; wire++) {
            ReportOps.setSeverity(report, wire);
            assertEquals(wire, state.severity.getValue());
        }
        // Critical is ordinal 3 and value 4.
        ReportOps.setSeverity(report, 4);
        assertEquals(IssueSeverity.Critical, state.severity);
        assertEquals(3, IssueSeverity.Critical.ordinal());
        assertEquals(Integer.valueOf(4), ReportOps.read(report).severity);
    }

    @Test
    public void severityOutsideTheSdkRangeIsRefusedNotCoerced() {
        // IssueSeverity.fromIntValue maps all of these to VeryLow, silently.
        for (final long wire : new long[] {0, -1, 6, 100, Long.MAX_VALUE, Long.MIN_VALUE}) {
            assertBad(r -> ReportOps.setSeverity(r, wire));
        }
    }

    @Test
    public void severityRangeIsExactlyTheSdksValues() {
        final HashSet<Integer> values = new HashSet<>();
        for (final IssueSeverity s : IssueSeverity.values()) {
            values.add(s.getValue());
        }
        assertEquals(new HashSet<>(Arrays.asList(1, 2, 3, 4, 5)), values);
        assertEquals(ReportOps.MIN_SEVERITY, Collections.min(values).intValue());
        assertEquals(ReportOps.MAX_SEVERITY, Collections.max(values).intValue());
    }

    @Test
    public void typeIsTheWireStringNotTheEnumName() {
        for (final IssueType t : IssueType.values()) {
            state.type = t;
            assertEquals(t.toString(), ReportOps.typeOf(report));
        }
        state.type = IssueType.Crash;
        assertEquals("crash", ReportOps.typeOf(report));
        assertEquals("Crash", IssueType.Crash.name());
    }

    @Test
    public void replacingLabelsIsOneAtomicCall() throws Exception {
        state.labels.addAll(Arrays.asList("old"));
        ReportOps.replaceLabels(report, Arrays.asList("a", "b"));
        assertEquals(Arrays.asList("a", "b"), state.labels);
        // clear-then-add would expose a label-less report between the two calls.
        assertEquals(Collections.singletonList("setLabels"), state.mutations());
    }

    @Test
    public void aListThatIsNotAllStringsChangesNothing() {
        state.labels.add("keep");
        assertBad(r -> ReportOps.replaceLabels(r, Arrays.asList("a", 3)));
        assertBad(r -> ReportOps.replaceLabels(r, Arrays.asList("a", null)));
        assertBad(r -> ReportOps.addLabels(r, Arrays.asList(1.5)));
        assertBad(r -> ReportOps.replaceLabels(r, null));
        assertEquals(Collections.singletonList("keep"), state.labels);
    }

    @Test
    public void attributesTakeOnlyWhatBothSdksCarry() throws Exception {
        ReportOps.setAttribute(report, "s", "text");
        ReportOps.setAttribute(report, "b", true);
        ReportOps.setAttribute(report, "i", 7);
        ReportOps.setAttribute(report, "l", 7_000_000_000L);
        ReportOps.setAttribute(report, "d", 1.5);
        assertEquals(5, state.attributes.size());
        state.calls.clear();
        assertBad(r -> ReportOps.setAttribute(r, "n", Double.NaN));
        assertBad(r -> ReportOps.setAttribute(r, "n", Double.POSITIVE_INFINITY));
        assertBad(r -> ReportOps.setAttribute(r, "n", new HashSet<>(Arrays.asList("x"))));
        assertBad(r -> ReportOps.setAttribute(r, "n", Arrays.asList("x")));
        assertBad(r -> ReportOps.setAttribute(r, "n", null));
        assertBad(r -> ReportOps.setAttribute(r, "", "v"));
        assertBad(r -> ReportOps.setAttribute(r, null, "v"));
        assertEquals(5, state.attributes.size());
    }

    @Test
    public void readReturnsTheLiveReportAndLeavesUnsupportedAttributesOut() {
        state.summary = "s";
        state.description = "d";
        state.email = "e@x";
        state.severity = IssueSeverity.Blocker;
        state.labels.addAll(Arrays.asList("l1", "l2"));
        state.attributes.put("ok", "v");
        state.attributes.put("set", new HashSet<>(Arrays.asList("a")));
        state.attributes.put("nan", Double.NaN);
        final ReportOps.Snapshot s = ReportOps.read(report);
        assertEquals("report-1", s.id);
        assertEquals("bug", s.type);
        assertEquals("s", s.summary);
        assertEquals("d", s.description);
        assertEquals("e@x", s.email);
        assertEquals(Integer.valueOf(5), s.severity);
        assertEquals(Arrays.asList("l1", "l2"), s.labels);
        assertEquals(Collections.singletonMap("ok", "v"), s.attributes);
        assertNull(new FakeReportsHelper().emptyRead().summary);
    }

    @Test
    public void attributeValueRule() {
        assertTrue(ReportOps.isAllowedAttributeValue("x"));
        assertTrue(ReportOps.isAllowedAttributeValue(false));
        assertTrue(ReportOps.isAllowedAttributeValue(1));
        assertFalse(ReportOps.isAllowedAttributeValue(null));
        assertFalse(ReportOps.isAllowedAttributeValue(new Object()));
    }

    /** A fresh report with nothing set. */
    private static final class FakeReportsHelper {
        ReportOps.Snapshot emptyRead() {
            return ReportOps.read(FakeReports.create(new FakeReports.State()));
        }
    }
}
