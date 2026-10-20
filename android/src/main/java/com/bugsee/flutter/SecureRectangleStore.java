package com.bugsee.flutter;

import androidx.annotation.NonNull;

import com.bugsee.library.contracts.internal.BugseeWrapper;

import java.util.concurrent.ConcurrentHashMap;

/**
 * Where the secure-rectangle sets live (workbook 5.4.2): outside the wrapper
 * object, because the wrapper is replaced mid-session when Dart refines the
 * identity, and the regions must survive that or the app is recorded
 * unredacted until it next republishes.
 *
 * <p>Empty for now; Phase 3b fills it. A set is the SDK's packed buffer
 * {@code [version, count, l, t, r, b, ...]}, kept per display (5.2.3). Held as
 * published, never mutated afterwards, and handed out as a copy, so the SDK
 * thread that pulls it cannot see a half-written set (5.4.1).
 */
final class SecureRectangleStore {

    /**
     * {@link BugseeWrapper#SECURE_RECTANGLES_VERSION_UNKNOWN}: the SDK then
     * compares the rectangles themselves. A constant real version would let a
     * later set that also starts at that version, with real rectangles, be
     * ignored (the SDK caches by version per display: unredacted capture).
     */
    private static final int UNKNOWN_VERSION = BugseeWrapper.SECURE_RECTANGLES_VERSION_UNKNOWN;

    private static final SecureRectangleStore SHARED = new SecureRectangleStore();

    @NonNull
    static SecureRectangleStore shared() {
        return SHARED;
    }

    private final ConcurrentHashMap<Integer, int[]> sets = new ConcurrentHashMap<>();

    /** The set last published for {@code display}, or the empty set. */
    @NonNull
    int[] snapshot(final int display) {
        final int[] set = sets.get(display);
        return set == null ? new int[] {UNKNOWN_VERSION, 0} : set.clone();
    }

    /** Replaces the set for {@code display}. The buffer is copied. */
    void publish(final int display, @NonNull final int[] buffer) {
        sets.put(display, buffer.clone());
    }

    /** For tests only: forgets every set. */
    void clearForTests() {
        sets.clear();
    }
}
