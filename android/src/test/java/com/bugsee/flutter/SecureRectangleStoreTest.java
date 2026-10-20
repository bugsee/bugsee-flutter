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
        volatile double scale = 3;
        volatile int[] bounds = {1080, 2400};
        volatile int scaleReads;

        @Override
        public double pixelsPerLogicalPixel(final int display) {
            scaleReads++;
            return scale;
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

    private static Map<Integer, double[]> view(final double... ltrb) {
        return Collections.singletonMap(0, ltrb);
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
                1, 1, 2, 2);
        assertArrayEquals(new int[] {1, 3, 3, 6, 6}, withoutVersion(store.snapshot(0)));
    }

    /** The scale is read at every pull (5.3.2): a density change is seen by the next one. */
    @Test
    public void theScaleIsReadPerCall() {
        publish(10, 10, 20, 20);
        final int[] at3 = store.snapshot(0);
        assertArrayEquals(new int[] {1, 30, 30, 60, 60}, withoutVersion(at3));
        env.scale = 2;
        final int[] at2 = store.snapshot(0);
        assertArrayEquals(new int[] {1, 20, 20, 40, 40}, withoutVersion(at2));
        assertNotEquals("a density change moves the version", at3[0], at2[0]);
        env.scale = 2.625;
        assertArrayEquals(new int[] {1, 26, 26, 53, 53}, withoutVersion(store.snapshot(0)));
        assertTrue(env.scaleReads >= 3);
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
            env.scale = bad;
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
        store.publish(1, 1, 1, Collections.singletonMap(7, new double[] {1, 1, 2, 2}));
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

        env.scale = 2; // the density changed
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
        store.publish(2, 1, 1, view(1, 1, 2, 2));
        final int d0 = store.snapshot(0)[0];
        final int d1 = store.snapshot(1)[0];
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
        assertFalse("older epoch", store.publish(1, 4, 99, view(7, 7, 8, 8)));
        assertArrayEquals(new int[] {1, 3, 3, 6, 6}, withoutVersion(store.snapshot(0)));
        assertTrue("newer sequence", store.publish(1, 5, 11, view(2, 2, 3, 3)));
        assertArrayEquals(new int[] {1, 6, 6, 9, 9}, withoutVersion(store.snapshot(0)));
    }

    @Test
    public void aNewIsolateWinsEvenThoughItsCounterRestarted() {
        store.setPlacement(1, 0, Placement.known(0, 0, 0));
        assertTrue(store.publish(1, 5, 500, view(1, 1, 2, 2)));
        assertTrue("a hot restart: larger epoch, sequence back at 1",
                store.publish(1, 6, 1, view(2, 2, 3, 3)));
        assertArrayEquals(new int[] {1, 6, 6, 9, 9}, withoutVersion(store.snapshot(0)));
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
        store.publish(1, 1, 1, Collections.singletonMap(0, mine));
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
        env.scale = 1;
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
            store.publish(1, 1, i, Collections.singletonMap(0, set));
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

    private static int[] withoutVersion(final int[] buffer) {
        // [count, l, t, r, b, ...]: drops the version, which has its own tests.
        final int[] out = new int[buffer.length - 1];
        System.arraycopy(buffer, 1, out, 0, out.length);
        return out;
    }
}
