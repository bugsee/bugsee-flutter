package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import androidx.annotation.Nullable;

import com.bugsee.flutter.SecureRectangleStore.Placement;

import org.junit.Before;
import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The managed view hierarchy cache (the SDK's {@code vh}): what is served, in which unit, and every
 * case that must serve nothing instead.
 */
public class ViewHierarchyStoreTest {

    /** A device whose density a test can change. Android takes physical pixels: unit 1. */
    static final class Device implements SecureRectangleStore.Environment {
        volatile double density = 3;

        @Override
        public double nativePixelRatio(final int display) {
            return density;
        }

        @Override
        public double unitsPerPhysicalPixel(final int display) {
            return 1;
        }

        @Nullable
        @Override
        public int[] displayBounds(final int display) {
            return new int[] {1080, 2400};
        }
    }

    private static final long OWNER = 1;

    private Device device;
    private AtomicLong now;
    private SecureRectangleStore placement;
    private ViewHierarchyStore store;
    private long sequence;

    @Before
    public void setUp() {
        device = new Device();
        now = new AtomicLong(1000);
        placement = new SecureRectangleStore(device, now::get, 0);
        store = new ViewHierarchyStore(placement, now::get);
        sequence = 0;
    }

    /** Two nodes: template `A{age}B<box0>C<box1>D` (segments = nodes + 2). */
    private static List<String> template() {
        return Arrays.asList("A", "B", "C", "D");
    }

    private boolean publish(final long owner, final long epoch, final long seq,
            final double ratio, final List<String> segments, final double... bounds) {
        return store.publish(owner, epoch, seq, 0, ratio, segments, bounds);
    }

    /** Publishes the two-node template for owner 1 at the display's density, view at (x, y). */
    private void publishPlaced(final double x, final double y, final double... bounds) {
        placement.setPlacement(OWNER, 0, Placement.known(0, x, y));
        assertTrue(publish(OWNER, 1, ++sequence, device.density, template(), bounds));
    }

    // ---- nothing -------------------------------------------------------------------

    @Test
    public void nothingPublishedAnswersNull() {
        assertNull(store.answer());
    }

    @Test
    public void aSnapshotThatCannotBePlacedAnswersNull() {
        // Published, but the view's position was never learned.
        assertTrue(publish(OWNER, 1, 1, 3, template(), 0, 0, 10, 10, 0, 0, 5, 5));
        assertNull(store.answer());
        placement.setPlacement(OWNER, 0, Placement.UNKNOWN);
        assertNull(store.answer());
    }

    @Test
    public void aViewKnownToBeOffScreenAnswersNull() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        assertNotNull(store.answer());
        placement.setPlacement(OWNER, 0, Placement.ABSENT);
        assertNull(store.answer());
    }

    // ---- unit and placement (workbook 5.3, 6.6) -------------------------------------------

    /** Android: physical pixels, so 3 per logical pixel at density 3, plus the view's own position. */
    @Test
    public void boxesAreScaledToPhysicalPixelsAndPlacedOnTheScreen() {
        publishPlaced(30, 60, 0, 0, 100, 200, 10, 20, 50, 40);
        // origin + (0,0..100,200)*3 = [30,60, 300 wide, 600 high]; (10,20..50,40)*3 = [60,120, 120, 60]
        assertEquals("A0B[30,60,300,600]C[60,120,120,60]D", store.answer());
    }

    /** A density of 1 would give 100x200: the check below fails if the density is not applied. */
    @Test
    public void theDensityOfTheDeviceIsApplied() {
        device.density = 2.625;
        publishPlaced(0, 0, 0, 0, 100, 100, 0, 0, 1, 1);
        assertEquals("A0B[0,0,263,263]C[0,0,3,3]D", store.answer());
    }

    /** Fractional edges round outward, scaled BEFORE rounding, like the secure rectangles. */
    @Test
    public void edgesRoundOutwardAfterScaling() {
        publishPlaced(0, 0, 0, 0, 1, 1, 1.25, 2.25, 1.5, 2.5);
        // 3.75 -> 3, 6.75 -> 6, 4.5 -> 5, 7.5 -> 8: width 2, height 2
        assertEquals("A0B[0,0,3,3]C[3,6,2,2]D", store.answer());
    }

    /** A view with its own scale on screen (split-screen resize, a scaled ancestor). */
    @Test
    public void theViewsOwnScaleOnScreenIsApplied() {
        placement.setPlacement(OWNER, 0, Placement.known(0, 10, 10, 0.5, 0.5));
        assertTrue(publish(OWNER, 1, 1, 3, template(), 0, 0, 100, 100, 0, 0, 10, 10));
        // 100 * 3 * 0.5 + 10 = 160 -> [10,10,150,150]; 10*3*.5+10 = 25 -> [10,10,15,15]
        assertEquals("A0B[10,10,150,150]C[10,10,15,15]D", store.answer());
    }

    /** The same point is in the same place for the secure rectangles and the hierarchy. */
    @Test
    public void theSamePlaceAsTheSecureRectangles() {
        final Placement at = Placement.known(0, 17, 29, 0.75, 0.5);
        placement.setPlacement(OWNER, 0, at);
        final double[] box = {3.3, 4.7, 21.2, 30.9};
        assertTrue(placement.publish(OWNER, 1, 1, Collections.singletonMap(0,
                new SecureRectangleStore.ViewRects(3, box))));
        final int[] secure = placement.snapshot(0); // [version, count, l, t, r, b]
        assertTrue(publish(OWNER, 1, 1, 3, Arrays.asList("A", "B", "C"), box));
        final String answer = store.answer();
        assertEquals("A0B[" + secure[2] + "," + secure[3] + "," + (secure[4] - secure[2]) + ","
                + (secure[5] - secure[3]) + "]C", answer);
    }

    /** A boxes measured at one density are not served after the display changed density. */
    @Test
    public void aDensityThatNoLongerMatchesAnswersNull() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        assertNotNull(store.answer());
        device.density = 2;
        assertNull(store.answer());
        device.density = 3;
        assertNotNull("matches again", store.answer());
    }

    @Test
    public void aBoxThatIsNotFiniteAnswersNullNotAPartialDocument() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, Double.NaN, 5);
        assertNull(store.answer());
        publishPlaced(0, 0, 0, 0, 10, 10, 0, Double.POSITIVE_INFINITY, 5, 5);
        assertNull(store.answer());
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 1e300, 5);
        assertNull("beyond what the SDK's arithmetic can take", store.answer());
    }

    @Test
    public void aPlacementRefreshThatNeverCompletesAnswersNull() {
        placement.setPullHook(() -> { });
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        placement.refreshRequested();
        now.addAndGet(SecureRectangleStore.REFRESH_STALE_MS);
        assertNotNull("not yet stale", store.answer());
        now.addAndGet(1);
        assertNull("the main thread is not answering: the placement may be stale", store.answer());
        placement.refreshCompleted();
        assertNotNull(store.answer());
    }

    // ---- age ----------------------------------------------------------------------

    @Test
    public void theAgeIsMeasuredWhenTheAnswerIsGiven() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        assertEquals("A0B", store.answer().substring(0, 3));
        now.addAndGet(2500);
        assertEquals("A2500B", store.answer().substring(0, 6));
    }

    // ---- refresh hook -----------------------------------------------------------

    @Test
    public void theRefresherRunsBeforeEveryAnswerAndMayThrow() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        final AtomicInteger runs = new AtomicInteger();
        store.setRefresher(() -> {
            runs.incrementAndGet();
            throw new IllegalStateException("could not refresh");
        });
        assertNotNull(store.answer());
        assertNotNull(store.answer());
        assertEquals(2, runs.get());
    }

    // ---- shape, size, clearing ---------------------------------------------------

    @Test
    public void emptySegmentsClearTheSnapshot() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        assertNotNull(store.answer());
        assertTrue(publish(OWNER, 1, ++sequence, 1, Collections.<String>emptyList()));
        assertNull(store.answer());
    }

    @Test
    public void aMalformedMessageClearsWhatWasThere() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        // 3 segments for 2 nodes: one short.
        assertTrue(publish(OWNER, 1, ++sequence, 3, Arrays.asList("A", "B", "C"),
                0, 0, 10, 10, 0, 0, 5, 5));
        assertNull(store.answer());
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        // 7 numbers: not a whole number of boxes.
        assertTrue(publish(OWNER, 1, ++sequence, 3, Arrays.asList("A", "B", "C", "D"),
                0, 0, 10, 10, 0, 0, 5));
        assertNull(store.answer());
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        // A missing segment.
        assertTrue(publish(OWNER, 1, ++sequence, 3, Arrays.asList("A", null, "C", "D"),
                0, 0, 10, 10, 0, 0, 5, 5));
        assertNull(store.answer());
    }

    @Test
    public void anOversizeTemplateClearsWhatWasThere() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        final char[] big = new char[ViewHierarchyStore.MAX_TEMPLATE_CHARS];
        Arrays.fill(big, 'x');
        final String huge = new String(big);
        assertTrue(publish(OWNER, 1, ++sequence, 3, Arrays.asList(huge, "B", "C", "D"),
                0, 0, 10, 10, 0, 0, 5, 5));
        assertNull(store.answer());
        // Exactly at the limit is accepted.
        final String justFits = huge.substring(0, ViewHierarchyStore.MAX_TEMPLATE_CHARS - 3);
        assertTrue(publish(OWNER, 1, ++sequence, 3, Arrays.asList(justFits, "B", "C", "D"),
                0, 0, 10, 10, 0, 0, 5, 5));
        assertNotNull(store.answer());
    }

    // ---- immutability -----------------------------------------------------------------

    /** What Dart's lists held when they were sent is what is served, whatever happens to them later. */
    @Test
    public void whatWasPublishedCannotBeChangedFromOutside() {
        placement.setPlacement(OWNER, 0, Placement.known(0, 0, 0));
        final List<String> segments = new ArrayList<>(template());
        final double[] bounds = {0, 0, 10, 10, 0, 0, 5, 5};
        assertTrue(publish(OWNER, 1, 1, 3, segments, bounds));
        final String before = store.answer();
        segments.set(0, "X");
        segments.clear();
        Arrays.fill(bounds, 99);
        assertEquals(before, store.answer());
    }

    // ---- ordering (the secure rectangles' rules) ------------------------------------------

    @Test
    public void anOlderSequenceIsIgnoredAndKeepsWhatWasThere() {
        placement.setPlacement(OWNER, 0, Placement.known(0, 0, 0));
        assertTrue(publish(OWNER, 1, 5, 3, template(), 0, 0, 10, 10, 0, 0, 5, 5));
        final String served = store.answer();
        assertFalse(publish(OWNER, 1, 5, 3, template(), 0, 0, 99, 99, 0, 0, 5, 5));
        assertFalse(publish(OWNER, 1, 4, 3, Collections.<String>emptyList()));
        assertEquals(served, store.answer());
    }

    @Test
    public void aNewEpochIsANewIsolateAndReplacesTheOldOne() {
        placement.setPlacement(OWNER, 0, Placement.known(0, 0, 0));
        assertTrue(publish(OWNER, 1, 50, 3, template(), 0, 0, 10, 10, 0, 0, 5, 5));
        // A hot restart: a fresh epoch whose counter starts again at 1.
        assertTrue(publish(OWNER, 2, 1, 3, template(), 0, 0, 20, 20, 0, 0, 5, 5));
        assertEquals("A0B[0,0,60,60]C[0,0,15,15]D", store.answer());
    }

    @Test
    public void aRetiredEpochsStragglerIsIgnored() {
        placement.setPlacement(OWNER, 0, Placement.known(0, 0, 0));
        assertTrue(publish(OWNER, 1, 1, 3, template(), 0, 0, 10, 10, 0, 0, 5, 5));
        assertTrue(publish(OWNER, 2, 1, 3, template(), 0, 0, 20, 20, 0, 0, 5, 5));
        assertFalse("the dead isolate's late message", publish(OWNER, 1, 99, 3,
                Collections.<String>emptyList()));
        assertEquals("A0B[0,0,60,60]C[0,0,15,15]D", store.answer());
    }

    // ---- owners ----------------------------------------------------------------------

    @Test
    public void aDetachedEngineServesNothingEvenThoughItsViewWasPlaced() {
        publishPlaced(0, 0, 0, 0, 10, 10, 0, 0, 5, 5);
        assertNotNull(store.answer());
        store.dropOwner(OWNER);
        assertNull(store.answer());
        // And a late message of the dropped engine starts from nothing, like a new one.
        assertTrue(publish(OWNER, 1, 1, 3, template(), 0, 0, 10, 10, 0, 0, 5, 5));
    }

    @Test
    public void withSeveralEnginesTheNewestSnapshotIsServedAndOnlyIfItCanBePlaced() {
        placement.setPlacement(1, 0, Placement.known(0, 0, 0));
        placement.setPlacement(2, 0, Placement.known(0, 0, 0));
        assertTrue(store.publish(1, 1, 1, 0, 3, Arrays.asList("one", "B", "C", "D"),
                new double[] {0, 0, 1, 1, 0, 0, 1, 1}));
        now.addAndGet(10);
        assertTrue(store.publish(2, 1, 1, 0, 3, Arrays.asList("two", "B", "C", "D"),
                new double[] {0, 0, 1, 1, 0, 0, 1, 1}));
        assertEquals("two", store.answer().substring(0, 3));
        // The newest cannot be placed: nothing is served, not the other engine's older tree.
        placement.setPlacement(2, 0, Placement.UNKNOWN);
        assertNull(store.answer());
        store.dropOwner(2);
        assertEquals("one", store.answer().substring(0, 3));
    }

    // ---- thread safety ----------------------------------------------------------------------

    /**
     * Writers swap between two whole snapshots while readers answer: every answer is one of the two,
     * complete, never a mixture (5.4.1) and never an exception.
     */
    @Test(timeout = 20000)
    public void concurrentPublishAndAnswerNeverTear() throws Exception {
        placement.setPlacement(OWNER, 0, Placement.known(0, 0, 0));
        final String a = "AAAA";
        final String b = "BBBB";
        final List<String> first = Arrays.asList(a, "-", a, a);
        final List<String> second = Arrays.asList(b, "-", b, b);
        final double[] boxA = {0, 0, 1, 1, 0, 0, 2, 2};
        final double[] boxB = {0, 0, 3, 3, 0, 0, 4, 4};
        assertTrue(publish(OWNER, 1, ++sequence, 3, first, boxA));
        final Set<String> seen = ConcurrentHashMap.newKeySet();
        final AtomicBoolean failed = new AtomicBoolean();
        final AtomicBoolean stop = new AtomicBoolean();
        final CountDownLatch ready = new CountDownLatch(4);
        final List<Thread> readers = new ArrayList<>();
        for (int i = 0; i < 3; i++) {
            final Thread t = new Thread(() -> {
                ready.countDown();
                while (!stop.get()) {
                    try {
                        final String s = store.answer();
                        if (s != null) {
                            // Age is a number we strip: AAAA<age>-[box]AAAA[box]AAAA
                            seen.add(s.replaceFirst("(AAAA|BBBB)\\d+", "$1"));
                        }
                    } catch (Throwable e) {
                        failed.set(true);
                    }
                }
            });
            readers.add(t);
            t.start();
        }
        final Thread writer = new Thread(() -> {
            ready.countDown();
            long seq = 100;
            for (int i = 0; i < 20000 && !failed.get(); i++) {
                publish(OWNER, 1, ++seq, 3, i % 2 == 0 ? second : first, i % 2 == 0 ? boxB : boxA);
            }
        });
        writer.start();
        ready.await();
        writer.join();
        stop.set(true);
        for (final Thread t : readers) {
            t.join();
        }
        assertFalse(failed.get());
        final Set<String> allowed = new java.util.HashSet<>(Arrays.asList(
                "AAAA-[0,0,3,3]AAAA[0,0,6,6]AAAA",
                "BBBB-[0,0,9,9]BBBB[0,0,12,12]BBBB"));
        assertTrue("only whole snapshots, got " + seen, allowed.containsAll(seen));
        assertFalse(seen.isEmpty());
    }
}
