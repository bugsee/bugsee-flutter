package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class ReportHandlerDeadlinesTest {

    @Test
    public void liveDeadlineSitsInsideTheSdksDefault() {
        assertEquals(25_000L, ReportHandlerDeadlines.liveMs(null));
        assertEquals(25_000L, ReportHandlerDeadlines.liveMs(0));
        assertEquals(25_000L, ReportHandlerDeadlines.liveMs(-1));
        assertEquals(25_000L, ReportHandlerDeadlines.liveMs(30));
        assertTrue(ReportHandlerDeadlines.LIVE_DEADLINE_MS
                < ReportHandlerDeadlines.SDK_DEFAULT_HANDLER_TIMEOUT_MS);
    }

    @Test
    public void aShorterOptionShortensTheDeadlineAndALongerOneDoesNotLengthenIt() {
        assertEquals(9_000L, ReportHandlerDeadlines.liveMs(10));
        assertEquals(1_000L, ReportHandlerDeadlines.liveMs(2));
        assertEquals(0L, ReportHandlerDeadlines.liveMs(1));
        assertEquals(25_000L, ReportHandlerDeadlines.liveMs(120));
    }

    @Test
    public void onlyTheSdksDispatchThreadIsTheWaitedForPath() {
        assertTrue(ReportHandlerDeadlines.isLive("BugseeReportHandlerThread"));
        assertFalse(ReportHandlerDeadlines.isLive("bugsee-report-handler-bounded"));
        assertFalse(ReportHandlerDeadlines.isLive("main"));
        assertFalse(ReportHandlerDeadlines.isLive(null));
    }

    @Test
    public void terminatingAndUnawaitedPathsGetNoDartRoundTrip() {
        assertEquals(0L, ReportHandlerDeadlines.deadlineMs(
                ReportHandlerDeadlines.LIVE_HANDLER_THREAD, true, null));
        assertEquals(0L, ReportHandlerDeadlines.deadlineMs("bugsee-report-handler-bounded", false, null));
        assertEquals(0L, ReportHandlerDeadlines.deadlineMs(
                ReportHandlerDeadlines.LIVE_HANDLER_THREAD, false, 1));
        assertEquals(25_000L, ReportHandlerDeadlines.deadlineMs(
                ReportHandlerDeadlines.LIVE_HANDLER_THREAD, false, null));
    }

    /**
     * The thread name is what tells the waited-for path from the others, so it must be the
     * SDK's. The constant is read from the SDK when it is accessible, and the test says so
     * when it is not rather than passing vacuously.
     */
    @Test
    public void theThreadNameIsTheSdksConstant() throws Exception {
        final Class<?> handlers;
        try {
            handlers = Class.forName("com.bugsee.library.shared.threading.BugseeHandlers");
        } catch (final ClassNotFoundException | LinkageError e) {
            throw new AssertionError("the SDK's BugseeHandlers is not on the test classpath: " + e);
        }
        assertEquals(ReportHandlerDeadlines.LIVE_HANDLER_THREAD,
                handlers.getField("REPORT_HANDLER_THREAD_NAME").get(null));
    }
}
