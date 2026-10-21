package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.exchange.NetworkEvent;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Network events the Dart capture ({@code lib/src/network}) hands to the SDK (Phase 5b).
 *
 * <p>Dart's {@code dart:io} stack is invisible to the SDK's own interception, so the wrapper
 * captures it in Dart and injects the events here. The SDK is behind {@link Sdk} so a unit test
 * can see what reaches it. Every decision the SDK would make for an injected event is mirrored
 * here rather than left to it, so the wrapper never hands over what the SDK would drop (and says
 * how many it did hand over):
 *
 * <ul>
 *   <li><b>gate</b>: {@code BugseeInternal.addNetworkEvent} (v7.4.2:975) accepts while the SDK is
 *       started or starting, but a provider that has not started only buffers 32 events
 *       ({@code BugseeCaptureDataProviderNetwork.PRESTART_BUFFER_SIZE}) and iOS drops everything
 *       but {@code Launched}; the wrapper sends nothing before {@code Launched} on either
 *       platform, and nothing while {@code capture.network} is off (no provider subscribes);</li>
 *   <li><b>filtering is always required</b> ({@code requiresFiltering = true}): the SDK's default
 *       sanitizer (option {@code capture.network.default-sanitizer}) and the app's own native
 *       network filter, if it set one, run on injected events exactly as on intercepted ones.
 *       {@code false} would skip both (v7.4.2 {@code BugseeCaptureDataProviderNetwork.onNetworkEvent});</li>
 *   <li><b>size and content-type limits</b> ({@code capture.network.body-size-limit},
 *       {@code body-without-type}) are enforced by the SDK itself on whatever arrives
 *       ({@code applyBodyFilters}); Dart already withholds a body the SDK would drop, so this
 *       only defends against a message that did not come from this Dart.</li>
 * </ul>
 *
 * <p>The SDK exposes a wrapper-attributed route for this, {@code BugseeWrapperChannel}
 * (v7.4.2 {@code BugseeWrapperChannelImpl}); {@link NetworkChannelHolder} keeps the channel the
 * SDK hands the current wrapper registration. Network events carry no source attribution at
 * 7.4.2 (only {@code log} does): the {@code mechanism} field ({@code dart:io}) is what says where
 * an event came from.
 */
final class NetworkOps {

    /** The wire stage names Dart sends: the SDK's own ({@code NetworkEventStage#toString}). */
    static final String STAGE_BEFORE = "before";
    static final String STAGE_REDIRECT = "redirect";
    static final String STAGE_COMPLETE = "complete";
    static final String STAGE_ERROR = "error";
    static final String STAGE_ABORT = "abort";

    /** Compared with Dart's {@code NetworkWire.maxAgeMs} by the drift guard. */
    static final long MAX_AGE_MS = 60L * 60L * 1000L;

    /** What a single event is refused for, to tell a bug from a drop in tests and logs. */
    enum Outcome {
        HANDED,
        /** The SDK is not launched or {@code capture.network} is off. */
        NOT_ACCEPTING,
        /** Malformed (an empty id or url, an unknown stage): a message not from this Dart. */
        INVALID,
        /** The SDK made no event, or the wrapper holds no channel yet. */
        NO_EVENT
    }

    /** The SDK entry points injection uses; the real ones are {@link BugseeNetworkSdk}. */
    interface Sdk {
        /** {@code Launched} and {@code capture.network} on. */
        boolean acceptsNetworkEvents();

        /** {@code BugseeExchangeFactory.currentTimestamp()}: the clock the pipeline validates. */
        long currentTimestamp();

        /** {@code factory.createNetworkEvent(...)} (null: the capture subsystem is not available). */
        @Nullable
        NetworkEvent create(
                long timestamp,
                @NonNull NetworkEvent.NetworkEventStage stage,
                @NonNull String id,
                @NonNull String mechanism,
                @Nullable String method,
                @NonNull String url,
                @Nullable Map<String, String> headers,
                @Nullable String body,
                long size,
                int bodyByteSize,
                @Nullable NetworkEvent.NetworkBodyAbsenceReason reason,
                int responseCode,
                @Nullable String statusText,
                @Nullable String errorShortMessage,
                @Nullable String errorDescription,
                @Nullable Map<String, Double> timings);

        /**
         * {@code channel.addNetworkEvent(event, true)}; false when the wrapper holds no channel
         * (it is delivered at {@code setWrapper}, so this only happens before registration).
         */
        boolean submit(@NonNull NetworkEvent event);
    }

    private NetworkOps() {
    }

    /** The SDK's stage for a wire name, or null (also for the stages Dart never sends). */
    @Nullable
    static NetworkEvent.NetworkEventStage stageOf(@Nullable final String wire) {
        if (wire == null) {
            return null;
        }
        switch (wire) {
            case STAGE_BEFORE:
                return NetworkEvent.NetworkEventStage.RequestStarted;
            case STAGE_REDIRECT:
                return NetworkEvent.NetworkEventStage.Redirect;
            case STAGE_COMPLETE:
                return NetworkEvent.NetworkEventStage.RequestCompleted;
            case STAGE_ERROR:
                return NetworkEvent.NetworkEventStage.RequestErrored;
            case STAGE_ABORT:
                return NetworkEvent.NetworkEventStage.RequestAborted;
            default:
                return null;
        }
    }

    /**
     * The SDK's absence reason for a wire value, or null for none or one this version does not
     * know ({@code NetworkBodyAbsenceReason.getByString}).
     */
    @Nullable
    static NetworkEvent.NetworkBodyAbsenceReason reasonOf(@Nullable final String wire) {
        if (wire == null || wire.isEmpty()) {
            return null;
        }
        return NetworkEvent.NetworkBodyAbsenceReason.getByString(wire);
    }

    /**
     * Hands every event of the batch to the SDK, in order, and returns how many it took. Nothing
     * throws: an SDK or filter exception for one event is caught (the SDK's network filter runs
     * on THIS thread, the plugin's serial background thread, and a throw there must not take the app down; the event
     * is dropped, fail closed) and the rest of the batch goes on.
     */
    static int addAll(@NonNull final Sdk sdk, @Nullable final List<Messages.NetworkEventMessage> events) {
        if (events == null || events.isEmpty()) {
            return 0;
        }
        final boolean accepting;
        try {
            accepting = sdk.acceptsNetworkEvents();
        } catch (final RuntimeException e) {
            return 0;
        }
        if (!accepting) {
            return 0;
        }
        int handed = 0;
        for (final Messages.NetworkEventMessage message : events) {
            if (add(sdk, message) == Outcome.HANDED) {
                handed++;
            }
        }
        return handed;
    }

    /** One event. The gate is the caller's ({@link #addAll}). */
    @NonNull
    static Outcome add(@NonNull final Sdk sdk, @Nullable final Messages.NetworkEventMessage message) {
        if (message == null) {
            return Outcome.INVALID;
        }
        final NetworkEvent.NetworkEventStage stage = stageOf(message.getStage());
        final String id = message.getId();
        final String url = message.getUrl();
        final String mechanism = message.getMechanism();
        if (stage == null || id == null || id.isEmpty() || url == null || url.isEmpty()
                || mechanism == null || mechanism.isEmpty()) {
            return Outcome.INVALID;
        }
        final Map<String, String> headers = copyHeaders(message.getHeaders());
        final Map<String, Double> timings = copyTimings(message.getTimings());
        final String body = message.getBody();
        final long size = Math.max(0L, message.getSize());
        final long age = Math.min(MAX_AGE_MS, Math.max(0L, message.getAgeMs()));
        final long statusCode = message.getStatusCode();
        try {
            final NetworkEvent event = sdk.create(
                    sdk.currentTimestamp() - age,
                    stage,
                    id,
                    mechanism,
                    message.getMethod(),
                    url,
                    headers,
                    body,
                    size,
                    // The exact byte length of the text: the SDK's size limit is byte-accurate when
                    // it is known, and a character count is only an over-estimate.
                    body == null ? 0 : (int) Math.min(Integer.MAX_VALUE, size),
                    reasonOf(message.getNoBodyReason()),
                    statusCode < 0 || statusCode > 999 ? 0 : (int) statusCode,
                    message.getStatusText(),
                    message.getErrorShortMessage(),
                    message.getErrorDescription(),
                    timings);
            if (event == null) {
                return Outcome.NO_EVENT;
            }
            return sdk.submit(event) ? Outcome.HANDED : Outcome.NO_EVENT;
        } catch (final RuntimeException e) {
            // The app's native filter (or the SDK) threw on this thread: the event is dropped.
            return Outcome.NO_EVENT;
        }
    }

    @Nullable
    private static Map<String, String> copyHeaders(@Nullable final Map<?, ?> raw) {
        if (raw == null) {
            return null;
        }
        final Map<String, String> copy = new LinkedHashMap<>();
        for (final Map.Entry<?, ?> entry : raw.entrySet()) {
            if (entry.getKey() instanceof String && entry.getValue() instanceof String) {
                copy.put((String) entry.getKey(), (String) entry.getValue());
            }
        }
        return copy;
    }

    @Nullable
    private static Map<String, Double> copyTimings(@Nullable final Map<?, ?> raw) {
        if (raw == null || raw.isEmpty()) {
            return null;
        }
        final Map<String, Double> copy = new LinkedHashMap<>();
        for (final Map.Entry<?, ?> entry : raw.entrySet()) {
            if (entry.getKey() instanceof String && entry.getValue() instanceof Number) {
                final double value = ((Number) entry.getValue()).doubleValue();
                if (!Double.isNaN(value) && !Double.isInfinite(value)) {
                    copy.put((String) entry.getKey(), value);
                }
            }
        }
        return copy.isEmpty() ? null : copy;
    }

    /** For tests: the wire stage names, in the order they are declared here. */
    @NonNull
    static List<String> stageNames() {
        final List<String> names = new ArrayList<>();
        Collections.addAll(names, STAGE_BEFORE, STAGE_REDIRECT, STAGE_COMPLETE, STAGE_ERROR,
                STAGE_ABORT);
        return names;
    }
}
