package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.internal.BugseeWrapper;

import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Where the secure-rectangle sets live (workbook 5.4.2): outside the wrapper
 * object, because the wrapper is replaced mid-session when Dart refines the
 * identity, and the regions must survive that or the app is recorded
 * unredacted until it next republishes.
 *
 * <h2>What the SDK takes (Android 7.4.2)</h2>
 *
 * <p>{@link BugseeWrapper#getSecureRectangles(int)} returns
 * {@code [version, count, l, t, r, b, ...]}; the rectangles are PHYSICAL PIXELS
 * in the display's coordinate space, the one {@code View.getLocationOnScreen}
 * reports (the SDK measures its own secure views with it and applies the
 * screen-to-frame transform itself), {@code r}/{@code b} exclusive. The
 * {@code display} argument is the Android display id
 * ({@code Display.getDisplayId()}); the SDK pulls once per capture on its
 * capture thread. A non-zero version equal to the last one seen for that
 * display makes the SDK skip the rectangles entirely; 0
 * ({@link BugseeWrapper#SECURE_RECTANGLES_VERSION_UNKNOWN}) makes it compare
 * them; a count of 0 clears the display's set whatever the version.
 *
 * <p>Dart publishes Flutter LOGICAL pixels (Android dp) relative to its view.
 * This class turns them into the SDK's buffer: multiply by the display's
 * pixels-per-logical-pixel (read at every pull, never cached), add the view's
 * position on the screen, then round OUTWARD (floor {@code l}/{@code t}, ceil
 * {@code r}/{@code b}), scaling BEFORE rounding so no sub-pixel strip is left
 * uncovered (5.1.2, 5.3.1).
 *
 * <h2>Versions</h2>
 *
 * <p>A display's version is derived from what is served, not from what was
 * written: it moves exactly when the served rectangles differ from the ones
 * served before (so also when only the scale or the view's position changed,
 * which no write announces), and never otherwise (5.2.1, 5.2.2). It is kept
 * per display (5.2.3) and only ever steps forward, skipping 0. A display that
 * has never had a rectangle serves {@code [0, 0]}: unknown, and empty. Once it
 * has had one it serves real versions, an emptied set included ({@code [v, 0]}).
 *
 * <h2>Fail closed</h2>
 *
 * <p>A view whose placement is not known (the Flutter view has not been found,
 * or is ambiguous) is served as one rectangle covering the whole display. A
 * rectangle that is not finite does the same, and so does a scale that is not
 * a positive finite number. A view that is known to be not on screen at all
 * (its activity is detached) serves nothing.
 *
 * <h2>Threading</h2>
 *
 * <p>Writes come from the platform thread and the placement tracker, the pull
 * from the SDK's capture thread. The written state is immutable and swapped
 * whole; the served buffer is an immutable array that is cloned for every
 * caller (5.4.1).
 */
final class SecureRectangleStore {

    /**
     * {@link BugseeWrapper#SECURE_RECTANGLES_VERSION_UNKNOWN}: what a display
     * that never had a rectangle serves, and what the SDK reads as "compare the
     * rectangles yourself". Real versions are never this value.
     */
    static final int UNKNOWN_VERSION = BugseeWrapper.SECURE_RECTANGLES_VERSION_UNKNOWN;

    private static final int HEADER_INTS = 2;

    /**
     * The size a whole-display rectangle gets when the display's real size is
     * not known: more than any panel, small enough not to overflow an int when
     * the SDK scales it.
     */
    static final int FALLBACK_DISPLAY_SIZE = 16384;

    /** Largest magnitude served: keeps the SDK's own int arithmetic away from overflow. */
    private static final double LIMIT = 1 << 28;

    /** What the store needs to know about the device, read at every pull. */
    interface Environment {
        /**
         * Physical pixels per Flutter logical pixel on {@code display}: the
         * density Flutter itself uses (Android: {@code DisplayMetrics.density}
         * of the Flutter view). Read per call, never cached. Not finite or not
         * positive means "unknown" and fails closed.
         */
        double pixelsPerLogicalPixel(int display);

        /** The display's current size in pixels, {@code {width, height}}, or {@code null}. */
        @Nullable
        int[] displayBounds(int display);
    }

    /** Knows nothing: every view covers the whole display. Until a plugin installs the real one. */
    static final Environment UNKNOWN_ENVIRONMENT = new Environment() {
        @Override
        public double pixelsPerLogicalPixel(final int display) {
            return Double.NaN;
        }

        @Nullable
        @Override
        public int[] displayBounds(final int display) {
            return null;
        }
    };

    /** Where one Flutter view sits, in the unit and space the SDK wants. */
    static final class Placement {
        static final int KNOWN_KIND = 0;
        static final int UNKNOWN_KIND = 1;
        static final int ABSENT_KIND = 2;

        /** The view's position is not known: serve the whole display. */
        static final Placement UNKNOWN = new Placement(UNKNOWN_KIND, 0, 0, 0);
        /** The view is known not to be on screen: serve nothing. */
        static final Placement ABSENT = new Placement(ABSENT_KIND, 0, 0, 0);

        final int kind;
        final int display;
        /** The view's top-left on the display, in physical pixels. */
        final double x;
        final double y;

        private Placement(final int kind, final int display, final double x, final double y) {
            this.kind = kind;
            this.display = display;
            this.x = x;
            this.y = y;
        }

        static Placement known(final int display, final double x, final double y) {
            return new Placement(KNOWN_KIND, display, x, y);
        }

        @Override
        public boolean equals(final Object o) {
            if (!(o instanceof Placement)) {
                return false;
            }
            final Placement p = (Placement) o;
            return kind == p.kind && display == p.display && x == p.x && y == p.y;
        }

        @Override
        public int hashCode() {
            return Arrays.hashCode(new double[] {kind, display, x, y});
        }
    }

    /** One Flutter view of one Dart isolate. */
    private static final class Lane implements Comparable<Lane> {
        final long owner;
        final int viewId;

        Lane(final long owner, final int viewId) {
            this.owner = owner;
            this.viewId = viewId;
        }

        @Override
        public boolean equals(final Object o) {
            return o instanceof Lane && ((Lane) o).owner == owner && ((Lane) o).viewId == viewId;
        }

        @Override
        public int hashCode() {
            return Long.hashCode(owner) * 31 + viewId;
        }

        @Override
        public int compareTo(final Lane other) {
            final int c = Long.compare(owner, other.owner);
            return c != 0 ? c : Integer.compare(viewId, other.viewId);
        }
    }

    /** Immutable. Replaced wholesale on every write. */
    private static final class State {
        /** Logical-pixel rectangles as Dart sent them, flat ltrb. */
        final TreeMap<Lane, double[]> rects;
        final Map<Lane, Placement> placements;
        /** owner to {epoch, sequence} of the newest applied publish. */
        final Map<Long, long[]> order;

        State(
                final TreeMap<Lane, double[]> rects,
                final Map<Lane, Placement> placements,
                final Map<Long, long[]> order
        ) {
            this.rects = rects;
            this.placements = placements;
            this.order = order;
        }
    }

    /** What a display last served. Immutable. */
    private static final class Served {
        final int version;
        /** The rectangles only (no header), physical pixels. */
        final int[] quads;
        final int[] buffer;

        Served(final int version, @NonNull final int[] quads) {
            this.version = version;
            this.quads = quads;
            this.buffer = new int[HEADER_INTS + quads.length];
            buffer[0] = version;
            buffer[1] = quads.length / 4;
            System.arraycopy(quads, 0, buffer, HEADER_INTS, quads.length);
        }
    }

    private static final SecureRectangleStore SHARED = new SecureRectangleStore(UNKNOWN_ENVIRONMENT);

    @NonNull
    static SecureRectangleStore shared() {
        return SHARED;
    }

    private volatile Environment environment;
    private volatile State state = new State(new TreeMap<>(), new HashMap<>(), new HashMap<>());
    private final Object writeLock = new Object();
    private final Object serveLock = new Object();
    private final Map<Integer, Served> served = new HashMap<>();
    private final AtomicReference<Runnable> pullHook = new AtomicReference<>();

    SecureRectangleStore(@NonNull final Environment environment) {
        this.environment = environment;
    }

    /** For a plugin to install what it can read off the device. */
    void setEnvironment(@NonNull final Environment environment) {
        this.environment = environment;
    }

    /**
     * Installs what every pull calls first (the placement tracker's throttled
     * refresh request). It must only post to another thread, never block.
     */
    void setPullHook(@Nullable final Runnable hook) {
        pullHook.set(hook);
    }

    /**
     * Applies Dart's whole state for {@code owner}: {@code views} maps a view
     * id to its flat logical {@code [l, t, r, b, ...]}; a view not in the map
     * has no rectangles any more. Ignored, and {@code false}, unless
     * {@code (epoch, sequence)} is newer than the newest applied for
     * {@code owner}: a delayed older message must never overwrite a newer one,
     * while a new isolate (a larger epoch, its counter back at 0) still wins.
     */
    boolean publish(
            final long owner,
            final long epoch,
            final long sequence,
            @NonNull final Map<Integer, double[]> views
    ) {
        synchronized (writeLock) {
            final State previous = state;
            final long[] last = previous.order.get(owner);
            if (last != null && (epoch < last[0] || (epoch == last[0] && sequence <= last[1]))) {
                return false;
            }
            final TreeMap<Lane, double[]> rects = new TreeMap<>();
            for (final Map.Entry<Lane, double[]> e : previous.rects.entrySet()) {
                if (e.getKey().owner != owner) {
                    rects.put(e.getKey(), e.getValue());
                }
            }
            for (final Map.Entry<Integer, double[]> e : views.entrySet()) {
                final double[] copy = e.getValue().clone();
                if (copy.length > 0) {
                    rects.put(new Lane(owner, e.getKey()), copy);
                }
            }
            final Map<Long, long[]> order = new HashMap<>(previous.order);
            order.put(owner, new long[] {epoch, sequence});
            state = new State(rects, previous.placements, order);
            return true;
        }
    }

    /** Where {@code owner}'s view {@code viewId} sits now. Not a change when it is the same. */
    void setPlacement(final long owner, final int viewId, @NonNull final Placement placement) {
        synchronized (writeLock) {
            final State previous = state;
            final Lane lane = new Lane(owner, viewId);
            if (placement.equals(previous.placements.get(lane))) {
                return;
            }
            final Map<Lane, Placement> placements = new HashMap<>(previous.placements);
            placements.put(lane, placement);
            state = new State(previous.rects, placements, previous.order);
        }
    }

    /** Dart's engine is gone: forget its rectangles, placements and ordering. */
    void dropOwner(final long owner) {
        synchronized (writeLock) {
            final State previous = state;
            final TreeMap<Lane, double[]> rects = new TreeMap<>();
            for (final Map.Entry<Lane, double[]> e : previous.rects.entrySet()) {
                if (e.getKey().owner != owner) {
                    rects.put(e.getKey(), e.getValue());
                }
            }
            final Map<Lane, Placement> placements = new HashMap<>();
            for (final Map.Entry<Lane, Placement> e : previous.placements.entrySet()) {
                if (e.getKey().owner != owner) {
                    placements.put(e.getKey(), e.getValue());
                }
            }
            final Map<Long, long[]> order = new HashMap<>(previous.order);
            order.remove(owner);
            state = new State(rects, placements, order);
        }
    }

    /** The SDK's pull: asks the tracker for a refresh, then serves. */
    @NonNull
    int[] pull(final int display) {
        final Runnable hook = pullHook.get();
        if (hook != null) {
            try {
                hook.run();
            } catch (Throwable ignored) {
                // The pull must always be answered.
            }
        }
        return snapshot(display);
    }

    /**
     * The buffer for {@code display}: {@code [version, count, l, t, r, b, ...]}.
     * Computed from the current state, scale and size at this call; a fresh
     * array every time.
     */
    @NonNull
    int[] snapshot(final int display) {
        synchronized (serveLock) {
            final int[] quads = serve(state, display);
            final Served previous = served.get(display);
            if (previous == null && quads.length == 0) {
                return new int[] {UNKNOWN_VERSION, 0};
            }
            if (previous != null && Arrays.equals(previous.quads, quads)) {
                return previous.buffer.clone();
            }
            final Served next = new Served(nextVersion(previous), quads);
            served.put(display, next);
            return next.buffer.clone();
        }
    }

    private static int nextVersion(@Nullable final Served previous) {
        return previous == null ? 1 : advance(previous.version);
    }

    /** The version after {@code version}: wraps, and never lands on 0 ("unknown"). */
    static int advance(final int version) {
        final int next = version + 1;
        return next == UNKNOWN_VERSION ? next + 1 : next;
    }

    /** The physical-pixel rectangles {@code display} serves for {@code s}, flat ltrb. */
    @NonNull
    private int[] serve(@NonNull final State s, final int display) {
        final Environment env = environment;
        double scale = Double.NaN;
        boolean scaleRead = false;
        int[] bounds = null;
        boolean boundsRead = false;

        int[] out = new int[16];
        int n = 0;
        boolean whole = false;

        for (final Map.Entry<Lane, double[]> entry : s.rects.entrySet()) {
            final double[] logical = entry.getValue();
            final Placement placement = s.placements.get(entry.getKey());
            final int kind = placement == null ? Placement.UNKNOWN_KIND : placement.kind;
            if (kind == Placement.ABSENT_KIND) {
                continue;
            }
            if (kind == Placement.UNKNOWN_KIND) {
                whole = true;
                continue;
            }
            if (placement.display != display) {
                continue;
            }
            if (!scaleRead) {
                scale = env.pixelsPerLogicalPixel(display);
                scaleRead = true;
            }
            if (!boundsRead) {
                bounds = env.displayBounds(display);
                boundsRead = true;
            }
            if (!(scale > 0) || Double.isInfinite(scale) || logical.length % 4 != 0) {
                whole = true;
                continue;
            }
            for (int i = 0; i < logical.length; i += 4) {
                final double l = logical[i];
                final double t = logical[i + 1];
                final double r = logical[i + 2];
                final double b = logical[i + 3];
                if (!isFinite(l) || !isFinite(t) || !isFinite(r) || !isFinite(b)) {
                    whole = true;
                    continue;
                }
                if (r <= l || b <= t) {
                    continue; // degenerate: nothing to hide
                }
                // Scale and place first, round outward last (5.3.1).
                int il = toInt(Math.floor(l * scale + placement.x));
                int it = toInt(Math.floor(t * scale + placement.y));
                int ir = toInt(Math.ceil(r * scale + placement.x));
                int ib = toInt(Math.ceil(b * scale + placement.y));
                if (bounds != null) {
                    il = clamp(il, bounds[0]);
                    ir = clamp(ir, bounds[0]);
                    it = clamp(it, bounds[1]);
                    ib = clamp(ib, bounds[1]);
                }
                if (ir <= il || ib <= it) {
                    continue; // nothing of it is on the display
                }
                if (n + 4 > out.length) {
                    out = Arrays.copyOf(out, out.length * 2);
                }
                out[n++] = il;
                out[n++] = it;
                out[n++] = ir;
                out[n++] = ib;
            }
        }

        if (whole) {
            // Something could not be placed or measured: cover everything. The
            // other rectangles are inside it, so they add nothing.
            if (!boundsRead) {
                bounds = env.displayBounds(display);
            }
            final int w = bounds == null ? FALLBACK_DISPLAY_SIZE : bounds[0];
            final int h = bounds == null ? FALLBACK_DISPLAY_SIZE : bounds[1];
            return w > 0 && h > 0 ? new int[] {0, 0, w, h} : new int[0];
        }
        return n == out.length ? out : Arrays.copyOf(out, n);
    }

    private static boolean isFinite(final double v) {
        return !Double.isNaN(v) && !Double.isInfinite(v);
    }

    private static int toInt(final double v) {
        return (int) Math.max(-LIMIT, Math.min(LIMIT, v));
    }

    private static int clamp(final int v, final int max) {
        return Math.max(0, Math.min(v, max));
    }

    /** For tests only: forgets everything. */
    void clearForTests() {
        synchronized (writeLock) {
            state = new State(new TreeMap<>(), new HashMap<>(), new HashMap<>());
        }
        synchronized (serveLock) {
            served.clear();
        }
        pullHook.set(null);
        environment = UNKNOWN_ENVIRONMENT;
    }
}
