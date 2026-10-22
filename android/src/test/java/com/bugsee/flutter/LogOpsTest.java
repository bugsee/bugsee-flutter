package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.internal.BugseeWrapperChannel;
import com.bugsee.library.contracts.internal.LogSource;
import com.bugsee.library.contracts.options.LogLevel;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * Log injection with a fake SDK behind the seam, and the real {@link BugseeLogSdk} over a recording
 * channel: what reaches the SDK, with which source, tag and level, and what does not (v7.4.2
 * {@code BugseeInternal.log}, {@code BugseeWrapperChannelImpl}, {@code BugseeCaptureDataProviderLog};
 * doc/logs.md).
 */
public class LogOpsTest {

    private static final class Call {
        final String tag;
        final String message;
        final int level;

        Call(final String tag, final String message, final int level) {
            this.tag = tag;
            this.message = message;
            this.level = level;
        }
    }

    private static class FakeSdk implements LogOps.Sdk {
        boolean accepting = true;
        boolean channelAvailable = true;
        boolean acceptsThrows;
        /** Throws from {@link #submit} for this message (an app filter that threw). */
        String throwOnMessage;
        final List<Call> submitted = new ArrayList<>();
        int acceptsCalls;

        @Override
        public boolean acceptsLogs() {
            acceptsCalls++;
            if (acceptsThrows) {
                throw new IllegalStateException("status unreadable");
            }
            return accepting;
        }

        @Override
        public boolean submit(@Nullable final String tag, @NonNull final String message, final int level) {
            if (!channelAvailable) {
                return false;
            }
            if (message.equals(throwOnMessage)) {
                throw new IllegalStateException("the app's filter threw");
            }
            submitted.add(new Call(tag, message, level));
            return true;
        }
    }

    private static Messages.LogLineMessage line(final String message, final long level, final String tag) {
        return new Messages.LogLineMessage.Builder()
                .setMessage(message).setLevel(level).setTag(tag).build();
    }

    // ---- the gate -------------------------------------------------------------------------------

    @Test
    public void nothingIsHandedOverWhenTheSdkIsNotAccepting() {
        final FakeSdk sdk = new FakeSdk();
        sdk.accepting = false;
        assertEquals(0, LogOps.addAll(sdk, Arrays.asList(line("a", 3, null), line("b", 3, null))));
        assertTrue(sdk.submitted.isEmpty());
    }

    @Test
    public void theGateIsReadOncePerBatch() {
        final FakeSdk sdk = new FakeSdk();
        LogOps.addAll(sdk, Arrays.asList(line("a", 3, null), line("b", 3, null), line("c", 3, null)));
        assertEquals(1, sdk.acceptsCalls);
    }

    @Test
    public void aGateThatCannotBeReadHandsNothingOverAndDoesNotThrow() {
        final FakeSdk sdk = new FakeSdk();
        sdk.acceptsThrows = true;
        assertEquals(0, LogOps.addAll(sdk, Collections.singletonList(line("a", 3, null))));
        assertTrue(sdk.submitted.isEmpty());
    }

    @Test
    public void anEmptyOrNullBatchIsZeroAndDoesNotReadTheGate() {
        final FakeSdk sdk = new FakeSdk();
        assertEquals(0, LogOps.addAll(sdk, null));
        assertEquals(0, LogOps.addAll(sdk, Collections.<Messages.LogLineMessage>emptyList()));
        assertEquals(0, sdk.acceptsCalls);
    }

    // ---- what is handed over --------------------------------------------------------------------

    @Test
    public void linesAreHandedOverInOrderWithTheirTagAndLevel() {
        final FakeSdk sdk = new FakeSdk();
        final int handed = LogOps.addAll(sdk, Arrays.asList(
                line("one", 1, "print"), line("two", 5, "debugPrint"), line("three", 3, null)));
        assertEquals(3, handed);
        assertEquals("one", sdk.submitted.get(0).message);
        assertEquals("print", sdk.submitted.get(0).tag);
        assertEquals(1, sdk.submitted.get(0).level);
        assertEquals("two", sdk.submitted.get(1).message);
        assertEquals(5, sdk.submitted.get(1).level);
        assertEquals("three", sdk.submitted.get(2).message);
        assertNull(sdk.submitted.get(2).tag);
    }

    @Test
    public void anEmptyTagIsNoTag() {
        final FakeSdk sdk = new FakeSdk();
        LogOps.addAll(sdk, Collections.singletonList(line("x", 3, "")));
        assertNull(sdk.submitted.get(0).tag);
    }

    @Test
    public void everyLevelFromOneToFiveIsAccepted() {
        final FakeSdk sdk = new FakeSdk();
        for (int level = 1; level <= 5; level++) {
            assertEquals(LogOps.Outcome.HANDED, LogOps.add(sdk, line("x", level, null)));
        }
        assertEquals(5, sdk.submitted.size());
    }

    @Test
    public void aLevelOutsideTheSdksRangeIsRefused() {
        final FakeSdk sdk = new FakeSdk();
        for (final long level : new long[] {0, 6, -1, 99, Long.MAX_VALUE, Long.MIN_VALUE}) {
            assertEquals("level " + level, LogOps.Outcome.INVALID, LogOps.add(sdk, line("x", level, null)));
        }
        assertTrue(sdk.submitted.isEmpty());
    }

    @Test
    public void anEmptyMessageOrANullLineIsRefused() {
        final FakeSdk sdk = new FakeSdk();
        assertEquals(LogOps.Outcome.INVALID, LogOps.add(sdk, line("", 3, null)));
        assertEquals(LogOps.Outcome.INVALID, LogOps.add(sdk, null));
        assertTrue(sdk.submitted.isEmpty());
    }

    @Test
    public void aWrapperWithNoChannelYetHandsNothingOverAndCountsNothing() {
        final FakeSdk sdk = new FakeSdk();
        sdk.channelAvailable = false;
        assertEquals(0, LogOps.addAll(sdk, Arrays.asList(line("a", 3, null), line("b", 3, null))));
    }

    @Test
    public void anExceptionFromTheAppsFilterDropsThatLineAndTheBatchGoesOn() {
        final FakeSdk sdk = new FakeSdk();
        sdk.throwOnMessage = "bad";
        final int handed = LogOps.addAll(sdk, Arrays.asList(
                line("a", 3, null), line("bad", 3, null), line("c", 3, null)));
        assertEquals(2, handed);
        assertEquals("a", sdk.submitted.get(0).message);
        assertEquals("c", sdk.submitted.get(1).message);
    }

    // ---- the real seam over a recording channel -------------------------------------------------

    private static final class RecordingChannel implements BugseeWrapperChannel {
        final List<Object[]> calls = new ArrayList<>();
        RuntimeException throwing;

        @Override
        public void log(@Nullable final String tag, @Nullable final String message,
                @Nullable final LogLevel level, @NonNull final LogSource source) {
            if (throwing != null) {
                throw throwing;
            }
            calls.add(new Object[] {tag, message, level, source});
        }
    }

    @Test
    public void theRealSeamClaimsOnlyTheWrapperSourceAndMapsTheLevel() {
        final NetworkChannelHolder holder = new NetworkChannelHolder();
        final RecordingChannel channel = new RecordingChannel();
        holder.set(channel);
        final BugseeLogSdk sdk = new BugseeLogSdk(holder);
        assertTrue(sdk.submit("print", "hello", 2));
        assertTrue(sdk.submit(null, "world", 5));
        assertEquals(2, channel.calls.size());
        assertEquals("print", channel.calls.get(0)[0]);
        assertEquals("hello", channel.calls.get(0)[1]);
        assertSame(LogLevel.Warning, channel.calls.get(0)[2]);
        // Custom: "the host runtime's own logs". Never Bugsee (the app's own Bugsee.log).
        assertSame(LogSource.Custom, channel.calls.get(0)[3]);
        assertNull(channel.calls.get(1)[0]);
        assertSame(LogLevel.Verbose, channel.calls.get(1)[2]);
        assertSame(LogSource.Custom, channel.calls.get(1)[3]);
    }

    @Test
    public void theRealSeamRefusesALevelTheSdkDoesNotHave() {
        final NetworkChannelHolder holder = new NetworkChannelHolder();
        final RecordingChannel channel = new RecordingChannel();
        holder.set(channel);
        final BugseeLogSdk sdk = new BugseeLogSdk(holder);
        assertFalse(sdk.submit("t", "x", 0));
        assertFalse(sdk.submit("t", "x", 6));
        assertTrue(channel.calls.isEmpty());
    }

    @Test
    public void withNoChannelTheRealSeamRefusesAndNothingThrows() {
        final BugseeLogSdk sdk = new BugseeLogSdk(new NetworkChannelHolder());
        assertFalse(sdk.submit("t", "x", 3));
    }

    @Test
    public void aReplacedWrapperRegistrationSendsToTheNewChannelOnly() {
        // The SDK retires the old channel when the wrapper is replaced (the identity refinement) and
        // hands the new one to onWrapperChannelAvailable; the holder is process-wide, so the next
        // line goes to the new channel and the retired one is never written to again.
        final NetworkChannelHolder holder = new NetworkChannelHolder();
        final RecordingChannel retired = new RecordingChannel();
        final RecordingChannel current = new RecordingChannel();
        holder.set(retired);
        final BugseeLogSdk sdk = new BugseeLogSdk(holder);
        assertTrue(sdk.submit(null, "before", 3));
        holder.set(current);
        assertTrue(sdk.submit(null, "after", 3));
        assertEquals(1, retired.calls.size());
        assertEquals("before", retired.calls.get(0)[1]);
        assertEquals(1, current.calls.size());
        assertEquals("after", current.calls.get(0)[1]);
    }

    @Test
    public void anExceptionThrownByTheAppsFilterThroughTheRealChannelIsCaughtPerLine() {
        final NetworkChannelHolder holder = new NetworkChannelHolder();
        final RecordingChannel channel = new RecordingChannel();
        channel.throwing = new IllegalStateException("filter bug");
        holder.set(channel);
        final BugseeLogSdk real = new BugseeLogSdk(holder);
        // The gate reads the SDK's static status, which a unit test cannot set: open it, keep the
        // real submit.
        final LogOps.Sdk sdk = new LogOps.Sdk() {
            @Override
            public boolean acceptsLogs() {
                return true;
            }

            @Override
            public boolean submit(@Nullable final String tag, @NonNull final String message,
                    final int level) {
                return real.submit(tag, message, level);
            }
        };
        assertEquals(0, LogOps.addAll(sdk, Arrays.asList(line("a", 3, null), line("b", 3, null))));
        channel.throwing = null;
        assertEquals(1, LogOps.addAll(sdk, Collections.singletonList(line("c", 3, null))));
    }
}
