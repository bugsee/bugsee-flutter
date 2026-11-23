package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.Bugsee;
import com.bugsee.library.contracts.exchange.BugseeExchangeFactory;
import com.bugsee.library.contracts.exchange.NetworkEvent;
import com.bugsee.library.contracts.internal.BugseeWrapperChannel;
import com.bugsee.library.contracts.lifecycle.BugseeStatus;
import com.bugsee.library.contracts.options.Options;
import com.bugsee.library.contracts.options.OptionsContainer;

import java.util.Map;

/**
 * The real Android SDK behind {@link NetworkOps.Sdk}. Nothing is decided here (see
 * {@link NetworkOps}): each method is one SDK call, made on the plugin's serial background thread (the Pigeon
 * method has a task queue: the SDK's sanitizer and the app's native filter run on the calling
 * thread and must not take UI time).
 */
final class BugseeNetworkSdk implements NetworkOps.Sdk {

    private final NetworkChannelHolder channels;

    BugseeNetworkSdk(@NonNull final NetworkChannelHolder channels) {
        this.channels = channels;
    }

    @Override
    public boolean acceptsNetworkEvents() {
        if (Bugsee.getStatus() != BugseeStatus.Launched) {
            return false;
        }
        final OptionsContainer options = Bugsee.getLaunchOptions();
        // The option's own default: capture.network is on unless the app turned it off.
        return options == null || options.getOption(Options.CaptureNetwork, Boolean.TRUE);
    }

    @Override
    public long currentTimestamp() {
        final BugseeExchangeFactory factory = Bugsee.getExchangeFactory();
        return factory == null ? System.currentTimeMillis() : factory.currentTimestamp();
    }

    @Nullable
    @Override
    public NetworkEvent create(
            final long timestamp,
            @NonNull final NetworkEvent.NetworkEventStage stage,
            @NonNull final String id,
            @NonNull final String mechanism,
            @Nullable final String method,
            @NonNull final String url,
            @Nullable final Map<String, String> headers,
            @Nullable final String body,
            final long size,
            final int bodyByteSize,
            @Nullable final NetworkEvent.NetworkBodyAbsenceReason reason,
            final int responseCode,
            @Nullable final String statusText,
            @Nullable final String errorShortMessage,
            @Nullable final String errorDescription,
            @Nullable final Map<String, Double> timings
    ) {
        final BugseeExchangeFactory factory = Bugsee.getExchangeFactory();
        if (factory == null) {
            return null;
        }
        return factory.createNetworkEvent(timestamp, stage, id, mechanism, method, url, headers,
                body, size, bodyByteSize, reason, responseCode, statusText, errorShortMessage,
                errorDescription, timings);
    }

    @Override
    public boolean submit(@NonNull final NetworkEvent event) {
        final BugseeWrapperChannel channel = channels.get();
        if (channel == null) {
            return false;
        }
        // Filtering REQUIRED: the default sanitizer and the app's native filter must see it.
        channel.addNetworkEvent(event, true);
        return true;
    }
}
