package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.internal.BugseeWrapper;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
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
 * <p>Dart publishes Flutter LOGICAL pixels (Android dp) relative to its view,
 * with the device pixel ratio it measured them at. This class multiplies by
 * that ratio, scales by the view's own on-screen scale, adds the view's
 * position on the screen, then rounds OUTWARD (floor {@code l}/{@code t}, ceil
 * {@code r}/{@code b}), scaling BEFORE rounding so no sub-pixel strip is left
 * uncovered (5.1.2, 5.3.1). The display's density is read at every pull and
 * must equal the ratio the rectangles were measured at: a density change is
 * applied natively before Dart lays out again, and old logical rectangles times
 * a new density cover neither the old nor the new content, so until Dart
 * republishes at the new ratio the whole display is covered.
 *
 * <h2>Versions</h2>
 *
 * <p>A display's version is derived from what is served, not from what was
 * written: it moves exactly when the served rectangles differ from the ones
 * served before (so also when only the density, the view's position or a past
 * set's grace window ending changed, which no write announces), and never otherwise (5.2.1,
 * 5.2.2). It is kept per display (5.2.3) and only ever steps forward, skipping
 * 0. A display that has never had a rectangle serves {@code [0, 0]}: unknown,
 * and empty. Once it has had one it serves real versions, an emptied set
 * included ({@code [v, 0]}).
 *
 * <h2>Grace window</h2>
 *
 * <p>Dart measures after a frame and the message crosses a channel, while the
 * raster of that frame (or the one before) may be captured first. So every set
 * that stops being current is served as well for {@link #GRACE_MS} from the
 * moment IT stopped (not from the last change, so a long movement does not widen
 * the cover to its whole path): a moving region leaves no uncovered strip as wide
 * as one frame's movement, and a region that has just gone is covered a little
 * longer.
 * It only ever over-covers. A region that has just APPEARED has no previous
 * position, so its first frame can still be recorded before the message lands:
 * the one exposure this class cannot close. The union shrinks back on a later
 * pull, which is a change of the served set and so moves the version.
 *
 * <h2>Fail closed</h2>
 *
 * <p>A view whose placement is not known (the Flutter view has not been found,
 * or is ambiguous, or is transformed by more than a scale) is served as one
 * rectangle covering the whole display. A rectangle that is not finite does the
 * same, and so does a scale or ratio that is not a positive finite number or
 * does not match the display's density. A view known to be off screen serves
 * nothing.
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
     * not known (or reads as zero): more than any panel, small enough not to
     * overflow an int when the SDK scales it.
     */
    static final int FALLBACK_DISPLAY_SIZE = 16384;

    /** Largest magnitude served: keeps the SDK's own int arithmetic away from overflow. */
    private static final double LIMIT = 1 << 28;

    /**
     * A placement refresh that was asked for by a pull and has not completed for this long means
     * the main thread is not answering: the placements may be stale by an unknown amount, so every
     * placed view is covered whole until a refresh completes. A refresh normally completes within
     * milliseconds of the pull that asked, so this never fires in ordinary running (and is
     * independent of how often the SDK pulls). Repeated nowhere else.
     */
    static final long REFRESH_STALE_MS = 1000;

    /** How long each past set is served after it stopped being current. Repeated in ObjC. */
    static final long GRACE_MS = 120;

    /** More rectangles than this and the past sets still being served are collapsed to their bounding box. */
    private static final int MAX_RECTANGLES = 64;

    /** The densities a message may differ from the display's by (floating-point noise). */
    private static final double RATIO_TOLERANCE = 1e-3;

    /** Epochs remembered as retired, so a straggler of a dead isolate is ignored. */
    private static final int RETIRED_EPOCHS = 32;

    /** What the store needs to know about the device, read at every pull. */
    interface Environment {
        /**
         * The display's physical pixels per Flutter logical pixel right now
         * (Android: {@code DisplayMetrics.density} of the Flutter view). Read
         * per call, never cached. Not finite or not positive means "unknown"
         * and fails closed.
         */
        double nativePixelRatio(int display);

        /**
         * SDK units per physical pixel: 1 on Android (the SDK takes physical
         * pixels).
         */
        double unitsPerPhysicalPixel(int display);

        /** The display's current size in pixels, {@code {width, height}}, or {@code null}. */
        @Nullable
        int[] displayBounds(int display);
    }

    /** Knows nothing: every view covers the whole display. Until a plugin installs the real one. */
    static final Environment UNKNOWN_ENVIRONMENT = new Environment() {
        @Override
        public double nativePixelRatio(final int display) {
            return Double.NaN;
        }

        @Override
        public double unitsPerPhysicalPixel(final int display) {
            return 1;
        }

        @Nullable
        @Override
        public int[] displayBounds(final int display) {
            return null;
        }
    };

    /** Milliseconds from a monotonic source. */
    interface Clock {
        long nowMs();
    }

    /** What one view published: the ratio it was measured at and its flat logical ltrb. */
    static final class ViewRects {
        final double ratio;
        final double[] rects;

        ViewRects(final double ratio, @NonNull final double[] rects) {
            this.ratio = ratio;
            this.rects = rects;
        }
    }

    /** Where one Flutter view sits, in the unit and space the SDK wants. */
    static final class Placement {
        static final int KNOWN_KIND = 0;
        static final int UNKNOWN_KIND = 1;
        static final int ABSENT_KIND = 2;

        /** The view's position is not known: serve the whole display. */
        static final Placement UNKNOWN = new Placement(UNKNOWN_KIND, 0, 0, 0, 1, 1);
        /** The view is known not to be on screen: serve nothing. */
        static final Placement ABSENT = new Placement(ABSENT_KIND, 0, 0, 0, 1, 1);

        final int kind;
        final int display;
        /** The view's top-left on the display, in physical pixels. */
        final double x;
        final double y;
        /** The view's own scale on the screen (it, or an ancestor, is scaled); 1 normally. */
        final double scaleX;
        final double scaleY;

        private Placement(
                final int kind,
                final int display,
                final double x,
                final double y,
                final double scaleX,
                final double scaleY
        ) {
            this.kind = kind;
            this.display = display;
            this.x = x;
            this.y = y;
            this.scaleX = scaleX;
            this.scaleY = scaleY;
        }

        static Placement known(final int display, final double x, final double y) {
            return known(display, x, y, 1, 1);
        }

        static Placement known(
                final int display,
                final double x,
                final double y,
                final double scaleX,
                final double scaleY
        ) {
            return new Placement(KNOWN_KIND, display, x, y, scaleX, scaleY);
        }

        @Override
        public boolean equals(final Object o) {
            if (!(o instanceof Placement)) {
                return false;
            }
            final Placement p = (Placement) o;
            return kind == p.kind && display == p.display && x == p.x && y == p.y
                    && scaleX == p.scaleX && scaleY == p.scaleY;
        }

        @Override
        public int hashCode() {
            return Arrays.hashCode(new double[] {kind, display, x, y, scaleX, scaleY});
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

    /** The ordering state of one owner. Immutable. */
    private static final class Order {
        final long epoch;
        final long sequence;
        final List<Long> retired;

        Order(final long epoch, final long sequence, @NonNull final List<Long> retired) {
            this.epoch = epoch;
            this.sequence = sequence;
            this.retired = retired;
        }
    }

    /** Immutable. Replaced wholesale on every write. */
    private static final class State {
        final TreeMap<Lane, ViewRects> rects;
        final Map<Lane, Placement> placements;
        final Map<Long, Order> order;

        State(
                final TreeMap<Lane, ViewRects> rects,
                final Map<Lane, Placement> placements,
                final Map<Long, Order> order
        ) {
            this.rects = rects;
            this.placements = placements;
            this.order = order;
        }
    }

    /** A set that stopped being current, and until when it is still served. Immutable. */
    private static final class Past {
        final int[] quads;
        final long untilMs;

        Past(@NonNull final int[] quads, final long untilMs) {
            this.quads = quads;
            this.untilMs = untilMs;
        }
    }

    /** What a display last served. Immutable. */
    private static final class Served {
        final int version;
        /** What is served: the current set plus every past set still inside its window. */
        final int[] quads;
        final int[] current;
        /** Newest first. Each is served until {@code GRACE_MS} after it stopped being current. */
        final List<Past> past;
        final int[] buffer;

        Served(
                final int version,
                @NonNull final int[] quads,
                @NonNull final int[] current,
                @NonNull final List<Past> past
        ) {
            this.version = version;
            this.quads = quads;
            this.current = current;
            this.past = past;
            this.buffer = new int[HEADER_INTS + quads.length];
            buffer[0] = version;
            buffer[1] = quads.length / 4;
            System.arraycopy(quads, 0, buffer, HEADER_INTS, quads.length);
        }
    }

    private static final int[] NONE = new int[0];

    private static final SecureRectangleStore SHARED = new SecureRectangleStore(
            UNKNOWN_ENVIRONMENT, () -> System.nanoTime() / 1_000_000L, GRACE_MS);

    @NonNull
    static SecureRectangleStore shared() {
        return SHARED;
    }

    private volatile Environment environment;
    private final Clock clock;
    private final long graceMs;
    private volatile State state = new State(new TreeMap<>(), new HashMap<>(), new HashMap<>());
    private final Object writeLock = new Object();
    private final Object serveLock = new Object();
    private final Map<Integer, Served> served = new HashMap<>();
    private final AtomicReference<Runnable> pullHook = new AtomicReference<>();
    private static final long NO_REFRESH_PENDING = Long.MIN_VALUE;
    /** When the oldest refresh that a pull asked for was asked; none while all completed. */
    private final java.util.concurrent.atomic.AtomicLong refreshPendingSince =
            new java.util.concurrent.atomic.AtomicLong(NO_REFRESH_PENDING);

    /** No grace window: what is written is what is served at once. For tests. */
    SecureRectangleStore(@NonNull final Environment environment) {
        this(environment, () -> System.nanoTime() / 1_000_000L, 0);
    }

    SecureRectangleStore(
            @NonNull final Environment environment,
            @NonNull final Clock clock,
            final long graceMs
    ) {
        this.environment = environment;
        this.clock = clock;
        this.graceMs = graceMs;
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
     * id to what it published; a view not in the map has no rectangles any
     * more. Ignored, and {@code false}, when {@code epoch} is the current one
     * and {@code sequence} is not newer, or when {@code epoch} was retired (a
     * straggler of a dead isolate). An epoch not seen before is a new isolate
     * (a hot restart): it replaces the old one's state and retires its epoch.
     * Epochs are random ids, never clocks.
     */
    boolean publish(
            final long owner,
            final long epoch,
            final long sequence,
            @NonNull final Map<Integer, ViewRects> views
    ) {
        synchronized (writeLock) {
            final State previous = state;
            final Order last = previous.order.get(owner);
            List<Long> retired = new ArrayList<>();
            if (last != null) {
                if (last.retired.contains(epoch)) {
                    return false;
                }
                if (epoch == last.epoch) {
                    if (sequence <= last.sequence) {
                        return false;
                    }
                    retired = last.retired;
                } else {
                    retired = new ArrayList<>(last.retired);
                    retired.add(last.epoch);
                    while (retired.size() > RETIRED_EPOCHS) {
                        retired.remove(0);
                    }
                }
            }
            final TreeMap<Lane, ViewRects> rects = new TreeMap<>();
            for (final Map.Entry<Lane, ViewRects> e : previous.rects.entrySet()) {
                if (e.getKey().owner != owner) {
                    rects.put(e.getKey(), e.getValue());
                }
            }
            for (final Map.Entry<Integer, ViewRects> e : views.entrySet()) {
                if (e.getValue().rects.length > 0) {
                    rects.put(new Lane(owner, e.getKey()),
                            new ViewRects(e.getValue().ratio, e.getValue().rects.clone()));
                }
            }
            final Map<Long, Order> order = new HashMap<>(previous.order);
            order.put(owner, new Order(epoch, sequence, retired));
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
            final TreeMap<Lane, ViewRects> rects = new TreeMap<>();
            for (final Map.Entry<Lane, ViewRects> e : previous.rects.entrySet()) {
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
            final Map<Long, Order> order = new HashMap<>(previous.order);
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
     * A placement refresh was actually handed to the main thread (call it only for a request that
     * was posted, never for one the throttle dropped: with nothing in flight there is nothing to
     * wait for). The OLDEST unanswered request counts.
     */
    void refreshRequested() {
        refreshPendingSince.compareAndSet(NO_REFRESH_PENDING, clock.nowMs());
    }

    /**
     * The placement refresh the pull asked for has finished (the tracker calls this after it
     * re-read every view): the placements are fresh again.
     */
    void refreshCompleted() {
        refreshPendingSince.set(NO_REFRESH_PENDING);
    }

    /**
     * The buffer for {@code display}: {@code [version, count, l, t, r, b, ...]}.
     * Computed from the current state, density and size at this call; a fresh
     * array every time.
     */
    @NonNull
    int[] snapshot(final int display) {
        synchronized (serveLock) {
            final long now = clock.nowMs();
            final int[] target = serve(state, display);
            final Served last = served.get(display);
            if (last == null) {
                if (target.length == 0) {
                    return new int[] {UNKNOWN_VERSION, 0};
                }
                final Served first = new Served(1, target, target, new ArrayList<>());
                served.put(display, first);
                return first.buffer.clone();
            }
            // Sets that stopped being current are served for a window each, counted from
            // the moment THEY stopped (not from the last change), so a long movement keeps
            // only the last window's worth of places instead of its whole path.
            final List<Past> past = new ArrayList<>();
            if (graceMs > 0 && !Arrays.equals(target, last.current) && last.current.length > 0) {
                past.add(new Past(last.current, now + graceMs));
            }
            for (final Past p : last.past) {
                if (p.untilMs > now) {
                    past.add(p);
                }
            }
            int[] out = target;
            for (final Past p : past) {
                out = union(out, p.quads);
            }
            final int version = Arrays.equals(out, last.quads)
                    ? last.version : advance(last.version);
            final Served next = new Served(version, out, target, past);
            served.put(display, next);
            return next.buffer.clone();
        }
    }

    /** The rectangles of {@code a} then those of {@code b} that are not in {@code a}. */
    @NonNull
    private static int[] union(@NonNull final int[] a, @NonNull final int[] b) {
        if (b.length == 0) {
            return a;
        }
        int[] extra = new int[b.length];
        int n = 0;
        for (int i = 0; i < b.length; i += 4) {
            boolean present = false;
            for (int j = 0; j < a.length && !present; j += 4) {
                present = a[j] == b[i] && a[j + 1] == b[i + 1]
                        && a[j + 2] == b[i + 2] && a[j + 3] == b[i + 3];
            }
            if (!present) {
                System.arraycopy(b, i, extra, n, 4);
                n += 4;
            }
        }
        if (n == 0) {
            return a;
        }
        if ((a.length + n) / 4 > MAX_RECTANGLES) {
            // Too many to carry: cover the previous ones by their bounding box (more, never less).
            int l = Integer.MAX_VALUE, t = Integer.MAX_VALUE, r = Integer.MIN_VALUE, bt = Integer.MIN_VALUE;
            for (int i = 0; i < n; i += 4) {
                l = Math.min(l, extra[i]);
                t = Math.min(t, extra[i + 1]);
                r = Math.max(r, extra[i + 2]);
                bt = Math.max(bt, extra[i + 3]);
            }
            extra = new int[] {l, t, r, bt};
            n = 4;
        }
        final int[] out = Arrays.copyOf(a, a.length + n);
        System.arraycopy(extra, 0, out, a.length, n);
        return out;
    }

    /** The version after {@code version}: wraps, and never lands on 0 ("unknown"). */
    static int advance(final int version) {
        final int next = version + 1;
        return next == UNKNOWN_VERSION ? next + 1 : next;
    }

    /** The physical-pixel rectangles {@code display} should serve for {@code s}, flat ltrb. */
    @NonNull
    private int[] serve(@NonNull final State s, final int display) {
        final Environment env = environment;
        double nativeRatio = Double.NaN;
        double unit = 1;
        boolean envRead = false;
        int[] bounds = null;

        int[] out = new int[16];
        int n = 0;
        boolean whole = false;
        final long pendingSince = refreshPendingSince.get();
        final boolean refreshStuck = pullHook.get() != null && pendingSince != NO_REFRESH_PENDING
                && clock.nowMs() - pendingSince > REFRESH_STALE_MS;

        for (final Map.Entry<Lane, ViewRects> entry : s.rects.entrySet()) {
            final ViewRects view = entry.getValue();
            final double[] logical = view.rects;
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
            if (refreshStuck) {
                // The placement may be stale by an unknown amount: cover rather than trust it.
                whole = true;
                continue;
            }
            if (!envRead) {
                nativeRatio = env.nativePixelRatio(display);
                unit = env.unitsPerPhysicalPixel(display);
                bounds = env.displayBounds(display);
                envRead = true;
            }
            final double ratio = view.ratio;
            final double factor = ratio * unit;
            final double sx = placement.scaleX;
            final double sy = placement.scaleY;
            if (!isUsable(ratio) || !isUsable(nativeRatio) || !isUsable(unit)
                    || !isUsable(sx) || !isUsable(sy)
                    || Math.abs(nativeRatio - ratio) > RATIO_TOLERANCE * Math.max(1, ratio)
                    || logical.length % 4 != 0) {
                // Measured at another density than the display has now, or not measurable.
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
                int il = toInt(Math.floor(l * factor * sx + placement.x));
                int it = toInt(Math.floor(t * factor * sy + placement.y));
                int ir = toInt(Math.ceil(r * factor * sx + placement.x));
                int ib = toInt(Math.ceil(b * factor * sy + placement.y));
                if (bounds != null && bounds[0] > 0 && bounds[1] > 0) {
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
            if (!envRead) {
                bounds = env.displayBounds(display);
            }
            final boolean known = bounds != null && bounds[0] > 0 && bounds[1] > 0;
            final int w = known ? bounds[0] : FALLBACK_DISPLAY_SIZE;
            final int h = known ? bounds[1] : FALLBACK_DISPLAY_SIZE;
            return new int[] {0, 0, w, h};
        }
        return n == out.length ? out : Arrays.copyOf(out, n);
    }

    private static boolean isUsable(final double v) {
        return v > 0 && !Double.isInfinite(v);
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
