package com.bugsee.flutter;

import android.content.Context;

import androidx.annotation.NonNull;

import com.bugsee.library.Bugsee;

import java.io.Serializable;
import java.util.Map;

/**
 * The real Android SDK behind {@link LaunchOps.Sdk}. Nothing is decided here (see
 * {@link LaunchOps}): each method is one SDK call.
 */
final class BugseeSdk implements LaunchOps.Sdk {

    private final Context context;

    BugseeSdk(@NonNull final Context applicationContext) {
        this.context = applicationContext;
    }

    @NonNull
    @Override
    public String status() {
        return LaunchOps.statusName(Bugsee.getStatus());
    }

    @Override
    public void launch(
            @NonNull final String token,
            @NonNull final Map<String, Serializable> options,
            @NonNull final LaunchOps.Done done
    ) {
        // `Bugsee.launch(context, token, options, callback)`: true once the SDK is running, false
        // when it did not launch. May be called on a background thread.
        Bugsee.launch(context, token, options, ok -> done.run(Boolean.TRUE.equals(ok)));
    }

    @Override
    public void stop(@NonNull final Runnable done) {
        Bugsee.stop(done);
    }

    @NonNull
    @Override
    public Map<String, ? extends Serializable> launchOptions(final boolean hostOnly) {
        return hostOnly ? Bugsee.getHostLaunchOptions() : Bugsee.getLaunchOptions().toMap();
    }
}
