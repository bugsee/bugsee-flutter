package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.exchange.Breadcrumb;
import com.bugsee.library.contracts.exchange.NetworkEvent;
import com.bugsee.library.contracts.internal.BugseeWrapperChannel;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Network injection with a fake SDK behind the seam: what reaches the SDK, what does not, and how
 * many events were handed over (v7.4.2 {@code BugseeInternal.addNetworkEvent}, {@code
 * BugseeWrapperChannelImpl}, {@code BugseeCaptureDataProviderNetwork}; doc/network.md).
 */
public class NetworkOpsTest {

    /** One recorded {@code createNetworkEvent} call. */
    private static final class Created implements NetworkEvent {
        long timestamp;
        NetworkEventStage stage;
        String id;
        String mechanism;
        String method;
        String url;
        Map<String, String> headers;
        String body;
        long size;
        int bodyByteSize;
        NetworkBodyAbsenceReason reason;
        int responseCode;
        String statusText;
        String errorShort;
        String errorDescription;
        Map<String, Double> timings;

        @NonNull @Override public String getId() { return id; }
        @Nullable @Override public String getMechanism() { return mechanism; }
        @Nullable @Override public String getUrl() { return url; }
        @Nullable @Override public String getBody() { return body; }
        @Override public long getSize() { return size; }
        @Nullable @Override public String getErrorShortMessage() { return errorShort; }
        @Nullable @Override public String getErrorDescription() { return errorDescription; }
        @Nullable @Override public Map<String, String> getHeaders() { return headers; }
        @Nullable @Override public String getMethod() { return method; }
        @Nullable @Override public NetworkBodyAbsenceReason getBodyAbsenceReason() { return reason; }
        @Override public int getResponseCode() { return responseCode; }
        @Override public void setResponseCode(final int responseCode) { this.responseCode = responseCode; }
        @Nullable @Override public String getStatusText() { return statusText; }
        @Override public void setStatusText(@Nullable final String statusText) { this.statusText = statusText; }
        @Nullable @Override public NetworkEventStage getNetworkEventType() { return stage; }
        @Nullable @Override public WebSocketEventType getWebSocketEventType() { return null; }
        @Override public long getTimestamp() { return timestamp; }
    }

    private static class FakeSdk implements NetworkOps.Sdk {
        boolean accepting = true;
        long now = 1_000_000L;
        boolean factoryAvailable = true;
        boolean channelAvailable = true;
        /** Throws from {@link #submit} for events with this id (an app filter that threw). */
        String throwOnId;
        final List<Created> created = new ArrayList<>();
        final List<Created> submitted = new ArrayList<>();
        int acceptsCalls;

        @Override
        public boolean acceptsNetworkEvents() {
            acceptsCalls++;
            return accepting;
        }

        @Override
        public long currentTimestamp() {
            return now;
        }

        @Nullable
        @Override
        public NetworkEvent create(
                final long timestamp, @NonNull final NetworkEvent.NetworkEventStage stage,
                @NonNull final String id, @NonNull final String mechanism, @Nullable final String method,
                @NonNull final String url, @Nullable final Map<String, String> headers,
                @Nullable final String body, final long size, final int bodyByteSize,
                @Nullable final NetworkEvent.NetworkBodyAbsenceReason reason, final int responseCode,
                @Nullable final String statusText, @Nullable final String errorShortMessage,
                @Nullable final String errorDescription, @Nullable final Map<String, Double> timings) {
            if (!factoryAvailable) {
                return null;
            }
            final Created c = new Created();
            c.timestamp = timestamp;
            c.stage = stage;
            c.id = id;
            c.mechanism = mechanism;
            c.method = method;
            c.url = url;
            c.headers = headers;
            c.body = body;
            c.size = size;
            c.bodyByteSize = bodyByteSize;
            c.reason = reason;
            c.responseCode = responseCode;
            c.statusText = statusText;
            c.errorShort = errorShortMessage;
            c.errorDescription = errorDescription;
            c.timings = timings;
            created.add(c);
            return c;
        }

        @Override
        public boolean submit(@NonNull final NetworkEvent event) {
            if (!channelAvailable) {
                return false;
            }
            if (event.getId().equals(throwOnId)) {
                throw new IllegalStateException("the app's filter threw");
            }
            submitted.add((Created) event);
            return true;
        }
    }

    private static Messages.NetworkEventMessage message(final String id, final String stage) {
        return new Messages.NetworkEventMessage.Builder()
                .setId(id)
                .setStage(stage)
                .setMechanism("dart:io")
                .setMethod("GET")
                .setUrl("https://example.com/a")
                .setAgeMs(0L)
                .setSize(0L)
                .setStatusCode(0L)
                .build();
    }

    @Test
    public void everyStageDartSendsMapsToTheSdksStageByItsOwnWireName() {
        // NetworkEventStage#toString is the wire value in the bundle (network.md: `type`).
        for (final String name : NetworkOps.stageNames()) {
            final NetworkEvent.NetworkEventStage stage = NetworkOps.stageOf(name);
            assertEquals(name, stage.toString());
        }
        assertEquals(NetworkEvent.NetworkEventStage.RequestStarted, NetworkOps.stageOf("before"));
        assertEquals(NetworkEvent.NetworkEventStage.Redirect, NetworkOps.stageOf("redirect"));
        assertEquals(NetworkEvent.NetworkEventStage.RequestCompleted, NetworkOps.stageOf("complete"));
        assertEquals(NetworkEvent.NetworkEventStage.RequestErrored, NetworkOps.stageOf("error"));
        assertEquals(NetworkEvent.NetworkEventStage.RequestAborted, NetworkOps.stageOf("abort"));
    }

    @Test
    public void aStageDartNeverSendsOrDoesNotKnowIsRefused() {
        for (final String name : new String[] {"timing", "websocket", "cancel", "", "Before", null}) {
            assertNull(String.valueOf(name), NetworkOps.stageOf(name));
        }
        final FakeSdk sdk = new FakeSdk();
        assertEquals(NetworkOps.Outcome.INVALID, NetworkOps.add(sdk, message("1", "websocket")));
        assertTrue(sdk.created.isEmpty());
    }

    @Test
    public void nothingIsHandedOverWhileTheSdkIsNotAccepting() {
        final FakeSdk sdk = new FakeSdk();
        sdk.accepting = false;
        final int handed = NetworkOps.addAll(sdk, Arrays.asList(message("1", "before"), message("1", "complete")));
        assertEquals(0, handed);
        assertTrue("no event was even created", sdk.created.isEmpty());
        assertTrue(sdk.submitted.isEmpty());
    }

    @Test
    public void theBatchIsHandedOverInOrderAndCounted() {
        final FakeSdk sdk = new FakeSdk();
        final int handed = NetworkOps.addAll(sdk,
                Arrays.asList(message("a", "before"), message("a", "complete"), message("b", "error")));
        assertEquals(3, handed);
        assertEquals(Arrays.asList("a", "a", "b"), Arrays.asList(
                sdk.submitted.get(0).id, sdk.submitted.get(1).id, sdk.submitted.get(2).id));
        assertEquals(1, sdk.acceptsCalls);
    }

    @Test
    public void everyFieldReachesTheSdkEvent() {
        final FakeSdk sdk = new FakeSdk();
        final Map<String, String> headers = new HashMap<>();
        headers.put("content-type", "application/json");
        final Map<String, Double> timings = new HashMap<>();
        timings.put("ttfb", 12.5);
        final Messages.NetworkEventMessage m = new Messages.NetworkEventMessage.Builder()
                .setId("req-1").setStage("complete").setMechanism("dart:io").setMethod("POST")
                .setUrl("https://example.com/x?y=1").setAgeMs(0L).setSize(11L).setStatusCode(201L)
                .setHeaders(headers).setBody("{\"a\":\"bcde\"}").setStatusText("Created")
                .setErrorShortMessage("short").setErrorDescription("long").setTimings(timings)
                .setNoBodyReason(null)
                .build();
        assertEquals(NetworkOps.Outcome.HANDED, NetworkOps.add(sdk, m));
        final Created c = sdk.submitted.get(0);
        assertEquals(NetworkEvent.NetworkEventStage.RequestCompleted, c.stage);
        assertEquals("req-1", c.id);
        assertEquals("dart:io", c.mechanism);
        assertEquals("POST", c.method);
        assertEquals("https://example.com/x?y=1", c.url);
        assertEquals(headers, c.headers);
        assertEquals("{\"a\":\"bcde\"}", c.body);
        assertEquals(11L, c.size);
        assertEquals("the exact byte length rides with a body", 11, c.bodyByteSize);
        assertEquals(201, c.responseCode);
        assertEquals("Created", c.statusText);
        assertEquals("short", c.errorShort);
        assertEquals("long", c.errorDescription);
        assertEquals(timings, c.timings);
    }

    @Test
    public void noBodyMeansNoByteSizeAndTheReasonIsTheSdksOwnConstant() {
        final FakeSdk sdk = new FakeSdk();
        final Messages.NetworkEventMessage m = new Messages.NetworkEventMessage.Builder()
                .setId("1").setStage("complete").setMechanism("dart:io").setMethod("GET")
                .setUrl("https://e/").setAgeMs(0L).setSize(5000L).setStatusCode(200L)
                .setNoBodyReason("size_too_large").build();
        NetworkOps.add(sdk, m);
        final Created c = sdk.submitted.get(0);
        assertNull(c.body);
        assertEquals(0, c.bodyByteSize);
        assertEquals(5000L, c.size);
        assertEquals(NetworkEvent.NetworkBodyAbsenceReason.SizeTooLarge, c.reason);
        for (final String wire : new String[] {"no_data", "unsupported_content_type",
                "no_content_type", "cant_read_data"}) {
            assertEquals(wire, NetworkOps.reasonOf(wire).getValue());
        }
        assertNull(NetworkOps.reasonOf("something_new"));
        assertNull(NetworkOps.reasonOf(null));
        assertNull(NetworkOps.reasonOf(""));
    }

    @Test
    public void theTimestampIsTheSdksClockMinusTheAgeAndTheAgeIsClamped() {
        final FakeSdk sdk = new FakeSdk();
        sdk.now = 10_000_000_000L;
        final Messages.NetworkEventMessage fresh = message("1", "before");
        fresh.setAgeMs(1500L);
        final Messages.NetworkEventMessage negative = message("2", "before");
        negative.setAgeMs(-5L);
        final Messages.NetworkEventMessage ancient = message("3", "before");
        ancient.setAgeMs(Long.MAX_VALUE);
        NetworkOps.addAll(sdk, Arrays.asList(fresh, negative, ancient));
        assertEquals(10_000_000_000L - 1500L, sdk.submitted.get(0).timestamp);
        assertEquals("a negative age is now, never the future", 10_000_000_000L, sdk.submitted.get(1).timestamp);
        assertEquals(10_000_000_000L - NetworkOps.MAX_AGE_MS, sdk.submitted.get(2).timestamp);
    }

    @Test
    public void aMalformedMessageIsRefusedAndTheRestOfTheBatchGoesOn() {
        final FakeSdk sdk = new FakeSdk();
        final Messages.NetworkEventMessage noId = message("", "before");
        final Messages.NetworkEventMessage noUrl = message("2", "before");
        noUrl.setUrl("");
        final Messages.NetworkEventMessage noMechanism = message("3", "before");
        noMechanism.setMechanism("");
        final int handed = NetworkOps.addAll(sdk,
                Arrays.asList(noId, noUrl, noMechanism, message("4", "before")));
        assertEquals(1, handed);
        assertEquals("4", sdk.submitted.get(0).id);
        assertEquals(NetworkOps.Outcome.INVALID, NetworkOps.add(sdk, null));
        assertEquals(0, NetworkOps.addAll(sdk, null));
        assertEquals(0, NetworkOps.addAll(sdk, Collections.<Messages.NetworkEventMessage>emptyList()));
    }

    @Test
    public void aStatusOutsideHttpIsZeroAndNegativeSizeIsZero() {
        final FakeSdk sdk = new FakeSdk();
        final Messages.NetworkEventMessage m = message("1", "complete");
        m.setStatusCode(100000L);
        m.setSize(-9L);
        NetworkOps.add(sdk, m);
        assertEquals(0, sdk.submitted.get(0).responseCode);
        assertEquals(0L, sdk.submitted.get(0).size);
    }

    @Test
    public void aFilterThatThrowsDropsThatEventNotTheBatchNorTheApp() {
        final FakeSdk sdk = new FakeSdk();
        sdk.throwOnId = "boom";
        final int handed = NetworkOps.addAll(sdk,
                Arrays.asList(message("a", "before"), message("boom", "complete"), message("c", "complete")));
        assertEquals(2, handed);
        assertEquals(Arrays.asList("a", "c"),
                Arrays.asList(sdk.submitted.get(0).id, sdk.submitted.get(1).id));
        assertEquals(NetworkOps.Outcome.NO_EVENT, NetworkOps.add(sdk, message("boom", "before")));
    }

    @Test
    public void noFactoryEventOrNoChannelIsNotCountedAsHandedOver() {
        final FakeSdk sdk = new FakeSdk();
        sdk.factoryAvailable = false;
        assertEquals(0, NetworkOps.addAll(sdk, Arrays.asList(message("1", "before"))));
        sdk.factoryAvailable = true;
        sdk.channelAvailable = false;
        assertEquals(0, NetworkOps.addAll(sdk, Arrays.asList(message("1", "before"))));
        assertTrue(sdk.submitted.isEmpty());
    }

    @Test
    public void aSdkThatThrowsWhileAskedWhetherItAcceptsHandsNothingOver() {
        final NetworkOps.Sdk throwing = new FakeSdk() {
            @Override
            public boolean acceptsNetworkEvents() {
                throw new IllegalStateException("options not available");
            }
        };
        assertEquals(0, NetworkOps.addAll(throwing, Arrays.asList(message("1", "before"))));
    }

    // ---- The wrapper channel: filtering is required, the newest registration wins ----------

    private static final class FakeChannel implements BugseeWrapperChannel {
        final List<Object[]> calls = new ArrayList<>();

        @Override
        public void addNetworkEvent(@Nullable final NetworkEvent networkEvent, final boolean requiresFiltering) {
            calls.add(new Object[] {networkEvent, requiresFiltering});
        }

        @Override
        public void addBreadcrumb(@Nullable final Breadcrumb breadcrumb) {
            throw new AssertionError("network injection must not touch breadcrumbs");
        }
    }

    @Test
    public void theChannelIsAlwaysAskedToFilterTheEvent() {
        final NetworkChannelHolder holder = new NetworkChannelHolder();
        final FakeChannel channel = new FakeChannel();
        holder.set(channel);
        final BugseeNetworkSdk sdk = new BugseeNetworkSdk(holder);
        final Created event = new Created();
        assertTrue(sdk.submit(event));
        assertEquals(1, channel.calls.size());
        assertSame(event, channel.calls.get(0)[0]);
        // requiresFiltering = false would skip the SDK's default sanitizer and the app's filter.
        assertEquals(Boolean.TRUE, channel.calls.get(0)[1]);
    }

    @Test
    public void withoutAChannelNothingIsSubmitted() {
        final BugseeNetworkSdk sdk = new BugseeNetworkSdk(new NetworkChannelHolder());
        assertFalse(sdk.submit(new Created()));
    }

    @Test
    public void theWrapperStoresTheChannelTheSdkHandsItAndTheNewestRegistrationWins() {
        final NetworkChannelHolder holder = NetworkChannelHolder.shared();
        final BugseeWrapperChannel before = holder.get();
        try {
            final FakeChannel first = new FakeChannel();
            final FakeChannel second = new FakeChannel();
            final FlutterWrapper wrapper = FlutterWrapper.create("flutter", "1", null, null);
            wrapper.onWrapperChannelAvailable(first);
            assertSame(first, holder.get());
            // Dart refines the identity: a NEW wrapper object is registered and gets a new channel.
            FlutterWrapper.create("flutter", "1", null, null).onWrapperChannelAvailable(second);
            assertSame(second, holder.get());
        } finally {
            holder.set(before);
        }
    }
}
