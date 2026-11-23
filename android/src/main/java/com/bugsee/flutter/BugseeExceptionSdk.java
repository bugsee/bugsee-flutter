package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.Bugsee;
import com.bugsee.library.contracts.lifecycle.BugseeStatus;

import java.util.Map;

/** The real Android SDK behind {@link ExceptionOps.Sdk}: one SDK call each, nothing decided here. */
final class BugseeExceptionSdk implements ExceptionOps.Sdk {

    @Override
    public boolean isLaunchedOrLaunching() {
        final BugseeStatus status = Bugsee.getStatus();
        return status == BugseeStatus.Launching || status == BugseeStatus.Launched;
    }

    @Override
    public void logException(@NonNull final Throwable throwable, @Nullable final String domain, final int skipFrames) {
        Bugsee.logException(throwable, domain, skipFrames);
    }

    @Override
    public void logUnhandledException(@NonNull final Throwable throwable, @Nullable final Map<String, Object> options) {
        Bugsee.logUnhandledException(throwable, options);
    }
}
