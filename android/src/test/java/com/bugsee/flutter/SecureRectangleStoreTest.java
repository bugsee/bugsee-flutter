package com.bugsee.flutter;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotSame;

import com.bugsee.library.contracts.internal.BugseeWrapper;

import org.junit.Test;

public class SecureRectangleStoreTest {

    @Test
    public void emptyUntilSomethingIsPublished() {
        final int[] s = new SecureRectangleStore().snapshot(0);
        assertArrayEquals(new int[] {BugseeWrapper.SECURE_RECTANGLES_VERSION_UNKNOWN, 0}, s);
    }

    @Test
    public void setsAreKeptPerDisplay() {
        final SecureRectangleStore store = new SecureRectangleStore();
        store.publish(0, new int[] {1, 0});
        store.publish(1, new int[] {5, 1, 1, 1, 2, 2});
        assertEquals(1, store.snapshot(0)[0]);
        assertEquals(5, store.snapshot(1)[0]);
    }

    /** 5.4.1: what the SDK reads is not what a caller can still mutate. */
    @Test
    public void snapshotsAreImmutableCopies() {
        final SecureRectangleStore store = new SecureRectangleStore();
        final int[] mine = {3, 0};
        store.publish(0, mine);
        mine[0] = 99;
        assertEquals(3, store.snapshot(0)[0]);
        final int[] read = store.snapshot(0);
        read[0] = 77;
        assertEquals(3, store.snapshot(0)[0]);
        assertNotSame(store.snapshot(0), store.snapshot(0));
    }
}
