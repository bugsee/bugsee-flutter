package com.bugsee.flutter.feedback;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import com.bugsee.library.contracts.feedback.FeedbackListener;

import org.junit.Before;
import org.junit.Test;

import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.Queue;
import java.util.concurrent.Executor;

public class FeedbackOpsTest {

    /** The SDK's feedback module: records what reaches it. */
    static final class FakeSdk implements FeedbackSdk {
        boolean registered = true;
        RuntimeException throwOnCall;
        final List<String> calls = new ArrayList<>();
        FeedbackListener listener;

        private void check(final String call) {
            calls.add(call);
            if (!registered) {
                throw new FeedbackException(FeedbackOps.NOT_REGISTERED, "none");
            }
            if (throwOnCall != null) {
                throw throwOnCall;
            }
        }

        @Override
        public boolean isRegistered() {
            return registered;
        }

        @Override
        public boolean registerIfMissing() {
            return false;
        }

        @Override
        public void show() {
            check("show");
        }

        @Override
        public void setGreeting(final String greeting) {
            check("greeting:" + greeting);
        }

        @Override
        public void setListener(final FeedbackListener l) {
            check("listener:" + (l == null ? "null" : "set"));
            listener = l;
        }
    }

    /** The platform thread: runs only when the test lets it. */
    static final class Main implements Executor {
        final Queue<Runnable> queue = new ArrayDeque<>();

        @Override
        public void execute(final Runnable command) {
            queue.add(command);
        }

        void drain() {
            while (!queue.isEmpty()) {
                queue.remove().run();
            }
        }
    }

    static final class Recorder implements FeedbackOps.Sink {
        final List<List<String>> received = new ArrayList<>();
        final List<String> sent = new ArrayList<>();

        @Override
        public void messagesReceived(final List<String> messages) {
            received.add(messages);
        }

        @Override
        public void messageSent(final String message) {
            sent.add(message);
        }
    }

    private FakeSdk sdk;
    private Main main;
    private Recorder sink;
    private FeedbackOps ops;

    @Before
    public void setUp() {
        FeedbackOps.resetSlotForTesting();
        sdk = new FakeSdk();
        main = new Main();
        sink = new Recorder();
        ops = new FeedbackOps(sdk, main, sink);
    }

    private static String codeOf(final Runnable r) {
        try {
            r.run();
        } catch (final FeedbackException e) {
            return e.code;
        }
        fail("no FeedbackException");
        return null;
    }

    // ---- show / greeting ----

    @Test
    public void showReachesTheSdk() {
        ops.show();
        assertEquals(Collections.singletonList("show"), sdk.calls);
    }

    @Test
    public void greetingIsPassedOnAsIsAndNullClears() {
        ops.setGreeting("How can we help?");
        ops.setGreeting(null);
        ops.setGreeting("");
        assertEquals(Arrays.asList("greeting:How can we help?", "greeting:null", "greeting:"), sdk.calls);
    }

    @Test
    public void aMissingModuleIsNotRegistered() {
        sdk.registered = false;
        assertEquals(FeedbackOps.NOT_REGISTERED, codeOf(ops::show));
        assertEquals(FeedbackOps.NOT_REGISTERED, codeOf(() -> ops.setGreeting("x")));
        assertEquals(FeedbackOps.NOT_REGISTERED, codeOf(() -> ops.setListenerEnabled(true)));
    }

    @Test
    public void anSdkThrowIsAnSdkErrorThatNeverQuotesTheMessage() {
        sdk.throwOnCall = new IllegalStateException("secret chat text");
        try {
            ops.show();
            fail();
        } catch (final FeedbackException e) {
            assertEquals(FeedbackOps.SDK_ERROR, e.code);
            assertTrue(e.getMessage().contains("IllegalStateException"));
            assertFalse(e.getMessage().contains("secret"));
        }
    }

    @Test
    public void attachSaysWhetherTheModuleIsRegistered() {
        assertTrue(ops.attach());
        sdk.registered = false;
        assertFalse(ops.attach());
    }

    // ---- listener ----

    @Test
    public void receivedMessagesGoToTheSinkOnTheMainThreadInOrder() {
        ops.setListenerEnabled(true);
        assertNotNull(sdk.listener);
        sdk.listener.onNewMessagesReceived(Arrays.asList("a", "b"));
        // Still on the SDK's worker thread: nothing yet.
        assertTrue(sink.received.isEmpty());
        main.drain();
        assertEquals(Collections.singletonList(Arrays.asList("a", "b")), sink.received);
    }

    @Test
    public void nullEntriesAreOmittedAndAnEmptyBatchIsNotDelivered() {
        ops.setListenerEnabled(true);
        sdk.listener.onNewMessagesReceived(Arrays.asList("a", null, "b"));
        sdk.listener.onNewMessagesReceived(Arrays.asList(null, null));
        sdk.listener.onNewMessagesReceived(null);
        sdk.listener.onNewMessagesReceived(new ArrayList<String>());
        main.drain();
        assertEquals(Collections.singletonList(Arrays.asList("a", "b")), sink.received);
    }

    @Test
    public void sentMessagesGoToTheSinkAndANullOneDoesNot() {
        ops.setListenerEnabled(true);
        sdk.listener.onNewMessageSent("hello");
        sdk.listener.onNewMessageSent(null);
        main.drain();
        assertEquals(Collections.singletonList("hello"), sink.sent);
    }

    @Test
    public void disablingRemovesTheSdkListenerAndDropsWhatIsQueued() {
        ops.setListenerEnabled(true);
        final FeedbackListener installed = sdk.listener;
        installed.onNewMessagesReceived(Collections.singletonList("late"));
        ops.setListenerEnabled(false);
        assertNull(sdk.listener);
        main.drain();
        assertTrue("a callback queued before the disable must drop", sink.received.isEmpty());
        // And a straggler from the SDK after the disable.
        installed.onNewMessageSent("after");
        main.drain();
        assertTrue(sink.sent.isEmpty());
    }

    @Test
    public void everyListeningEngineGetsTheEventsAndOneDetachingSilencesNoOther() {
        final Recorder sinkB = new Recorder();
        final FeedbackOps b = new FeedbackOps(sdk, main, sinkB);
        ops.setListenerEnabled(true);
        b.setListenerEnabled(true);
        final FeedbackListener shared = sdk.listener;
        shared.onNewMessageSent("one");
        shared.onNewMessagesReceived(Collections.singletonList("in"));
        main.drain();
        assertEquals(Collections.singletonList("one"), sink.sent);
        assertEquals(Collections.singletonList("one"), sinkB.sent);
        assertEquals(1, sink.received.size());
        assertEquals(1, sinkB.received.size());

        // The older engine goes: the newer keeps receiving, and the SDK slot is not released.
        ops.detach();
        assertSame("the slot still holds the fan-out", shared, sdk.listener);
        shared.onNewMessageSent("two");
        main.drain();
        assertEquals(Collections.singletonList("one"), sink.sent);
        assertEquals(Arrays.asList("one", "two"), sinkB.sent);

        // The newer engine goes too: nobody listens, so the slot is released.
        b.detach();
        assertNull(sdk.listener);
    }

    @Test
    public void theNewerEngineDetachingDoesNotSilenceTheOlder() {
        final Recorder sinkB = new Recorder();
        final FeedbackOps b = new FeedbackOps(sdk, main, sinkB);
        ops.setListenerEnabled(true);
        b.setListenerEnabled(true);
        b.detach();
        assertNotNull("the older engine still listens", sdk.listener);
        sdk.listener.onNewMessageSent("x");
        main.drain();
        assertEquals(Collections.singletonList("x"), sink.sent);
        assertTrue(sinkB.sent.isEmpty());
    }

    @Test
    public void enablingAgainReplacesThisEnginesRelayWithoutADuplicate() {
        ops.setListenerEnabled(true);
        ops.setListenerEnabled(true);
        sdk.listener.onNewMessageSent("once");
        main.drain();
        assertEquals(Collections.singletonList("once"), sink.sent);
    }

    @Test
    public void attachForgetsAListenerAPreviousIsolateLeft() {
        ops.setListenerEnabled(true);
        final FeedbackListener stale = sdk.listener;
        assertTrue(ops.attach());
        assertNull(sdk.listener);
        stale.onNewMessageSent("from the old isolate");
        main.drain();
        assertTrue(sink.sent.isEmpty());
    }

    @Test
    public void aFailedInstallLeavesNothingAccepting() {
        sdk.registered = false;
        assertEquals(FeedbackOps.NOT_REGISTERED, codeOf(() -> ops.setListenerEnabled(true)));
        assertNull(sdk.listener);
    }

    @Test
    public void aFailedReinstallSilencesTheListenerThisEngineHadBefore() {
        ops.setListenerEnabled(true);
        final FeedbackListener first = sdk.listener;
        sdk.registered = false;
        assertEquals(FeedbackOps.NOT_REGISTERED, codeOf(() -> ops.setListenerEnabled(true)));
        first.onNewMessageSent("late");
        main.drain();
        assertTrue(sink.sent.isEmpty());
    }

    @Test
    public void nonNullKeepsOrderAndDropsNulls() {
        assertEquals(Arrays.asList("1", "2"), FeedbackOps.nonNull(Arrays.asList("1", null, "2")));
        assertTrue(FeedbackOps.nonNull(null).isEmpty());
    }
}
