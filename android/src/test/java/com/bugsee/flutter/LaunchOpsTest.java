package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import com.bugsee.library.contracts.lifecycle.BugseeStatus;
import com.bugsee.library.contracts.options.VideoMode;

import org.junit.Test;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Launch, stop and status decisions with a fake SDK behind the seam: what reaches the SDK, what
 * does not, and what Dart is told. The real SDK's behaviour on each path is read from its source
 * (BugseeInternal.launchOnce, v7.4.2) and noted at each test.
 */
public class LaunchOpsTest {

    /** Records what reaches the SDK and answers as scripted. */
    private static final class FakeSdk implements LaunchOps.Sdk {
        String status = "stopped";
        boolean launchResult = true;
        /** How many times the SDK calls its completion back (a misbehaving SDK calls it twice). */
        int callbacks = 1;
        boolean throwAfterCallback;
        /** Throws, but leaves its callback to be called later (another thread). */
        boolean throwLeavingCallback;
        LaunchOps.Done leftCallback;
        RuntimeException launchThrows;
        final List<String> launches = new ArrayList<>();
        Map<String, Serializable> launchedWith;
        int stops;
        boolean stopCalledBack = true;
        int stopCallbacks = 1;
        boolean throwAfterStop;
        Map<String, Serializable> options = new HashMap<>();
        Boolean lastHostOnly;

        @Override
        public String status() {
            return status;
        }

        @Override
        public void launch(String token, Map<String, Serializable> opts, LaunchOps.Done done) {
            if (launchThrows != null) {
                throw launchThrows;
            }
            launches.add(token);
            launchedWith = opts;
            if (throwLeavingCallback) {
                leftCallback = done;
                throw new IllegalStateException("threw, callback comes later");
            }
            for (int i = 0; i < callbacks; i++) {
                done.run(launchResult);
            }
            if (throwAfterCallback) {
                throw new IllegalStateException("after the callback");
            }
        }

        @Override
        public void stop(Runnable done) {
            stops++;
            if (stopCalledBack) {
                for (int i = 0; i < stopCallbacks; i++) {
                    done.run();
                }
            }
            if (throwAfterStop) {
                throw new IllegalStateException("after the stop callback");
            }
        }

        @Override
        public Map<String, ? extends Serializable> launchOptions(boolean hostOnly) {
            lastHostOnly = hostOnly;
            return options;
        }
    }

    private static final class Recorder implements LaunchOps.Reply, LaunchOps.ErrorSink {
        final List<String> outcomes = new ArrayList<>();
        final List<String> reasons = new ArrayList<>();
        final List<Throwable> errors = new ArrayList<>();

        @Override
        public void outcome(String outcome, String reason) {
            outcomes.add(outcome);
            reasons.add(reason);
        }

        @Override
        public void error(Throwable error) {
            errors.add(error);
        }
    }

    private static Map<String, Object> flat(String key, Object value) {
        final Map<String, Object> m = new HashMap<>();
        m.put(key, value);
        return m;
    }

    @Test
    public void aStoppedSdkIsLaunchedWithTheTranslatedOptionsAndAnswersLaunched() {
        final FakeSdk sdk = new FakeSdk();
        final Recorder r = new Recorder();
        LaunchOps.launch(sdk, "tok", flat("com.bugsee.option.capture.video.mode", 20), r, r);
        assertEquals(java.util.Collections.singletonList("tok"), sdk.launches);
        // The number became the SDK's constant (never an ordinal).
        assertSame(VideoMode.Fullscreen, sdk.launchedWith.get("com.bugsee.option.capture.video.mode"));
        assertEquals(java.util.Collections.singletonList(LaunchOps.LAUNCHED), r.outcomes);
        assertNull(r.reasons.get(0));
        assertTrue(r.errors.isEmpty());
    }

    @Test
    public void anSdkThatCallsBackTwiceIsAnsweredOnce() {
        final FakeSdk sdk = new FakeSdk();
        sdk.callbacks = 2;
        final Recorder r = new Recorder();
        LaunchOps.launch(sdk, "tok", null, r, r);
        assertEquals(java.util.Collections.singletonList(LaunchOps.LAUNCHED), r.outcomes);
        assertTrue(r.errors.isEmpty());
    }

    @Test
    public void anSdkThatThrowsAndCallsBackLaterAnswersOnlyTheError() {
        final FakeSdk sdk = new FakeSdk();
        sdk.throwLeavingCallback = true;
        final Recorder r = new Recorder();
        LaunchOps.launch(sdk, "tok", null, r, r);
        assertEquals(1, r.errors.size());
        sdk.leftCallback.run(true); // the SDK's other thread, later
        assertTrue("no second answer", r.outcomes.isEmpty());
    }

    @Test
    public void anSdkThatCallsBackAndThenThrowsHasAlreadyBeenAnswered() {
        final FakeSdk sdk = new FakeSdk();
        sdk.throwAfterCallback = true;
        final Recorder r = new Recorder();
        LaunchOps.launch(sdk, "tok", null, r, r);
        assertEquals(java.util.Collections.singletonList(LaunchOps.LAUNCHED), r.outcomes);
        assertTrue("not also an error", r.errors.isEmpty());
    }

    @Test
    public void anSdkAlreadyLaunchingOrLaunchedIsNotLaunchedAgain() {
        // SDK source: launchOnce returns ALREADY_LAUNCHED and drops the options, with only a log;
        // its Boolean callback says true, which cannot be told from a real launch. So status first.
        for (final String running : new String[] {"launching", "launched"}) {
            final FakeSdk sdk = new FakeSdk();
            sdk.status = running;
            final Recorder r = new Recorder();
            LaunchOps.launch(sdk, "tok", flat("com.bugsee.option.capture.logs", false), r, r);
            assertTrue(running, sdk.launches.isEmpty());
            assertEquals(running, java.util.Collections.singletonList(LaunchOps.ALREADY_RUNNING), r.outcomes);
        }
    }

    @Test
    public void aLaunchDuringAStopIsRefusedAsTheSdkRefusesIt() {
        // SDK source: launchOnce, state STOPPING -> REFUSED_STOPPING ("launch from the completion
        // callback of stop()").
        final FakeSdk sdk = new FakeSdk();
        sdk.status = "stopping";
        final Recorder r = new Recorder();
        LaunchOps.launch(sdk, "tok", null, r, r);
        assertTrue(sdk.launches.isEmpty());
        assertEquals(LaunchOps.REFUSED, r.outcomes.get(0));
        assertEquals(LaunchOps.STOPPING, r.reasons.get(0));
    }

    @Test
    public void aBlankTokenNeverReachesTheSdk() {
        for (final String token : new String[] {null, "", "  \n"}) {
            final FakeSdk sdk = new FakeSdk();
            final Recorder r = new Recorder();
            LaunchOps.launch(sdk, token, null, r, r);
            assertTrue(sdk.launches.isEmpty());
            assertEquals(LaunchOps.REFUSED, r.outcomes.get(0));
            assertEquals(LaunchOps.INVALID_TOKEN, r.reasons.get(0));
        }
    }

    @Test
    public void anSdkThatDeclinesIsRefusedAsFailed() {
        // SDK source: false for an invalid token, no context, a failed capture start, a stop that
        // overtook the launch; the reason is in its log only.
        final FakeSdk sdk = new FakeSdk();
        sdk.launchResult = false;
        final Recorder r = new Recorder();
        LaunchOps.launch(sdk, "tok", null, r, r);
        assertEquals(LaunchOps.REFUSED, r.outcomes.get(0));
        assertEquals(LaunchOps.FAILED, r.reasons.get(0));
    }

    @Test
    public void anExceptionFromTheSdkIsReportedAsAnErrorAndNeverAsAnOutcome() {
        final FakeSdk sdk = new FakeSdk();
        sdk.launchThrows = new IllegalStateException("boom");
        final Recorder r = new Recorder();
        LaunchOps.launch(sdk, "tok", null, r, r);
        assertTrue(r.outcomes.isEmpty());
        assertEquals(1, r.errors.size());
        assertEquals("boom", r.errors.get(0).getMessage());
    }

    @Test
    public void stopCallsTheSdkAndAnswersWhenItHasStopped() {
        final FakeSdk sdk = new FakeSdk();
        final int[] done = {0};
        final Recorder r = new Recorder();
        LaunchOps.stop(sdk, () -> done[0]++, r);
        assertEquals(1, sdk.stops);
        assertEquals(1, done[0]);
        // A stop that has not completed has not been answered.
        final FakeSdk slow = new FakeSdk();
        slow.stopCalledBack = false;
        LaunchOps.stop(slow, () -> done[0]++, r);
        assertEquals(1, done[0]);
    }

    @Test
    public void aStopIsAnsweredOnce_whateverTheSdkDoesAfterwards() {
        final FakeSdk twice = new FakeSdk();
        twice.stopCallbacks = 2;
        final int[] done = {0};
        final Recorder r = new Recorder();
        LaunchOps.stop(twice, () -> done[0]++, r);
        assertEquals(1, done[0]);
        final FakeSdk late = new FakeSdk();
        late.throwAfterStop = true;
        LaunchOps.stop(late, () -> done[0]++, r);
        assertEquals(2, done[0]);
        assertTrue("not also an error", r.errors.isEmpty());
    }

    @Test
    public void statusCrossesByNameNeverByOrdinal() {
        assertEquals("stopped", LaunchOps.statusName(BugseeStatus.Stopped));
        assertEquals("launching", LaunchOps.statusName(BugseeStatus.Launching));
        assertEquals("launched", LaunchOps.statusName(BugseeStatus.Launched));
        assertEquals("stopping", LaunchOps.statusName(BugseeStatus.Stopping));
        // The SDK has exactly these four, and "do not persist or transmit the ordinal".
        assertEquals(4, BugseeStatus.values().length);
        final FakeSdk sdk = new FakeSdk();
        sdk.status = "launching";
        assertEquals("launching", LaunchOps.status(sdk));
    }

    @Test
    public void theLaunchOptionsReadBackAreConvertedAndAskedForByKind() {
        final FakeSdk sdk = new FakeSdk();
        sdk.options.put("com.bugsee.option.capture.video.mode", VideoMode.DirectBuffers);
        sdk.options.put("com.bugsee.option.performance.sample-rate", 0.25f);
        final Map<String, Object> merged = LaunchOps.launchOptions(sdk, false);
        assertEquals(Boolean.FALSE, sdk.lastHostOnly);
        assertEquals(21, merged.get("com.bugsee.option.capture.video.mode"));
        assertEquals(0.25d, merged.get("com.bugsee.option.performance.sample-rate"));
        LaunchOps.launchOptions(sdk, true);
        assertEquals(Boolean.TRUE, sdk.lastHostOnly);
    }

    @Test
    public void theBridgeVocabularyIsWhatDartExpects() {
        assertEquals("launched", LaunchOps.LAUNCHED);
        assertEquals("already-running", LaunchOps.ALREADY_RUNNING);
        assertEquals("refused", LaunchOps.REFUSED);
        assertEquals("invalid-token", LaunchOps.INVALID_TOKEN);
        assertEquals("stopping", LaunchOps.STOPPING);
        assertEquals("failed", LaunchOps.FAILED);
        assertEquals("launch-failed", LaunchOps.ERROR_CODE);
    }
}
