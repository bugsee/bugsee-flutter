package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class PullThrottleTest {

    private long now;
    private int ran;

    private PullThrottle throttle() {
        return new PullThrottle(() -> now, Runnable::run, () -> ran++);
    }

    @Test
    public void theFirstPullAsksAndLaterOnesWaitForTheInterval() {
        final PullThrottle t = throttle();
        now = 1000;
        t.request();
        assertEquals(1, ran);
        now = 1000 + PullThrottle.MIN_INTERVAL_MS - 1;
        t.request();
        assertEquals("inside the window", 1, ran);
        now = 1000 + PullThrottle.MIN_INTERVAL_MS;
        t.request();
        assertEquals("window passed", 2, ran);
    }

    @Test
    public void aFailingExecutorNeverEscapesTheSdksThread() {
        final PullThrottle t = new PullThrottle(() -> now, r -> {
            throw new IllegalStateException("looper gone");
        }, () -> ran++);
        t.request();
        assertEquals(0, ran);
    }
}
