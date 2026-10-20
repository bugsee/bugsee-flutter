package com.bugsee.flutter;

import android.util.Log;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;

import java.util.Map;

/**
 * The Dart <-> native bridge. Registration of the wrapper is not done here: it
 * happens at process start in {@link FlutterWrapperInitProvider}, long before an
 * engine exists. This class only serves Dart once Dart asks.
 *
 * <p>Internal: no public API yet (Phase 4).
 */
public class BugseeFlutterPlugin implements FlutterPlugin, Messages.BugseeBridgeHostApi {

    private static final String TAG = FlutterWrapperInitProvider.TAG;

    private BinaryMessenger messenger;
    private LifecycleHub.Sink sink;

    @Override
    public void onAttachedToEngine(@NonNull final FlutterPluginBinding binding) {
        messenger = binding.getBinaryMessenger();
        Messages.BugseeBridgeHostApi.setUp(messenger, this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull final FlutterPluginBinding binding) {
        Messages.BugseeBridgeHostApi.setUp(binding.getBinaryMessenger(), null);
        final LifecycleHub.Sink stale = sink;
        if (stale != null) {
            LifecycleHub.shared().detach(stale);
            sink = null;
        }
        messenger = null;
    }

    @Override
    public void attachLifecycle() {
        if (messenger == null) {
            return;
        }
        final Messages.BugseeBridgeFlutterApi dart = new Messages.BugseeBridgeFlutterApi(messenger);
        final LifecycleHub.Sink fresh = event -> dart.onLifecycleEvent(toMessage(event), RESULT);
        // A second attach from the same engine (Dart hot restart) replaces this
        // engine's receiver only; other engines' receivers are untouched.
        final LifecycleHub.Sink previous = sink;
        if (previous != null) {
            LifecycleHub.shared().detach(previous);
        }
        sink = fresh;
        // Gets what was buffered, in order, and the latest status first if it is not in it.
        LifecycleHub.shared().attach(fresh);
    }

    @Override
    public void setWrapperIdentity(@NonNull final Messages.WrapperIdentityMessage identity) {
        FlutterWrapperInitProvider.registerRefined(
                FlutterWrapperInitProvider.sdkSetter,
                identity.getType(),
                identity.getVersion(),
                identity.getBuild(),
                (Map<?, ?>) identity.getContext());
    }

    @NonNull
    static Messages.LifecycleEventMessage toMessage(@NonNull final LifecycleHub.Event event) {
        return new Messages.LifecycleEventMessage.Builder()
                .setName(event.name)
                .setReportId(event.reportId)
                .setData(event.data)
                .build();
    }

    private static final Messages.VoidResult RESULT = new Messages.VoidResult() {
        @Override
        public void success() {}

        @Override
        public void error(@NonNull final Throwable error) {
            // Dart not listening (hot restart, teardown): nothing to do; the
            // status is also kept Dart-side.
            Log.w(TAG, "lifecycle event not delivered: " + error.getClass().getName());
        }
    };
}
