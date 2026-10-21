package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Where the managed view hierarchy (the SDK's {@code vh} data request) lives, and what answers it.
 *
 * <h2>Why a cache</h2>
 *
 * <p>The SDK asks for {@code vh} from {@link FlutterWrapper#requestData} on the MAIN thread and
 * times the reply from when the call RETURNS (500 ms; {@code DataRequestTypes}). Flutter's
 * isolate cannot answer from there: a wait for Dart on the platform thread is a deadlock, and a
 * reply that comes later is recorded behind the report's snapshot barrier when the request was
 * made on the main thread (the SDK waits for a late reply only when the snapshot is made on
 * another thread; 7.4.2 includes bugsee-android #120 and still does not wait on the main thread).
 * So Dart PUSHES each snapshot here ({@link #publish}) and this class answers immediately, on any
 * thread, from memory.
 *
 * <h2>What is stored</h2>
 *
 * <p>The snapshot is a JSON TEMPLATE: text cut at the place of the snapshot's age and of every
 * node's box, plus the boxes in the view's LOGICAL pixels. The text is never parsed and never
 * changed except for those insertions. At answer time each box is converted by
 * {@link SecureRectangleStore.Mapper}, the code that places the secure rectangles: physical
 * pixels in the space of {@code View.getLocationOnScreen}, the unit of the native tree's
 * {@code bounds} (workbook 5.3, 6.6). The conversion needs the view's current position and the
 * display's density, so it is done per answer, never cached: a view that moved with no Dart frame
 * is served where it is.
 *
 * <h2>Fail closed</h2>
 *
 * <p>The answer is {@code null} (the SDK records nothing from the wrapper) when there is no
 * snapshot, when the view is not placed or is off screen, when a placement refresh is stuck,
 * when the density no longer matches the one the boxes were measured at, or when a box is not
 * finite. Never a partial answer. A message that is not shaped as documented in
 * {@code ViewHierarchyMessage}, or too large, clears the sender's snapshot.
 *
 * <h2>Ownership</h2>
 *
 * <p>Process-wide and outside the wrapper object (which is replaced when Dart refines the
 * identity), like the secure rectangles. Snapshots are per Dart isolate (owner = engine); an
 * engine's detach drops its snapshot ({@link #dropOwner}: a detached engine serves nothing, it is
 * never stale-served). With several engines the NEWEST snapshot is served and only if it can be
 * placed. State is immutable and swapped whole under a write lock; reads take no lock.
 *
 * <h2>Staleness</h2>
 *
 * <p>A snapshot is as of the last frame that changed the tree (plus the publisher's throttle,
 * 300 ms by default); Flutter draws nothing without a frame, so an unchanged screen is still
 * described exactly however old the snapshot. Its age is written into the payload
 * ({@code options.age_ms}) because the SDK stamps the entry with the time of the REPLY, not the
 * time of the snapshot. There is no maximum age: see doc/view-hierarchy.md.
 */
final class ViewHierarchyStore {

    /** The SDK's {@code DataRequestTypes.VIEW_HIERARCHY}. Compared with the SDK's source by a drift guard. */
    static final String TYPE = "vh";

    /** Most characters of template one snapshot may hold (a Dart-side cap of 256 KiB sits far below). */
    static final int MAX_TEMPLATE_CHARS = 1 << 20;

    /** Epochs remembered as retired, so a straggler of a dead isolate is ignored. */
    private static final int RETIRED_EPOCHS = 32;

    /** Largest magnitude served: the secure rectangles' limit (keeps the SDK's arithmetic safe). */
    private static final double LIMIT = 1 << 28;

    /** Milliseconds from a monotonic source. */
    interface Clock {
        long nowMs();
    }

    /** One snapshot of one view. Immutable. */
    private static final class Snapshot {
        final int viewId;
        final double ratio;
        final String[] segments;
        final double[] bounds;
        final long receivedMs;

        Snapshot(
                final int viewId,
                final double ratio,
                @NonNull final String[] segments,
                @NonNull final double[] bounds,
                final long receivedMs
        ) {
            this.viewId = viewId;
            this.ratio = ratio;
            this.segments = segments;
            this.bounds = bounds;
            this.receivedMs = receivedMs;
        }
    }

    /** What is known of one owner: its message ordering and its snapshot, if any. Immutable. */
    private static final class Entry {
        final long epoch;
        final long sequence;
        final List<Long> retired;
        @Nullable
        final Snapshot snapshot;

        Entry(
                final long epoch,
                final long sequence,
                @NonNull final List<Long> retired,
                @Nullable final Snapshot snapshot
        ) {
            this.epoch = epoch;
            this.sequence = sequence;
            this.retired = retired;
            this.snapshot = snapshot;
        }
    }

    private static final ViewHierarchyStore SHARED = new ViewHierarchyStore(
            SecureRectangleStore.shared(), () -> System.nanoTime() / 1_000_000L);

    @NonNull
    static ViewHierarchyStore shared() {
        return SHARED;
    }

    private final SecureRectangleStore placement;
    private final Clock clock;
    private final Object writeLock = new Object();
    private volatile Map<Long, Entry> owners = new HashMap<>();
    private final AtomicReference<Runnable> refresher = new AtomicReference<>();

    ViewHierarchyStore(@NonNull final SecureRectangleStore placement, @NonNull final Clock clock) {
        this.placement = placement;
        this.clock = clock;
    }

    /**
     * Installs what is run before every answer: a re-read of where the Flutter views are (the
     * placement tracker's refresh), synchronously when it is already on the main thread, which is
     * where the SDK asks. It must not block; it may only post.
     */
    void setRefresher(@Nullable final Runnable refresh) {
        refresher.set(refresh);
    }

    /**
     * Applies a message of {@code owner}. {@code segments} empty clears the owner's snapshot; a
     * malformed or oversize one clears it too (and is {@code true}: it was applied as a clear).
     * Returns {@code false}, changing nothing, for an older message or a retired epoch.
     */
    boolean publish(
            final long owner,
            final long epoch,
            final long sequence,
            final int viewId,
            final double ratio,
            @NonNull final List<String> segments,
            @NonNull final double[] bounds
    ) {
        synchronized (writeLock) {
            final Map<Long, Entry> previous = owners;
            final Entry last = previous.get(owner);
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
            final Snapshot snapshot = segments.isEmpty()
                    ? null : validated(viewId, ratio, segments, bounds);
            final Map<Long, Entry> next = new HashMap<>(previous);
            next.put(owner, new Entry(epoch, sequence, retired, snapshot));
            owners = next;
            return true;
        }
    }

    /** The shape rules of {@code ViewHierarchyMessage}; {@code null} when broken (fail closed). */
    @Nullable
    private Snapshot validated(
            final int viewId,
            final double ratio,
            @NonNull final List<String> segments,
            @NonNull final double[] bounds
    ) {
        if (bounds.length % 4 != 0 || segments.size() != bounds.length / 4 + 2) {
            return null;
        }
        long chars = 0;
        final String[] copy = new String[segments.size()];
        for (int i = 0; i < copy.length; i++) {
            final String segment = segments.get(i);
            if (segment == null) {
                return null;
            }
            chars += segment.length();
            if (chars > MAX_TEMPLATE_CHARS) {
                return null;
            }
            copy[i] = segment;
        }
        return new Snapshot(viewId, ratio, copy, bounds.clone(), clock.nowMs());
    }

    /** Dart's engine is gone: nothing of it is served any more. */
    void dropOwner(final long owner) {
        synchronized (writeLock) {
            if (!owners.containsKey(owner)) {
                return;
            }
            final Map<Long, Entry> next = new HashMap<>(owners);
            next.remove(owner);
            owners = next;
        }
    }

    /**
     * The SDK's {@code vh} answer: the newest snapshot rendered for the screen as it is now, or
     * {@code null}. Any thread; never blocks; never throws.
     */
    @Nullable
    String answer() {
        try {
            final Runnable refresh = refresher.get();
            if (refresh != null) {
                try {
                    refresh.run();
                } catch (Throwable ignored) {
                    // A placement that could not be refreshed is judged by the store.
                }
            }
            long newestOwner = 0;
            Snapshot newest = null;
            for (final Map.Entry<Long, Entry> e : owners.entrySet()) {
                final Snapshot s = e.getValue().snapshot;
                if (s != null && (newest == null || s.receivedMs > newest.receivedMs)) {
                    newest = s;
                    newestOwner = e.getKey();
                }
            }
            return newest == null ? null : render(newestOwner, newest);
        } catch (Throwable t) {
            return null;
        }
    }

    @Nullable
    private String render(final long owner, @NonNull final Snapshot s) {
        final SecureRectangleStore.Mapper mapper = placement.mapperFor(owner, s.viewId, s.ratio);
        if (mapper == null) {
            return null;
        }
        final long ageMs = Math.max(0, clock.nowMs() - s.receivedMs);
        final StringBuilder out = new StringBuilder(s.segments[0].length() + 64);
        out.append(s.segments[0]).append(ageMs).append(s.segments[1]);
        final int nodes = s.bounds.length / 4;
        for (int k = 0; k < nodes; k++) {
            final double l = s.bounds[4 * k];
            final double t = s.bounds[4 * k + 1];
            final double r = s.bounds[4 * k + 2];
            final double b = s.bounds[4 * k + 3];
            if (!isFinite(l) || !isFinite(t) || !isFinite(r) || !isFinite(b)) {
                return null;
            }
            // Scaled and placed first, rounded last, outward like the secure rectangles.
            final double left = Math.floor(mapper.px(l));
            final double top = Math.floor(mapper.py(t));
            final double right = Math.ceil(mapper.px(r));
            final double bottom = Math.ceil(mapper.py(b));
            if (!inRange(left) || !inRange(top) || !inRange(right) || !inRange(bottom)) {
                return null;
            }
            out.append('[').append((long) left).append(',').append((long) top).append(',')
                    .append((long) (right - left)).append(',').append((long) (bottom - top))
                    .append(']').append(s.segments[k + 2]);
        }
        return out.toString();
    }

    private static boolean isFinite(final double v) {
        return !Double.isNaN(v) && !Double.isInfinite(v);
    }

    private static boolean inRange(final double v) {
        return isFinite(v) && Math.abs(v) <= LIMIT;
    }

    /** For tests only: forgets everything. */
    void clearForTests() {
        synchronized (writeLock) {
            owners = new HashMap<>();
        }
        refresher.set(null);
    }
}
