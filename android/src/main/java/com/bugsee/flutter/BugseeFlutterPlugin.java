package com.bugsee.flutter;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The Dart <-> native bridge. Registration of the wrapper is not done here: it
 * happens at process start in {@link FlutterWrapperInitProvider}, long before an
 * engine exists. This class only serves Dart once Dart asks.
 *
 * <p>Internal: no public API yet (Phase 4).
 */
public class BugseeFlutterPlugin
        implements FlutterPlugin, ActivityAware, Messages.BugseeBridgeHostApi {

    private static final String TAG = FlutterWrapperInitProvider.TAG;

    private static final AtomicLong NEXT_OWNER = new AtomicLong(1);
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    /** Every attached engine's placement tracker, for the SDK pull's refresh. */
    private static final List<SecurePlacement> PLACEMENTS = new CopyOnWriteArrayList<>();
    private static final PullThrottle PULLS = new PullThrottle(
            () -> System.nanoTime() / 1_000_000L,
            MAIN::post,
            BugseeFlutterPlugin::refreshPlacements);

    private static void refreshPlacements() {
        for (final SecurePlacement placement : PLACEMENTS) {
            placement.refresh();
        }
    }

    /** Identifies this engine's Dart isolate in {@link SecureRectangleStore}. */
    private final long owner = NEXT_OWNER.getAndIncrement();
    private BinaryMessenger messenger;
    private LifecycleHub.Sink sink;
    private SecurePlacement placement;

    @Override
    public void onAttachedToEngine(@NonNull final FlutterPluginBinding binding) {
        messenger = binding.getBinaryMessenger();
        Messages.BugseeBridgeHostApi.setUp(messenger, this);

        final SecureRectangleStore store = SecureRectangleStore.shared();
        final SecureEnvironment environment = new SecureEnvironment(binding.getApplicationContext());
        // One environment for the process; it keeps what each engine's view reports.
        store.setEnvironment(environment);
        placement = new SecurePlacement(owner, binding.getFlutterEngine(), store, environment);
        PLACEMENTS.add(placement);
        store.setPullHook(PULLS::request);
        // No activity yet: nothing of this engine is on screen.
        store.setPlacement(owner, SecurePlacement.IMPLICIT_VIEW_ID,
                SecureRectangleStore.Placement.ABSENT);
    }

    @Override
    public void onAttachedToActivity(@NonNull final ActivityPluginBinding binding) {
        if (placement != null) {
            placement.setActivity(binding.getActivity());
        }
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull final ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (placement != null) {
            placement.setActivity(null);
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull final FlutterPluginBinding binding) {
        Messages.BugseeBridgeHostApi.setUp(binding.getBinaryMessenger(), null);
        if (placement != null) {
            PLACEMENTS.remove(placement);
            placement.dispose();
            placement = null;
        }
        // The engine's UI is gone; there is nothing left of it to hide.
        SecureRectangleStore.shared().dropOwner(owner);
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
    @Override
    public Boolean setSecureRectangles(@NonNull final Messages.SecureRectanglesMessage state) {
        final Map<Integer, double[]> views = new HashMap<>();
        for (final Messages.SecureViewRectanglesMessage view : state.getViews()) {
            final List<Double> flat = view.getRectangles();
            final double[] rects = new double[flat.size()];
            for (int i = 0; i < rects.length; i++) {
                rects[i] = flat.get(i);
            }
            views.put(view.getViewId().intValue(), rects);
        }
        final boolean applied = SecureRectangleStore.shared().publish(
                owner, state.getEpoch(), state.getSequence(), views);
        if (applied && placement != null) {
            // Dart just measured, so look at where the view is now rather than
            // trusting what the layout listener last saw.
            placement.refresh();
        }
        return applied;
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
