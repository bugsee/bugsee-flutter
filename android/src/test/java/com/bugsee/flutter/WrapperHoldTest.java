package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import androidx.annotation.NonNull;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;

/** The startup hold must end on the first frame and can never outlive a runtime that cannot end it. */
public class WrapperHoldTest {

    /** A virtual clock: tasks run in due order when time advances. */
    private static final class Clock implements WrapperHold.Scheduler {
        private static final class Item {
            final Runnable task;
            final long due;

            Item(final Runnable task, final long due) {
                this.task = task;
                this.due = due;
            }
        }

        long now;
        final List<Item> items = new ArrayList<>();

        @Override
        public void postDelayed(@NonNull final Runnable task, final long delayMs) {
            items.add(new Item(task, now + delayMs));
        }

        @Override
        public void cancel(@NonNull final Runnable task) {
            for (final Iterator<Item> it = items.iterator(); it.hasNext(); ) {
                if (it.next().task == task) {
                    it.remove();
                }
            }
        }

        void advance(final long ms) {
            final long end = now + ms;
            while (true) {
                Item next = null;
                for (final Item i : items) {
                    if (i.due <= end && (next == null || i.due < next.due)) {
                        next = i;
                    }
                }
                if (next == null) {
                    break;
                }
                items.remove(next);
                now = next.due;
                next.task.run();
            }
            now = end;
        }
    }

    private static final class Sdk implements WrapperHold.Signal {
        int delivered;
        int attempts;
        boolean hasChannel = true;
        boolean throwing;

        @Override
        public boolean deliver() {
            attempts++;
            if (throwing) {
                throw new IllegalStateException("sdk");
            }
            if (!hasChannel) {
                return false;
            }
            delivered++;
            return true;
        }
    }

    @Test
    public void releasesOnceAfterTheFirstFrameSettles() {
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        clock.advance(2000);
        hold.uiDisplayed();
        clock.advance(WrapperHold.SETTLE_MS - 1);
        assertEquals("not before the secure rectangles had time to arrive", 0, sdk.delivered);
        clock.advance(1);
        assertEquals(1, sdk.delivered);
        assertTrue(hold.isReleased());
        // Nothing left to fire: neither the cap nor a second frame signals again.
        hold.uiDisplayed();
        clock.advance(60_000);
        assertEquals(1, sdk.delivered);
        assertTrue(clock.items.isEmpty());
    }

    @Test
    public void aSecondFrameDoesNotMoveTheSettle() {
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        hold.uiDisplayed();
        clock.advance(WrapperHold.SETTLE_MS - 10);
        hold.uiDisplayed();
        clock.advance(10);
        assertEquals(1, sdk.delivered);
    }

    @Test
    public void theCapCountsFromTheEngineNotTheProcess() {
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        // A slow cold start: the engine only attaches 12 s in. The hold must still be on.
        clock.advance(12_000);
        assertEquals(0, sdk.delivered);
        hold.engineAttached();
        clock.advance(WrapperHold.CAP_MS - 1);
        assertEquals(0, sdk.delivered);
        clock.advance(1);
        assertEquals(1, sdk.delivered);
        assertTrue(hold.isReleased());
    }

    @Test
    public void aProcessWithoutAnEngineIsReleasedByTheProcessCap() {
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        clock.advance(WrapperHold.PROCESS_CAP_MS - 1);
        assertEquals(0, sdk.delivered);
        clock.advance(1);
        assertEquals(1, sdk.delivered);
    }

    @Test
    public void aSecondEngineBeforeAnyFrameRestartsTheCap() {
        // A push wakes the process, a headless engine attaches; the UI engine comes 8 s later.
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        hold.engineAttached();
        clock.advance(WrapperHold.CAP_MS - 2000);
        hold.engineAttached();
        clock.advance(WrapperHold.CAP_MS - 1);
        assertEquals("the first engine's cap did not release the hold", 0, sdk.delivered);
        clock.advance(1);
        assertEquals(1, sdk.delivered);
    }

    @Test
    public void anEngineAfterTheFirstFrameDoesNotMoveTheSettle() {
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        hold.engineAttached();
        hold.uiDisplayed();
        clock.advance(WrapperHold.SETTLE_MS - 100);
        hold.engineAttached();
        clock.advance(100);
        assertEquals(1, sdk.delivered);
    }

    @Test
    public void aUiEngineThatComesAfterTheCapFindsTheHoldAlreadyReleased() {
        // The documented limit: a headless engine attached, the cap passed, a UI engine comes later.
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        hold.engineAttached();
        clock.advance(WrapperHold.CAP_MS);
        assertEquals("the cap released it", 1, sdk.delivered);
        hold.engineAttached();
        hold.uiDisplayed();
        clock.advance(WrapperHold.SETTLE_MS);
        assertEquals("the SDK was already told, nothing is held for the UI engine", 1, sdk.delivered);
        assertTrue(hold.isReleased());
    }

    @Test
    public void engineAttachesCannotKeepTheHoldPastTheHardCap() {
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        // One engine every 5 s: each restarts the cap, none shows a frame.
        for (long t = 0; t < WrapperHold.HARD_CAP_MS; t += 5_000) {
            hold.engineAttached();
            clock.advance(5_000);
        }
        assertEquals(1, sdk.delivered);
        assertTrue(hold.isReleased());
    }

    @Test
    public void theCapsAreOrderedAgainstTheSdksWarning() {
        // The SDK logs, at 15 s, that a hold is still on.
        assertTrue(WrapperHold.SETTLE_MS < WrapperHold.CAP_MS);
        assertTrue(WrapperHold.CAP_MS < WrapperHold.PROCESS_CAP_MS);
        assertTrue(WrapperHold.PROCESS_CAP_MS < WrapperHold.HARD_CAP_MS);
    }

    @Test
    public void startIsIdempotent() {
        final Clock clock = new Clock();
        final WrapperHold hold = new WrapperHold(clock, new Sdk());
        hold.start();
        hold.start();
        assertEquals("the cap and the hard cap, once each", 2, clock.items.size());
    }

    @Test
    public void withoutAChannelItKeepsRetryingUntilOneExists() {
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        sdk.hasChannel = false;
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        hold.uiDisplayed();
        clock.advance(WrapperHold.SETTLE_MS);
        assertFalse(hold.isReleased());
        clock.advance(1000);
        assertTrue("it keeps trying", sdk.attempts > 3);
        sdk.hasChannel = true;
        clock.advance(WrapperHold.RETRY_MS);
        assertEquals("and releases as soon as the channel is there", 1, sdk.delivered);
        assertTrue(hold.isReleased());
        assertTrue(clock.items.isEmpty());
    }

    @Test
    public void aChannelThatArrivesAfterTheRetryBudgetStillEndsTheHold() {
        // The registration failed at process start; it succeeded when Dart refined the identity, late.
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        sdk.hasChannel = false;
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        clock.advance(WrapperHold.PROCESS_CAP_MS * 3);
        assertFalse(hold.isReleased());
        final int before = sdk.attempts;
        clock.advance(WrapperHold.SLOW_RETRY_MS * 5);
        assertTrue("it keeps trying, slowly", sdk.attempts > before && sdk.attempts - before <= 6);
        sdk.hasChannel = true;
        clock.advance(WrapperHold.SLOW_RETRY_MS);
        assertEquals(1, sdk.delivered);
        assertTrue(hold.isReleased());
        assertTrue("nothing left running", clock.items.isEmpty());
    }

    @Test
    public void anSdkThatThrowsNeverEscapes() {
        final Clock clock = new Clock();
        final Sdk sdk = new Sdk();
        sdk.throwing = true;
        final WrapperHold hold = new WrapperHold(clock, sdk);
        hold.start();
        hold.uiDisplayed();
        clock.advance(WrapperHold.SETTLE_MS * 2);
        assertFalse(hold.isReleased());
    }
}
