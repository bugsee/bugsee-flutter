package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.Bugsee;
import com.bugsee.library.contracts.internal.BugseeWrapperChannel;
import com.bugsee.library.contracts.lifecycle.BugseeStatus;
import com.bugsee.library.contracts.options.LogLevel;
import com.bugsee.library.contracts.options.Options;
import com.bugsee.library.contracts.options.OptionsContainer;

/**
 * The real Android SDK behind {@link LogOps.Sdk}. Nothing is decided here (see {@link LogOps}):
 * each method is one SDK call, made on the plugin's serial background thread.
 */
final class BugseeLogSdk implements LogOps.Sdk {

    private final NetworkChannelHolder channels;

    BugseeLogSdk(@NonNull final NetworkChannelHolder channels) {
        this.channels = channels;
    }

    @Override
    public boolean acceptsLogs() {
        final BugseeStatus status = Bugsee.getStatus();
        if (status != BugseeStatus.Launching && status != BugseeStatus.Launched) {
            return false;
        }
        final OptionsContainer options = Bugsee.getLaunchOptions();
        // The option's own default: capture.logs is on unless the app turned it off.
        return options == null || options.getOption(Options.CaptureLogs, Boolean.TRUE);
    }

    @Override
    public boolean submit(@Nullable final String tag, @NonNull final String message, final int level) {
        final LogLevel sdkLevel = LogLevel.fromRawValue((byte) level, null);
        if (sdkLevel == null) {
            return false;
        }
        final BugseeWrapperChannel channel = channels.get();
        if (channel == null) {
            return false;
        }
        // Always filtered by the SDK (the channel has no flag), attributed to the wrapper.
        channel.log(tag, message, sdkLevel, LogOps.WRAPPER_SOURCE);
        return true;
    }
}
