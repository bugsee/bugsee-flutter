package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class ReportHandlerDeadlinesTest {

    @Test
    public void liveDeadlineSitsInsideTheSdksDefault() {
        assertEquals(20_000L, ReportHandlerDeadlines.liveMs(null));
        assertEquals(20_000L, ReportHandlerDeadlines.liveMs(0));
        assertEquals(20_000L, ReportHandlerDeadlines.liveMs(-1));
        assertEquals(20_000L, ReportHandlerDeadlines.liveMs(30));
        assertTrue(ReportHandlerDeadlines.LIVE_DEADLINE_MS
                < ReportHandlerDeadlines.SDK_DEFAULT_HANDLER_TIMEOUT_MS);
    }

    @Test
    public void aShorterOptionShortensTheDeadlineAndALongerOneDoesNotLengthenIt() {
        // The margin is a third of the SDK's budget, at most 10 s.
        assertEquals(6_667L, ReportHandlerDeadlines.liveMs(10));
        assertEquals(1_334L, ReportHandlerDeadlines.liveMs(2));
        assertEquals(667L, ReportHandlerDeadlines.liveMs(1));
        assertEquals(20_000L, ReportHandlerDeadlines.liveMs(120));
    }

    @Test
    public void theMarginIsAThirdOfTheBudgetAtMostTenSeconds() {
        assertEquals(10_000L, ReportHandlerDeadlines.marginMs(30_000L));
        assertEquals(10_000L, ReportHandlerDeadlines.marginMs(120_000L));
        assertEquals(1_000L, ReportHandlerDeadlines.marginMs(3_000L));
        assertEquals(0L, ReportHandlerDeadlines.marginMs(0L));
        assertEquals(ReportHandlerDeadlines.LIVE_DEADLINE_MS,
                ReportHandlerDeadlines.SDK_DEFAULT_HANDLER_TIMEOUT_MS
                        - ReportHandlerDeadlines.marginMs(ReportHandlerDeadlines.SDK_DEFAULT_HANDLER_TIMEOUT_MS));
    }

    @Test
    public void whatIsLeftOfAWindowNeverGoesNegative() {
        assertEquals(15_000L, ReportHandlerDeadlines.remainingMs(20_000L, 5_000L));
        assertEquals(0L, ReportHandlerDeadlines.remainingMs(20_000L, 20_000L));
        assertEquals(0L, ReportHandlerDeadlines.remainingMs(20_000L, 99_000L));
        assertEquals("a clock that went backwards costs nothing",
                20_000L, ReportHandlerDeadlines.remainingMs(20_000L, -5L));
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
        assertEquals(20_000L, ReportHandlerDeadlines.deadlineMs(
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
