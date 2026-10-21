package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.reporting.Report;

import org.junit.Test;

import java.util.ArrayList;
import java.util.List;

/**
 * The slot a created report lives in: one at a time, a deadline at every stage, and a stamp on every
 * reservation so a late SDK answer can never take a newer reservation's place.
 */
public class CreatedReportsTest {

    private static final class Manual implements ReportHandlerPipeline.Scheduler {
        static final class Task implements ReportHandlerPipeline.Cancellable {
            final Runnable runnable;
            final long delayMs;
            boolean cancelled;

            Task(final Runnable runnable, final long delayMs) {
                this.runnable = runnable;
                this.delayMs = delayMs;
            }

            @Override
            public void cancel() {
                cancelled = true;
            }
        }

        final List<Task> tasks = new ArrayList<>();

        @Override
        public ReportHandlerPipeline.Cancellable schedule(final Runnable task, final long delayMs) {
            final Task t = new Task(task, delayMs);
            tasks.add(t);
            return t;
        }

        Task last() {
            return tasks.get(tasks.size() - 1);
        }
    }

    private static final class Recorder implements CreatedReports.Expiry {
        int timedOut;
        final List<Report> expired = new ArrayList<>();

        @Override
        public void createTimedOut() {
            timedOut++;
        }

        @Override
        public void expired(final Report report) {
            expired.add(report);
        }
    }

    private final Manual scheduler = new Manual();
    private final CreatedReports reports = new CreatedReports(scheduler);
    private final Recorder expiry = new Recorder();
    private final Report one = FakeReports.create(new FakeReports.State());
    private final Report two = FakeReports.create(new FakeReports.State());

    @Test
    public void aSecondReservationIsRefusedWhileOneIsOpenOrHeld() {
        final int stamp = reports.reserve(1000, expiry);
        assertNotEquals(0, stamp);
        assertEquals("reserved", 0, reports.reserve(1000, expiry));
        final String handle = reports.fulfil(stamp, one, 5000, expiry);
        assertNotNull(handle);
        assertEquals("held", 0, reports.reserve(1000, expiry));
        assertSame(one, reports.take(handle));
        assertNotEquals("free again", 0, reports.reserve(1000, expiry));
    }

    @Test
    public void handlesAreNumberedAndNeverReused() {
        int stamp = reports.reserve(1000, expiry);
        final String first = reports.fulfil(stamp, one, 5000, expiry);
        reports.take(first);
        stamp = reports.reserve(1000, expiry);
        final String second = reports.fulfil(stamp, two, 5000, expiry);
        assertEquals("cr-1", first);
        assertEquals("cr-2", second);
        assertNull("the first handle is dead", reports.get(first));
        assertSame(two, reports.get(second));
    }

    @Test
    public void aNullAnswerFreesTheSlotAndMintsNothing() {
        final int stamp = reports.reserve(1000, expiry);
        assertNull(reports.fulfil(stamp, null, 5000, expiry));
        assertNotEquals(0, reports.reserve(1000, expiry));
    }

    @Test
    public void theCreateTimeoutFreesTheSlotAndTellsTheCaller() {
        final int stamp = reports.reserve(45_000, expiry);
        final Manual.Task timer = scheduler.last();
        assertEquals(45_000, timer.delayMs);
        timer.runnable.run();
        assertEquals(1, expiry.timedOut);
        assertNotEquals("the slot is free", 0, reports.reserve(1000, expiry));
        // The SDK's late answer for the timed-out reservation is refused by its stamp.
        assertNull(reports.fulfil(stamp, one, 5000, expiry));
    }

    @Test
    public void aLateAnswerCannotTakeANewerReservationsPlace() {
        final int old = reports.reserve(1000, expiry);
        scheduler.last().runnable.run(); // timed out
        final int fresh = reports.reserve(1000, expiry);
        assertNotEquals(old, fresh);
        assertNull("the stale listener is refused", reports.fulfil(old, one, 5000, expiry));
        assertTrue("the fresh reservation is intact", reports.isReserved(fresh));
        assertNotNull(reports.fulfil(fresh, two, 5000, expiry));
    }

    @Test
    public void aFulfilCancelsTheCreateTimerAndAnAnswerAfterItDoesNothing() {
        final int stamp = reports.reserve(1000, expiry);
        final Manual.Task createTimer = scheduler.last();
        final String handle = reports.fulfil(stamp, one, 5000, expiry);
        assertTrue(createTimer.cancelled);
        createTimer.runnable.run(); // fired anyway: the race
        assertEquals(0, expiry.timedOut);
        assertSame(one, reports.get(handle));
        assertNull("a second answer for the same stamp", reports.fulfil(stamp, two, 5000, expiry));
    }

    @Test
    public void theTimeToLiveReleasesTheReportOnce() {
        final int stamp = reports.reserve(1000, expiry);
        final String handle = reports.fulfil(stamp, one, 60_000, expiry);
        final Manual.Task ttl = scheduler.last();
        assertEquals(60_000, ttl.delayMs);
        ttl.runnable.run();
        assertEquals(1, expiry.expired.size());
        assertSame(one, expiry.expired.get(0));
        assertNull("gone", reports.get(handle));
        ttl.runnable.run(); // the race again
        assertEquals("released once", 1, expiry.expired.size());
        assertNotEquals("the slot is free", 0, reports.reserve(1000, expiry));
    }

    @Test
    public void takeCancelsTheTimeToLiveSoAnUploadedReportIsNotDiscarded() {
        final int stamp = reports.reserve(1000, expiry);
        final String handle = reports.fulfil(stamp, one, 60_000, expiry);
        final Manual.Task ttl = scheduler.last();
        assertSame(one, reports.take(handle));
        assertTrue(ttl.cancelled);
        ttl.runnable.run(); // the timer had already started
        assertEquals("a taken report is not expired", 0, expiry.expired.size());
        assertNull("a second take", reports.take(handle));
    }

    @Test
    public void anUnknownHandleTakesAndGetsNothing() {
        final int stamp = reports.reserve(1000, expiry);
        final String handle = reports.fulfil(stamp, one, 5000, expiry);
        assertNull(reports.get("cr-99"));
        assertNull(reports.take("cr-99"));
        assertNull(reports.take(null));
        assertSame("the real one is untouched", one, reports.get(handle));
    }

    @Test
    public void clearReleasesWhatIsHeldAndInvalidatesOpenStamps() {
        final int open = reports.reserve(1000, expiry);
        assertNull(reports.clear());
        assertNull(reports.fulfil(open, one, 5000, expiry));
        final int stamp = reports.reserve(1000, expiry);
        final String handle = reports.fulfil(stamp, two, 5000, expiry);
        assertSame(two, reports.clear());
        assertNull(reports.get(handle));
        assertNotEquals(0, reports.reserve(1000, expiry));
    }
}
