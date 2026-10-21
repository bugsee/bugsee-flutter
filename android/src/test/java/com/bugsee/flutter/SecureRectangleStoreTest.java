package com.bugsee.flutter;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertTrue;

import androidx.annotation.Nullable;

import com.bugsee.library.contracts.internal.BugseeWrapper;

import org.junit.Before;
import org.junit.Test;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import com.bugsee.flutter.SecureRectangleStore.Placement;

/**
 * Workbook Part 5 on Android: units, rounding, versions, ownership. The SDK's
 * unit here is physical pixels in the space of View.getLocationOnScreen.
 */
public class SecureRectangleStoreTest {

    /** A device whose density and display size a test can change between pulls. */
    static final class FakeEnvironment implements SecureRectangleStore.Environment {
        volatile double density = 3;
        volatile int[] bounds = {1080, 2400};
        volatile int scaleReads;

        @Override
        public double nativePixelRatio(final int display) {
            scaleReads++;
            return density;
        }

        @Override
        public double unitsPerPhysicalPixel(final int display) {
            return 1;
        }

        @Nullable
        @Override
        public int[] displayBounds(final int display) {
            final int[] b = bounds;
            return b == null ? null : b.clone();
        }
    }

    private FakeEnvironment env;
    private SecureRectangleStore store;
    private long sequence;

    @Before
    public void setUp() {
        env = new FakeEnvironment();
        store = new SecureRectangleStore(env);
        sequence = 0;
    }

    /** What Dart publishes for the implicit view, measured at the display's current density. */
    private Map<Integer, SecureRectangleStore.ViewRects> view(final double... ltrb) {
        return viewAt(env.density, ltrb);
    }

    private static Map<Integer, SecureRectangleStore.ViewRects> viewAt(
            final double ratio, final double... ltrb) {
        return Collections.singletonMap(0, new SecureRectangleStore.ViewRects(ratio, ltrb));
    }

    /** Publishes {@code ltrb} for owner 1's implicit view, placed at the display origin. */
    private void publish(final double... ltrb) {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        assertTrue(store.publish(1, 1, ++sequence, view(ltrb)));
    }

    // ---- empty -------------------------------------------------------------------

    @Test
    public void aDisplayThatNeverHadARectangleIsUnknownAndEmpty() {
        assertArrayEquals(new int[] {BugseeWrapper.SECURE_RECTANGLES_VERSION_UNKNOWN, 0},
                store.snapshot(0));
        assertEquals(0, BugseeWrapper.SECURE_RECTANGLES_VERSION_UNKNOWN);
    }

    @Test
    public void afterARectangleVersionsAreRealAndAnEmptiedSetIsStillCounted() {
        publish(1, 1, 2, 2);
        final int[] full = store.snapshot(0);
        assertEquals(1, full[1]);
        assertNotEquals(0, full[0]);
        assertTrue(store.publish(1, 1, ++sequence, Collections.emptyMap()));
        final int[] empty = store.snapshot(0);
        assertEquals(0, empty[1]);
        assertNotEquals("emptying is a change", full[0], empty[0]);
        assertNotEquals("a real version, not unknown", 0, empty[0]);
    }

    // ---- unit and rounding (5.1.2, 5.3) --------------------------------------------

    /** Scale 3, fractional edges: floor l/t and ceil r/b of the SCALED values. */
    @Test
    public void scalesToPixelsThenRoundsOutward() {
        publish(1.25, 2.25, 1.5, 2.5);
        // 3.75 -> 3, 6.75 -> 6, 4.5 -> 5, 7.5 -> 8
        assertArrayEquals(new int[] {1, 3, 6, 5, 8}, withoutVersion(store.snapshot(0)));
    }

    /** Rounding before scaling would give floor(1.25)*3=3 and ceil(1.5)*3=6. */
    @Test
    public void roundsAfterScalingNotBefore() {
        publish(1.25, 0, 1.5, 1);
        final int[] s = store.snapshot(0);
        assertEquals(3, s[2]);
        assertEquals(5, s[4]);
    }

    /** Round-to-nearest would give 3 and 3 (2.7, 3.3); outward is 2 and 4. */
    @Test
    public void leftAndTopFloorRightAndBottomCeil() {
        publish(0.9, 0.9, 1.1, 1.1);
        // 2.7 -> 2, 3.3 -> 4
        assertArrayEquals(new int[] {1, 2, 2, 4, 4}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void rightAndBottomAreExclusiveSoExactEdgesAreNotWidened() {
        publish(0, 0, 10, 20); // scale 3 -> 30 x 60 exactly
        assertArrayEquals(new int[] {1, 0, 0, 30, 60}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void degenerateRectanglesAreDropped() {
        publish(5, 5, 5, 10, // zero width
                5, 5, 10, 5, // zero height
                10, 10, 5, 20, // inverted
                1.25, 1, 1.25, 2, // zero width at a fractional edge: rounding outward must not make it 1px
                1, 1, 2, 2);
        assertArrayEquals(new int[] {1, 3, 3, 6, 6}, withoutVersion(store.snapshot(0)));
    }

    /**
     * The density is read at every pull (5.3.2). A density change is applied natively before
     * Dart lays out again, so what was measured at the old ratio is not scaled by the new one:
     * the whole display is covered until Dart republishes at the new ratio.
     */
    @Test
    public void theDensityIsReadPerCallAndAMismatchCoversTheWholeDisplayUntilRepublished() {
        publish(10, 10, 20, 20);
        final int[] at3 = store.snapshot(0);
        assertArrayEquals(new int[] {1, 30, 30, 60, 60}, withoutVersion(at3));
        env.density = 2; // the display changed; Dart has not laid out again
        final int[] mismatch = store.snapshot(0);
        assertArrayEquals("old logical rects x new density cover neither old nor new content",
                new int[] {1, 0, 0, 1080, 2400}, withoutVersion(mismatch));
        assertNotEquals(at3[0], mismatch[0]);
        // Dart republishes at the new ratio: placed by that ratio.
        assertTrue(store.publish(1, 1, ++sequence, viewAt(2, 10, 10, 20, 20)));
        final int[] at2 = store.snapshot(0);
        assertArrayEquals(new int[] {1, 20, 20, 40, 40}, withoutVersion(at2));
        assertNotEquals(mismatch[0], at2[0]);
        env.density = 2.625;
        assertArrayEquals(new int[] {1, 0, 0, 1080, 2400}, withoutVersion(store.snapshot(0)));
        assertTrue(store.publish(1, 1, ++sequence, viewAt(2.625, 10, 10, 20, 20)));
        assertArrayEquals(new int[] {1, 26, 26, 53, 53}, withoutVersion(store.snapshot(0)));
        assertTrue(env.scaleReads >= 4);
    }

    @Test
    public void theMessagesOwnRatioScalesItNotTheDensityAtPullTime() {
        env.density = 2;
        assertTrue(store.publish(1, 1, 1, viewAt(2, 10, 10, 20, 20)));
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        assertArrayEquals(new int[] {1, 20, 20, 40, 40}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void aViewScaledOnScreenScalesTheRectanglesToo() {
        store.setPlacement(1, 0, Placement.known(0, 100, 200, 0.9, 0.9));
        store.publish(1, 1, 1, view(10, 10, 20, 20));
        // 30*0.9 = 27 -> 27+100 = 127, 60*0.9 = 54 -> 154; y: 27+200, 54+200
        assertArrayEquals(new int[] {1, 127, 227, 154, 254}, withoutVersion(store.snapshot(0)));
        store.setPlacement(1, 0, Placement.known(0, 100, 200, 1, 1));
        assertArrayEquals(new int[] {1, 130, 230, 160, 260}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void aViewScaleThatIsNotUsableCoversTheWholeDisplay() {
        store.publish(1, 1, 1, view(10, 10, 20, 20));
        for (final double bad : new double[] {0, -1, Double.NaN}) {
            store.setPlacement(1, 0, Placement.known(0, 0, 0, bad, 1));
            assertArrayEquals("scaleX " + bad, new int[] {1, 0, 0, 1080, 2400},
                    withoutVersion(store.snapshot(0)));
            store.setPlacement(1, 0, Placement.known(0, 0, 0, 1, bad));
            assertArrayEquals("scaleY " + bad, new int[] {1, 0, 0, 1080, 2400},
                    withoutVersion(store.snapshot(0)));
        }
    }

    @Test
    public void aSetWithNoScaleChangeKeepsItsVersionAcrossPulls() {
        publish(10, 10, 20, 20);
        final int v = store.snapshot(0)[0];
        for (int i = 0; i < 5; i++) {
            assertEquals(v, store.snapshot(0)[0]);
        }
    }

    // ---- coordinate space ---------------------------------------------------------

    @Test
    public void theViewsPositionOnTheScreenIsAdded() {
        store.setPlacement(1, 0, Placement.known(0, 0, 66)); // below a status bar
        store.publish(1, 1, 1, view(10, 10, 20, 20));
        assertArrayEquals(new int[] {1, 30, 96, 60, 126}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void movingTheViewMovesTheRectanglesAndTheVersion() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        store.publish(1, 1, 1, view(10, 10, 20, 20));
        final int[] before = store.snapshot(0);
        store.setPlacement(1, 0, Placement.known(0, 100, 0));
        final int[] after = store.snapshot(0);
        assertArrayEquals(new int[] {1, 130, 30, 160, 60}, withoutVersion(after));
        assertNotEquals(before[0], after[0]);
    }

    @Test
    public void rectanglesAreClampedToTheDisplayAndOnesOffItAreDropped() {
        publish(-10, -10, 5, 5, // overhangs the top-left
                300, 700, 400, 900, // 900*3 = 2700 > 2400, overhangs the bottom
                1000, 1000, 1100, 1100); // entirely off the display
        assertArrayEquals(new int[] {2, 0, 0, 15, 15, 900, 2100, 1080, 2400},
                withoutVersion(store.snapshot(0)));
    }

    // ---- fail closed ------------------------------------------------------------------

    @Test
    public void aViewWhosePlacementIsUnknownCoversTheWholeDisplay() {
        store.publish(1, 1, 1, view(10, 10, 20, 20)); // no placement ever set
        assertArrayEquals(new int[] {1, 0, 0, 1080, 2400}, withoutVersion(store.snapshot(0)));
        store.setPlacement(1, 0, Placement.UNKNOWN);
        assertArrayEquals(new int[] {1, 0, 0, 1080, 2400}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void aWholeDisplayCoverUsesTheFallbackSizeWhenTheDisplayIsUnknown() {
        env.bounds = null;
        store.publish(1, 1, 1, view(10, 10, 20, 20));
        assertArrayEquals(
                new int[] {1, 0, 0, SecureRectangleStore.FALLBACK_DISPLAY_SIZE,
                        SecureRectangleStore.FALLBACK_DISPLAY_SIZE},
                withoutVersion(store.snapshot(0)));
    }

    @Test
    public void aDisplaySizeThatReadsAsZeroCoversWithTheFallbackSizeToo() {
        env.bounds = new int[] {0, 0};
        store.publish(1, 1, 1, view(10, 10, 20, 20)); // no placement
        assertArrayEquals(
                new int[] {1, 0, 0, SecureRectangleStore.FALLBACK_DISPLAY_SIZE,
                        SecureRectangleStore.FALLBACK_DISPLAY_SIZE},
                withoutVersion(store.snapshot(0)));
    }

    @Test
    public void aViewKnownToBeOffScreenServesNothing() {
        store.setPlacement(1, 0, Placement.ABSENT);
        store.publish(1, 1, 1, view(10, 10, 20, 20));
        assertEquals(0, store.snapshot(0)[1]);
        // and is covered again as soon as it is back and not placed yet
        store.setPlacement(1, 0, Placement.UNKNOWN);
        assertEquals(1, store.snapshot(0)[1]);
    }

    @Test
    public void aRectangleThatIsNotFiniteCoversTheWholeDisplay() {
        publish(1, 1, 2, 2, Double.NaN, 0, 5, 5);
        assertArrayEquals(new int[] {1, 0, 0, 1080, 2400}, withoutVersion(store.snapshot(0)));
        publish(1, 1, 2, 2, 0, 0, Double.POSITIVE_INFINITY, 5);
        assertArrayEquals(new int[] {1, 0, 0, 1080, 2400}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void aScaleThatIsNotUsableCoversTheWholeDisplay() {
        publish(1, 1, 2, 2);
        for (final double bad : new double[] {Double.NaN, 0, -1, Double.POSITIVE_INFINITY}) {
            env.density = bad;
            assertArrayEquals("scale " + bad, new int[] {1, 0, 0, 1080, 2400},
                    withoutVersion(store.snapshot(0)));
        }
    }

    @Test
    public void aMalformedViewListCoversTheWholeDisplay() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        store.publish(1, 1, 1, view(1, 2, 3)); // not a multiple of four
        assertArrayEquals(new int[] {1, 0, 0, 1080, 2400}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void aViewOtherThanTheImplicitOneIsNotPlacedSoItCoversTheDisplay() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        store.publish(1, 1, 1, Collections.singletonMap(7,
                new SecureRectangleStore.ViewRects(3, new double[] {1, 1, 2, 2})));
        assertArrayEquals(new int[] {1, 0, 0, 1080, 2400}, withoutVersion(store.snapshot(0)));
    }

    // ---- versions (5.2) ---------------------------------------------------------------

    @Test
    public void aNoOpWriteDoesNotMoveTheVersion() {
        publish(1, 1, 2, 2);
        final int v = store.snapshot(0)[0];
        for (int i = 0; i < 4; i++) {
            publish(1, 1, 2, 2); // same set, newer sequence
            assertEquals(v, store.snapshot(0)[0]);
        }
        // Setting the same placement again is no change either.
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        assertEquals(v, store.snapshot(0)[0]);
    }

    @Test
    public void everyKindOfRealChangeMovesTheVersion() {
        publish(1, 1, 2, 2);
        int last = store.snapshot(0)[0];

        publish(1, 1, 3, 2); // resize
        int v = store.snapshot(0)[0];
        assertNotEquals("resize", last, v);
        last = v;

        publish(2, 1, 4, 2); // move
        v = store.snapshot(0)[0];
        assertNotEquals("move", last, v);
        last = v;

        publish(2, 1, 4, 2, 10, 10, 11, 11); // add
        v = store.snapshot(0)[0];
        assertNotEquals("add", last, v);
        last = v;

        publish(2, 1, 4, 2); // remove one
        v = store.snapshot(0)[0];
        assertNotEquals("remove", last, v);
        last = v;

        store.setPlacement(1, 0, Placement.known(0, 1, 0)); // the view moved
        v = store.snapshot(0)[0];
        assertNotEquals("view moved", last, v);
        last = v;

        env.density = 2; // the density changed (mismatch: the whole display)
        v = store.snapshot(0)[0];
        assertNotEquals("scale", last, v);
        last = v;

        env.bounds = new int[] {6, 6}; // the display shrank under the rectangle
        v = store.snapshot(0)[0];
        assertNotEquals("display size", last, v);
    }

    @Test
    public void aSetThatComesBackStillGetsANewVersion() {
        publish(1, 1, 2, 2);
        final int a = store.snapshot(0)[0];
        publish(5, 5, 6, 6);
        final int b = store.snapshot(0)[0];
        publish(1, 1, 2, 2);
        final int c = store.snapshot(0)[0];
        assertNotEquals(a, b);
        assertNotEquals(b, c);
        assertNotEquals("the SDK cached a by version; c must not look like a", a, c);
    }

    @Test
    public void versionsNeverLandOnZero() {
                assertEquals(1, SecureRectangleStore.advance(-1));
        assertEquals(Integer.MIN_VALUE, SecureRectangleStore.advance(Integer.MAX_VALUE));
        assertEquals(5, SecureRectangleStore.advance(4));
    }

    @Test
    public void versionsArePerDisplay() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        store.setPlacement(2, 0, Placement.known(1, 0, 0));
        store.publish(1, 1, 1, view(1, 1, 2, 2));
        store.publish(2, 1, 1, view(4, 4, 5, 5));
        final int d0 = store.snapshot(0)[0];
        final int d1 = store.snapshot(1)[0];
        // Reading one display again after the other changes nothing.
        assertEquals(d0, store.snapshot(0)[0]);
        assertEquals(d1, store.snapshot(1)[0]);
        // A change on display 1 leaves display 0's version alone.
        store.publish(2, 1, 2, view(1, 1, 5, 5));
        assertEquals(d0, store.snapshot(0)[0]);
        assertNotEquals(d1, store.snapshot(1)[0]);
        // And the other way round.
        final int d1b = store.snapshot(1)[0];
        store.publish(1, 1, 2, view(1, 1, 9, 9));
        assertEquals(d1b, store.snapshot(1)[0]);
        // A rectangle shows on its own display only.
        assertEquals(1, store.snapshot(0)[1]);
        assertEquals(1, store.snapshot(1)[1]);
        assertEquals(0, store.snapshot(2)[1]);
    }

    // ---- ordering ----------------------------------------------------------------------

    @Test
    public void aDelayedOlderMessageNeverOverwritesANewerOne() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        assertTrue(store.publish(1, 5, 10, view(1, 1, 2, 2)));
        assertFalse("older sequence", store.publish(1, 5, 9, view(7, 7, 8, 8)));
        assertFalse("same sequence", store.publish(1, 5, 10, view(7, 7, 8, 8)));
        assertArrayEquals(new int[] {1, 3, 3, 6, 6}, withoutVersion(store.snapshot(0)));
        assertTrue("newer sequence", store.publish(1, 5, 11, view(2, 2, 3, 3)));
        assertArrayEquals(new int[] {1, 6, 6, 9, 9}, withoutVersion(store.snapshot(0)));
    }

    /**
     * Epochs are random ids, not clocks: a new isolate's id may be numerically LOWER than the
     * old one's (a wall clock that went backwards before a hot restart) and must still win,
     * while a late message of the dead isolate must not.
     */
    @Test
    public void aNewIsolateWinsWhateverItsEpochIsAndTheOldOnesStragglersAreIgnored() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        assertTrue(store.publish(1, 900, 500, view(1, 1, 2, 2)));
        assertTrue("a hot restart: a LOWER epoch id, counter back at 1",
                store.publish(1, 100, 1, view(2, 2, 3, 3)));
        assertArrayEquals(new int[] {1, 6, 6, 9, 9}, withoutVersion(store.snapshot(0)));
        assertFalse("a straggler of the dead isolate", store.publish(1, 900, 501, view(7, 7, 8, 8)));
        assertArrayEquals(new int[] {1, 6, 6, 9, 9}, withoutVersion(store.snapshot(0)));
        assertTrue(store.publish(1, 100, 2, view(3, 3, 4, 4)));
        // and a third isolate retires the second
        assertTrue(store.publish(1, 5, 1, view(1, 1, 2, 2)));
        assertFalse(store.publish(1, 100, 3, view(7, 7, 8, 8)));
        assertFalse(store.publish(1, 900, 502, view(7, 7, 8, 8)));
    }

    @Test
    public void theOrderingIsPerOwner() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        store.setPlacement(2, 0, Placement.known(0, 0, 0));
        assertTrue(store.publish(1, 1, 50, view(1, 1, 2, 2)));
        assertTrue("another engine has its own counter", store.publish(2, 1, 1, view(4, 4, 5, 5)));
        assertEquals("both engines' rectangles are served", 2, store.snapshot(0)[1]);
    }

    @Test
    public void aPublishReplacesOnlyItsOwnersViews() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        store.setPlacement(2, 0, Placement.known(0, 0, 0));
        store.publish(1, 1, 1, view(1, 1, 2, 2));
        store.publish(2, 1, 1, view(4, 4, 5, 5));
        store.publish(1, 1, 2, Collections.emptyMap());
        assertArrayEquals(new int[] {1, 12, 12, 15, 15}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void droppingAnOwnerClearsItsRectanglesAndOrdering() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        store.publish(1, 9, 9, view(1, 1, 2, 2));
        store.dropOwner(1);
        assertEquals(0, store.snapshot(0)[1]);
        // A new engine given the same owner id starts fresh.
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        assertTrue(store.publish(1, 1, 1, view(1, 1, 2, 2)));
        assertEquals(1, store.snapshot(0)[1]);
    }

    // ---- ownership (5.4.1) ----------------------------------------------------------------

    @Test
    public void snapshotsAreCopiesNobodyCanWriteThrough() {
        final double[] mine = {1, 1, 2, 2};
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        store.publish(1, 1, 1, Collections.singletonMap(0, new SecureRectangleStore.ViewRects(3, mine)));
        mine[0] = 50; // a later write by the caller must not reach what is served
        final int[] first = store.snapshot(0);
        assertEquals(3, first[2]);
        first[2] = 999; // nor a write by the reader
        assertEquals(3, store.snapshot(0)[2]);
        assertNotSame(store.snapshot(0), store.snapshot(0));
    }

    /**
     * The SDK pulls from its own thread while Dart keeps publishing: every buffer a
     * reader gets must be one coherent published set, and one version must always mean
     * one content.
     */
    @Test
    public void readersOnAnotherThreadSeeOnlyWholeSetsAndConsistentVersions() throws Exception {
        env.density = 1;
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        final AtomicBoolean stop = new AtomicBoolean();
        final AtomicReference<Throwable> failure = new AtomicReference<>();
        final Map<Integer, String> contentByVersion = new java.util.concurrent.ConcurrentHashMap<>();
        final CountDownLatch started = new CountDownLatch(2);

        final Runnable reader = () -> {
            started.countDown();
            try {
                while (!stop.get()) {
                    final int[] s = store.snapshot(0);
                    final int n = s[1];
                    if (s.length != 2 + 4 * n) {
                        throw new AssertionError("header and length disagree: " + s.length + " vs " + n);
                    }
                    // Every published set k is k rectangles (i, i, i + 100, i + 100), i < k.
                    for (int r = 0; r < n; r++) {
                        final int l = s[2 + 4 * r];
                        if (s[3 + 4 * r] != l || s[4 + 4 * r] != l + 100 || s[5 + 4 * r] != l + 100) {
                            throw new AssertionError("torn rectangle " + r + " of " + n);
                        }
                        if (l != r) {
                            throw new AssertionError("rectangle " + r + " has l=" + l);
                        }
                    }
                    final String content =
                            java.util.Arrays.toString(java.util.Arrays.copyOfRange(s, 1, s.length));
                    final String seen = contentByVersion.putIfAbsent(s[0], content);
                    if (seen != null && !seen.equals(content)) {
                        throw new AssertionError("version " + s[0] + " meant two sets");
                    }
                }
            } catch (Throwable t) {
                failure.compareAndSet(null, t);
            }
        };
        final Thread a = new Thread(reader);
        final Thread b = new Thread(reader);
        a.start();
        b.start();
        started.await();
        for (int i = 1; i <= 3000; i++) {
            final int k = 1 + (i % 12);
            final double[] set = new double[4 * k];
            for (int r = 0; r < k; r++) {
                set[4 * r] = r;
                set[4 * r + 1] = r;
                set[4 * r + 2] = r + 100;
                set[4 * r + 3] = r + 100;
            }
            store.publish(1, 1, i, viewAt(1, set));
        }
        stop.set(true);
        a.join();
        b.join();
        if (failure.get() != null) {
            throw new AssertionError(failure.get());
        }
    }

    // ---- the SDK's pull ------------------------------------------------------------------------

    @Test
    public void aPullCallsTheHookFirstAndSurvivesItThrowing() {
        publish(1, 1, 2, 2);
        final int[] calls = {0};
        store.setPullHook(() -> {
            calls[0]++;
            throw new IllegalStateException("hook failed");
        });
        assertEquals(1, store.pull(0)[1]);
        assertEquals(1, calls[0]);
    }


    // ---- grace window ---------------------------------------------------------------------------

    private final long[] now = {1000};

    private SecureRectangleStore graced() {
        env.density = 1;
        final SecureRectangleStore g = new SecureRectangleStore(env, () -> now[0],
                SecureRectangleStore.GRACE_MS);
        g.setPlacement(1, 0, Placement.known(0, 0, 0));
        return g;
    }

    private long seq;

    private boolean put(final SecureRectangleStore g, final double... ltrb) {
        return g.publish(1, 1, ++seq, viewAt(1, ltrb));
    }

    @Test
    public void aMovedRegionIsCoveredWhereItWasToo_thenTheUnionShrinksAndMovesTheVersion() {
        final SecureRectangleStore g = graced();
        put(g, 0, 0, 10, 10);
        final int[] first = g.snapshot(0);
        assertArrayEquals("a new region has no previous place: only itself",
                new int[] {1, 0, 0, 10, 10}, withoutVersion(first));
        now[0] += 10;
        put(g, 5, 0, 15, 10);
        final int[] moved = g.snapshot(0);
        assertArrayEquals("the new place AND the old one",
                new int[] {2, 5, 0, 15, 10, 0, 0, 10, 10}, withoutVersion(moved));
        assertNotEquals(first[0], moved[0]);
        now[0] += SecureRectangleStore.GRACE_MS - 1;
        assertEquals("inside the window: same union, same version", moved[0], g.snapshot(0)[0]);
        now[0] += 1;
        final int[] shrunk = g.snapshot(0);
        assertArrayEquals(new int[] {1, 5, 0, 15, 10}, withoutVersion(shrunk));
        assertNotEquals("shrinking is a change the SDK must re-read", moved[0], shrunk[0]);
        assertEquals("and then it is stable", shrunk[0], g.snapshot(0)[0]);
    }

    @Test
    public void aRegionThatWentIsStillCoveredForTheWindow() {
        final SecureRectangleStore g = graced();
        put(g, 0, 0, 10, 10);
        g.snapshot(0);
        now[0] += 10;
        assertTrue(g.publish(1, 1, ++seq, Collections.emptyMap()));
        final int[] gone = g.snapshot(0);
        assertArrayEquals(new int[] {1, 0, 0, 10, 10}, withoutVersion(gone));
        now[0] += SecureRectangleStore.GRACE_MS;
        final int[] empty = g.snapshot(0);
        assertEquals(0, empty[1]);
        assertNotEquals(gone[0], empty[0]);
    }

    @Test
    public void everyPastPlaceIsServedForAWindowFromWhenItStoppedBeingCurrent() {
        final SecureRectangleStore g = graced();
        put(g, 0, 0, 10, 10); // A
        g.snapshot(0);
        now[0] += 10;
        put(g, 5, 0, 15, 10); // B: A stops at +10, served until +130
        g.snapshot(0);
        now[0] += 40;
        put(g, 10, 0, 20, 10); // C: B stops at +50, served until +170
        assertEquals("current + both earlier places", 3, g.snapshot(0)[1]);
        now[0] = 1000 + 129;
        assertEquals(3, g.snapshot(0)[1]);
        now[0] = 1000 + 130;
        assertEquals("A has had its window", 2, g.snapshot(0)[1]);
        now[0] = 1000 + 169;
        assertEquals(2, g.snapshot(0)[1]);
        now[0] = 1000 + 170;
        assertEquals("B has had its window", 1, g.snapshot(0)[1]);
    }

    /** A long movement must not widen the cover to its whole path. */
    @Test
    public void aLongMovementKeepsOnlyTheLastWindowsWorthOfPlaces() {
        final SecureRectangleStore g = graced();
        int max = 0;
        for (int i = 0; i < 60; i++) {
            put(g, i * 10, 0, i * 10 + 10, 10);
            max = Math.max(max, g.snapshot(0)[1]);
            now[0] += 80; // slower than a frame, like a few pulls a second
        }
        assertTrue("at most the current and the previous place, got " + max, max <= 3);
    }

    @Test
    public void tooManyPreviousRectanglesCollapseToTheirBoundingBox() {
        final SecureRectangleStore g = graced();
        final double[] many = new double[4 * 70];
        for (int i = 0; i < 70; i++) {
            many[4 * i] = i;
            many[4 * i + 1] = 0;
            many[4 * i + 2] = i + 1;
            many[4 * i + 3] = 5;
        }
        put(g, many);
        g.snapshot(0);
        now[0] += 10;
        put(g, 500, 500, 510, 510);
        final int[] s = g.snapshot(0);
        assertArrayEquals("the new one, then ONE box over the 70 old ones",
                new int[] {2, 500, 500, 510, 510, 0, 0, 70, 5}, withoutVersion(s));
    }

    @Test
    public void afterALongWalkTooManyPastRectanglesStillCoverTheLastStepToo() {
        final SecureRectangleStore g = graced();
        for (int i = 0; i < 60; i++) {
            put(g, i * 10, 0, i * 10 + 10, 10);
            g.snapshot(0);
            now[0] += 80;
        }
        final double[] many = new double[4 * 70];
        for (int i = 0; i < 70; i++) {
            many[4 * i] = i;
            many[4 * i + 2] = i + 1;
            many[4 * i + 3] = 5;
        }
        now[0] += 1000;
        put(g, many);
        g.snapshot(0);
        now[0] += 10;
        put(g, 300, 300, 310, 310);
        // the walk's last step stopped being current only 10 ms ago, so it is covered too
        assertArrayEquals(new int[] {3, 300, 300, 310, 310, 0, 0, 70, 5, 590, 0, 600, 10},
                withoutVersion(g.snapshot(0)));
    }

    @Test
    public void aStaticSetNeverGrowsAWindow() {
        final SecureRectangleStore g = graced();
        put(g, 0, 0, 10, 10);
        final int v = g.snapshot(0)[0];
        for (int i = 0; i < 5; i++) {
            now[0] += 500;
            put(g, 0, 0, 10, 10);
            assertEquals(v, g.snapshot(0)[0]);
        }
    }

    private static int[] withoutVersion(final int[] buffer) {
        // [count, l, t, r, b, ...]: drops the version, which has its own tests.
        final int[] out = new int[buffer.length - 1];
        System.arraycopy(buffer, 1, out, 0, out.length);
        return out;
    }
}
