package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.internal.BugseeWrapperChannel;

/**
 * The SDK's wrapper channel for the CURRENT wrapper registration, process-wide.
 *
 * <p>The SDK hands a new {@link BugseeWrapperChannel} to {@code onWrapperChannelAvailable} for
 * every registration ({@code Bugsee.setWrapper}), synchronously, under its registration lock, and
 * silently retires the previous one. {@link FlutterWrapper} is replaced when Dart refines the
 * identity, so the channel cannot live in it: it lives here, like the lifecycle hub, and the
 * newest delivery wins. {@link #set} only stores (the SDK's contract: store the channel and
 * return; anything else in that callback risks the lock it is delivered under).
 */
final class NetworkChannelHolder {

    private static final NetworkChannelHolder SHARED = new NetworkChannelHolder();

    /** Package-private so a test can hold its own; production uses {@link #shared()}. */
    NetworkChannelHolder() {
    }

    @NonNull
    static NetworkChannelHolder shared() {
        return SHARED;
    }

    @Nullable
    private volatile BugseeWrapperChannel channel;

    void set(@Nullable final BugseeWrapperChannel channel) {
        this.channel = channel;
    }

    @Nullable
    BugseeWrapperChannel get() {
        return channel;
    }
}
