package com.bugsee.flutter;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.reporting.Report;

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

    private static SecureEnvironment sharedEnvironment;

    /** One per process: every engine's placement records its view's resources in it. */
    private static synchronized SecureEnvironment environment(
            @NonNull final android.content.Context context) {
        if (sharedEnvironment == null) {
            sharedEnvironment = new SecureEnvironment(context);
        }
        return sharedEnvironment;
    }

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
    /** Identifies this engine's Dart isolate in {@link ReportHandlerPipeline}. */
    private final Object reportOwner = new Object();

    @Override
    public void onAttachedToEngine(@NonNull final FlutterPluginBinding binding) {
        messenger = binding.getBinaryMessenger();
        Messages.BugseeBridgeHostApi.setUp(messenger, this);

        final SecureRectangleStore store = SecureRectangleStore.shared();
        final SecureEnvironment environment = environment(binding.getApplicationContext());
        // One environment for the process; it keeps what each engine's view reports.
        store.setEnvironment(environment);
        placement = new SecurePlacement(owner, binding.getFlutterEngine(), store, environment);
        PLACEMENTS.add(placement);
        store.setPullHook(PULLS::request);
        ReportHandlerPipeline.shared().attach(reportOwner, this::sendReportRequest);
        // No activity yet: where the view is is not known, so cover rather than guess.
        store.setPlacement(owner, SecurePlacement.IMPLICIT_VIEW_ID,
                SecureRectangleStore.Placement.UNKNOWN);
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
        // Completes what was handed to this engine's Dart: nothing else knows those handles.
        ReportHandlerPipeline.shared().detach(reportOwner);
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
        final Map<Integer, SecureRectangleStore.ViewRects> views = new HashMap<>();
        for (final Messages.SecureViewRectanglesMessage view : state.getViews()) {
            final List<Double> flat = view.getRectangles();
            final double[] rects = new double[flat.size()];
            for (int i = 0; i < rects.length; i++) {
                rects[i] = flat.get(i);
            }
            views.put(view.getViewId().intValue(),
                    new SecureRectangleStore.ViewRects(view.getDevicePixelRatio(), rects));
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

    // ---- Report handlers (workbook Part 7) --------------------------------------------

    /** Runs on the platform thread (the pipeline posts it there). Never waits for the reply. */
    private void sendReportRequest(
            @NonNull final ReportHandlerPipeline.Request request,
            @NonNull final Runnable unreachable
    ) {
        final BinaryMessenger current = messenger;
        if (current == null) {
            unreachable.run();
            return;
        }
        final Messages.ReportHandlerRequestMessage message =
                new Messages.ReportHandlerRequestMessage.Builder()
                        .setHandle(request.handle)
                        .setDeliveryId(request.deliveryId)
                        .setAfter(request.after)
                        .setReportId(request.reportId)
                        .setType(request.type)
                        .setDeadlineMs(request.deadlineMs)
                        .build();
        new Messages.BugseeBridgeFlutterApi(current).onReportHandlerRequest(
                message,
                new Messages.VoidResult() {
                    @Override
                    public void success() {
                        // Delivered. The SDK's completion runs when Dart completes the handle.
                    }

                    @Override
                    public void error(@NonNull final Throwable error) {
                        // No Dart handler (hot restart, teardown): answer for it, now.
                        Log.w(TAG, "report handler request not delivered: "
                                + error.getClass().getName());
                        unreachable.run();
                    }
                });
    }

    @Override
    public void resetReportHandlers() {
        ReportHandlerPipeline.shared().reset(reportOwner);
    }

    @Override
    public void setReportHandlerPhases(@NonNull final Boolean before, @NonNull final Boolean after) {
        ReportHandlerPipeline.shared().setPhases(reportOwner, before, after);
    }

    @Override
    public void completeReportHandler(@NonNull final String handle) {
        ReportHandlerPipeline.shared().complete(handle);
    }

    @Nullable
    @Override
    public Messages.ReportSnapshotMessage reportRead(@NonNull final String handle) {
        final Report report = ReportHandlerPipeline.shared().reportFor(handle);
        if (report == null) {
            return null;
        }
        final ReportOps.Snapshot s = ReportOps.read(report);
        return new Messages.ReportSnapshotMessage.Builder()
                .setId(s.id)
                .setType(s.type)
                .setSummary(s.summary)
                .setReportDescription(s.description)
                .setEmail(s.email)
                .setSeverity(s.severity == null ? null : s.severity.longValue())
                .setLabels(s.labels)
                .setAttributes(s.attributes)
                .build();
    }

    @NonNull
    @Override
    public Boolean reportSetSummary(@NonNull final String handle, @Nullable final String value) {
        return edit(handle, report -> report.setSummary(value));
    }

    @NonNull
    @Override
    public Boolean reportSetDescription(@NonNull final String handle, @Nullable final String value) {
        return edit(handle, report -> report.setDescription(value));
    }

    @NonNull
    @Override
    public Boolean reportSetEmail(@NonNull final String handle, @Nullable final String value) {
        return edit(handle, report -> report.setEmail(value));
    }

    @NonNull
    @Override
    public Boolean reportSetSeverity(@NonNull final String handle, @NonNull final Long severity) {
        return edit(handle, report -> ReportOps.setSeverity(report, severity));
    }

    @NonNull
    @Override
    public Boolean reportReplaceLabels(@NonNull final String handle, @NonNull final List<String> labels) {
        return edit(handle, report -> ReportOps.replaceLabels(report, labels));
    }

    @NonNull
    @Override
    public Boolean reportAddLabels(@NonNull final String handle, @NonNull final List<String> labels) {
        return edit(handle, report -> ReportOps.addLabels(report, labels));
    }

    @NonNull
    @Override
    public Boolean reportClearLabels(@NonNull final String handle) {
        return edit(handle, Report::clearLabels);
    }

    @NonNull
    @Override
    public Boolean reportSetAttribute(
            @NonNull final String handle,
            @NonNull final String name,
            @NonNull final Object value
    ) {
        return edit(handle, report -> ReportOps.setAttribute(report, name, value));
    }

    @NonNull
    @Override
    public Boolean reportRemoveAttribute(@NonNull final String handle, @NonNull final String name) {
        return edit(handle, report -> report.removeAttribute(name));
    }

    @NonNull
    @Override
    public Boolean reportClearAttributes(@NonNull final String handle) {
        return edit(handle, Report::clearAllAttributes);
    }

    /** False: the handle is not live, nothing changed. An unusable argument is an error reply. */
    private static boolean edit(
            @NonNull final String handle,
            @NonNull final ReportHandlerPipeline.Edit edit
    ) {
        try {
            return ReportHandlerPipeline.shared().edit(handle, edit);
        } catch (final ReportOps.BadArgument e) {
            throw new Messages.FlutterError("invalid-argument", e.getMessage(), null);
        }
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
