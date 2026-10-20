package com.bugsee.flutter;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.Bugsee;
import com.bugsee.library.BugseeExtensionInitProviderBase;
import com.bugsee.library.contracts.internal.BugseeWrapper;

/**
 * Registers the Flutter wrapper with the SDK before the SDK can launch.
 *
 * <p>Under auto-init the SDK launches from its own {@code BugseeInitProvider},
 * a ContentProvider, which runs before {@code Application.onCreate}, long
 * before a Dart isolate exists. Registering from Dart cannot beat that, and
 * the miss shows only on a relaunch after a crash (workbook Part 2). Providers
 * start in descending {@code initOrder}, so 200 runs ahead of the SDK's 100.
 *
 * <p>The class name is load-bearing: the Bugsee Gradle plugin deletes every
 * provider matching {@code ^.*\.Bugsee[A-Za-z0-9_]+InitProvider$} from the
 * merged manifest. {@code FlutterWrapperInitProvider} does not match; a test
 * asserts it.
 */
public final class FlutterWrapperInitProvider extends BugseeExtensionInitProviderBase {

    static final String TAG = "BugseeFlutter";

    /** Its own interface: {@code java.util.function} needs API 24, minSdk is 21. */
    interface Setter {
        void set(@Nullable BugseeWrapper wrapper);
    }

    /** The SDK entry point; a seam so a test can see what reaches it. */
    static volatile Setter sdkSetter = Bugsee::setWrapper;

    @Override
    protected boolean onExtensionCreate() {
        registerEarly(sdkSetter);
        // We expose no content.
        return false;
    }

    /**
     * Never throws, errors included. This runs before {@code Application.onCreate}
     * in every host app that links the plugin, so a throw kills the process
     * before the app runs a line of its own.
     */
    static void registerEarly(@NonNull final Setter register) {
        try {
            register.set(FlutterWrapper.atProcessStart());
            // Debug-visible proof of ordering; one line, no payload.
            Log.i(TAG, "wrapper registered type=" + FlutterWrapper.WRAPPER_TYPE
                    + " version=" + BuildConfig.WRAPPER_VERSION);
        } catch (Throwable t) {
            Log.e(TAG, "could not register the Flutter wrapper at process start: "
                    + t.getClass().getName());
        }
    }
}
