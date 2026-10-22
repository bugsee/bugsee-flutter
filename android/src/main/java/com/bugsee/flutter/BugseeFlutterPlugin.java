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

import java.util.ArrayList;
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
 * <p>Internal: the public API is `lib/bugsee_flutter.dart`; this is its native end.
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
            task -> {
                // Only a request that is really posted counts as one in flight (see the store).
                SecureRectangleStore.shared().refreshRequested();
                MAIN.post(task);
            },
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
        try {
            for (final SecurePlacement placement : PLACEMENTS) {
                placement.refresh();
            }
        } finally {
            SecureRectangleStore.shared().refreshCompleted();
        }
    }

    /** Identifies this engine's Dart isolate in {@link SecureRectangleStore}. */
    private final long owner = NEXT_OWNER.getAndIncrement();
    private BinaryMessenger messenger;
    private LaunchOps.Sdk sdk;
    /** Non-null while attached to an engine, like {@link #sdk}; every facade call needs it. */
    private FacadeOps.Sdk facade;
    /** Network injection (Phase 5b); non-null while attached, like {@link #facade}. */
    private volatile NetworkOps.Sdk network;
    private volatile ExceptionOps.Sdk exceptions;
    private LifecycleHub.Sink sink;
    private SecurePlacement placement;
    /** Identifies this engine's Dart isolate in {@link ReportHandlerPipeline}. */
    private final Object reportOwner = new Object();

    @Override
    public void onAttachedToEngine(@NonNull final FlutterPluginBinding binding) {
        messenger = binding.getBinaryMessenger();
        sdk = new BugseeSdk(binding.getApplicationContext());
        facade = new BugseeFacadeSdk();
        network = new BugseeNetworkSdk(NetworkChannelHolder.shared());
        exceptions = new BugseeExceptionSdk();
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
        // Its created report, if any, goes with it; another engine's does not.
        FILES.reset(reportOwner);
        // The engine's UI is gone; there is nothing left of it to hide.
        SecureRectangleStore.shared().dropOwner(owner);
        final LifecycleHub.Sink stale = sink;
        if (stale != null) {
            LifecycleHub.shared().detach(stale);
            sink = null;
        }
        messenger = null;
        sdk = null;
        facade = null;
        network = null;
        exceptions = null;
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
        // A new Dart isolate does not know the old one's created report: release it now, not at its
        // deadline.
        FILES.reset(reportOwner);
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
                .setAttachments(attachmentMessages(s.attachments))
                .setScreenshots(screenshotMessages(s.screenshots))
                .build();
    }

    @NonNull
    private static List<Messages.ReportAttachmentMessage> attachmentMessages(
            @NonNull final List<String[]> attachments
    ) {
        final List<Messages.ReportAttachmentMessage> result = new ArrayList<>();
        for (final String[] a : attachments) {
            result.add(new Messages.ReportAttachmentMessage.Builder()
                    .setName(a[0]).setMimeType(a[1]).setFileName(a[2]).build());
        }
        return result;
    }

    @NonNull
    private static List<Messages.ReportScreenshotMessage> screenshotMessages(
            @NonNull final List<int[]> screenshots
    ) {
        final List<Messages.ReportScreenshotMessage> result = new ArrayList<>();
        for (final int[] shot : screenshots) {
            result.add(new Messages.ReportScreenshotMessage.Builder()
                    .setDisplayId((long) shot[0]).setAnnotated(shot[1] != 0).build());
        }
        return result;
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

    // ---- Attachments, screenshots and createReport (Phase 6; see ReportFileFlow) -------------------

    private static final ReportFileFlow FILES = ReportFileFlow.shared();

    /** A pigeon reply as the flow's {@link ReportFileFlow.Reply}; the flow posts it to the platform thread. */
    @NonNull
    private static <T> ReportFileFlow.Reply<T> reply(@NonNull final Messages.NullableResult<T> result) {
        return new ReportFileFlow.Reply<T>() {
            @Override
            public void success(@Nullable final T value) {
                result.success(value);
            }

            @Override
            public void error(@NonNull final String code, @NonNull final String message) {
                result.error(new Messages.FlutterError(code, message, null));
            }
        };
    }

    @NonNull
    private static <T> ReportFileFlow.Reply<T> reply(@NonNull final Messages.Result<T> result) {
        return new ReportFileFlow.Reply<T>() {
            @Override
            public void success(@Nullable final T value) {
                result.success(value);
            }

            @Override
            public void error(@NonNull final String code, @NonNull final String message) {
                result.error(new Messages.FlutterError(code, message, null));
            }
        };
    }

    @Override
    public void reportAddAttachment(
            @NonNull final String handle,
            @NonNull final String path,
            @NonNull final String name,
            @Nullable final String mimeType,
            @NonNull final Boolean move,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.handlerOp(handle, (report, window) -> ReportOps.addFile(report, path, name, mimeType, move, window), reply(result));
    }

    @Override
    public void reportAddAttachmentBytes(
            @NonNull final String handle,
            @NonNull final byte[] data,
            @NonNull final String name,
            @Nullable final String mimeType,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.handlerOp(handle, (report, window) -> ReportOps.addBytes(report, data, name, mimeType, window), reply(result));
    }

    @Override
    public void reportClearAttachments(
            @NonNull final String handle,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.handlerOp(handle, (report, window) -> ReportOps.clearAttachments(report), reply(result));
    }

    @Override
    public void reportSetScreenshot(
            @NonNull final String handle,
            @NonNull final String path,
            @NonNull final Long displayId,
            @NonNull final Boolean annotated,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.handlerOp(handle, (report, window) -> FILES.setScreenshot(report, path, displayId, annotated), reply(result));
    }

    @Override
    public void reportRemoveScreenshot(
            @NonNull final String handle,
            @NonNull final Long displayId,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.handlerOp(handle, (report, window) -> ReportOps.removeScreenshot(report, displayId), reply(result));
    }

    @Override
    public void createReport(
            @NonNull final Long ttlMs,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.create(reportOwner, ttlMs, reply(result));
    }

    @Nullable
    @Override
    public Messages.CreatedReportSnapshotMessage createdReportRead(@NonNull final String handle) {
        final CreatedReportOps.Snapshot s = FILES.read(handle);
        if (s == null) {
            return null;
        }
        final List<Long> ids = new ArrayList<>();
        for (final Integer id : s.screenshotDisplayIds) {
            ids.add(id.longValue());
        }
        return new Messages.CreatedReportSnapshotMessage.Builder()
                .setReportId(s.id)
                .setType(s.type)
                .setSummary(s.summary)
                .setReportDescription(s.description)
                .setSeverity(s.severity == null ? null : s.severity.longValue())
                .setLabels(s.labels)
                .setAttributes(s.attributes)
                .setAttachmentNames(s.attachmentNames)
                .setScreenshotDisplayIds(ids)
                .build();
    }

    @NonNull
    @Override
    public Boolean createdReportApply(
            @NonNull final String handle,
            @NonNull final Messages.CreatedReportPatchMessage patch
    ) {
        final CreatedReportOps.Patch p = new CreatedReportOps.Patch();
        p.setSummary = patch.getSetSummary();
        p.summary = patch.getSummary();
        p.setDescription = patch.getSetDescription();
        p.description = patch.getReportDescription();
        p.severity = patch.getSeverity();
        p.labels = patch.getLabels();
        p.clearAttributes = patch.getClearAttributes();
        p.attributes = patch.getAttributes();
        p.removeAttributes = patch.getRemoveAttributes();
        try {
            return FILES.apply(handle, p);
        } catch (final ReportOps.BadArgument e) {
            throw new Messages.FlutterError(FacadeOps.INVALID_ARGUMENT, e.getMessage(), null);
        }
    }

    @Override
    public void createdReportAddAttachment(
            @NonNull final String handle,
            @NonNull final String path,
            @NonNull final String name,
            @Nullable final String mimeType,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.createdAddFile(handle, path, name, mimeType, reply(result));
    }

    @Override
    public void createdReportAddAttachmentBytes(
            @NonNull final String handle,
            @NonNull final byte[] data,
            @NonNull final String name,
            @Nullable final String mimeType,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.createdAddBytes(handle, data, name, mimeType, reply(result));
    }

    @Override
    public void createdReportClearAttachments(
            @NonNull final String handle,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.createdOp(handle, (report, window) -> ReportOps.clearAttachments(report), reply(result));
    }

    @Override
    public void createdReportSetScreenshot(
            @NonNull final String handle,
            @NonNull final String path,
            @NonNull final Boolean annotated,
            @NonNull final Messages.NullableResult<String> result
    ) {
        FILES.createdOp(handle, (report, window) -> FILES.setScreenshot(report, path, 0L, annotated), reply(result));
    }

    @Override
    public void createdReportUpload(
            @NonNull final String handle,
            @NonNull final Messages.Result<Boolean> result
    ) {
        FILES.upload(handle, reply(result));
    }

    @Override
    public void createdReportDiscard(@NonNull final String handle) {
        FILES.discard(handle);
    }

    // ---- Launch, stop, status (workbook Part 8; see LaunchOps) -------------------------------

    @NonNull
    private LaunchOps.Sdk sdkOrThrow() {
        final LaunchOps.Sdk current = sdk;
        if (current == null) {
            throw new Messages.FlutterError(LaunchOps.ERROR_CODE, "the plugin is not attached to an engine", null);
        }
        return current;
    }

    /** The SDK's callbacks may come on any thread; a channel reply goes on the platform thread. */
    private static void onMain(@NonNull final Runnable action) {
        MAIN.post(action);
    }

    /** The platform thread, for the report file flow. */
    static void postToMain(@NonNull final Runnable action) {
        MAIN.post(action);
    }

    @NonNull
    private static Messages.FlutterError launchError(@NonNull final Throwable t) {
        // The class and message only: never the token or the options.
        return new Messages.FlutterError(LaunchOps.ERROR_CODE,
                t.getClass().getName() + (t.getMessage() == null ? "" : ": " + t.getMessage()), null);
    }

    @Override
    public void launch(
            @NonNull final String token,
            @NonNull final Map<String, Object> options,
            @NonNull final Messages.Result<Messages.LaunchOutcomeMessage> result
    ) {
        final LaunchOps.Sdk current;
        try {
            current = sdkOrThrow();
        } catch (final Messages.FlutterError e) {
            result.error(e);
            return;
        }
        LaunchOps.launch(current, token, options,
                (outcome, reason) -> onMain(() -> result.success(
                        new Messages.LaunchOutcomeMessage.Builder()
                                .setOutcome(outcome)
                                .setReason(reason)
                                .build())),
                t -> onMain(() -> result.error(launchError(t))));
    }

    @Override
    public void stop(@NonNull final Messages.VoidResult result) {
        final LaunchOps.Sdk current;
        try {
            current = sdkOrThrow();
        } catch (final Messages.FlutterError e) {
            result.error(e);
            return;
        }
        LaunchOps.stop(current, () -> onMain(result::success), t -> onMain(() -> result.error(launchError(t))));
    }

    @NonNull
    @Override
    public String status() {
        return LaunchOps.status(sdkOrThrow());
    }

    @NonNull
    @Override
    public Map<String, Object> launchOptions(@NonNull final Boolean hostOnly) {
        return LaunchOps.launchOptions(sdkOrThrow(), hostOnly);
    }

    // ---- Facade (Phase 4b; see FacadeOps) -----------------------------------------------------
    //
    // Pigeon runs these handlers on the platform (main) thread, the thread the SDK's public API
    // is documented to be called from; nothing here keeps state, and the SDK serialises its own.

    private interface FacadeCall<T> {
        T run(@NonNull FacadeOps.Sdk sdk) throws FacadeOps.Failure;
    }

    private <T> T facade(@NonNull final FacadeCall<T> call) {
        final FacadeOps.Sdk current = facade;
        if (current == null) {
            throw new Messages.FlutterError(FacadeOps.NOT_ATTACHED,
                    "the plugin is not attached to an engine", null);
        }
        try {
            return call.run(current);
        } catch (final FacadeOps.Failure failure) {
            throw new Messages.FlutterError(failure.code, failure.getMessage(), null);
        }
    }

    @Override
    public void setAttribute(@NonNull final String name, @NonNull final Object value) {
        facade(sdk -> {
            FacadeOps.setAttribute(sdk, name, value);
            return null;
        });
    }

    @Nullable
    @Override
    public Object getAttribute(@NonNull final String name) {
        return facade(sdk -> FacadeOps.getAttribute(sdk, name));
    }

    @NonNull
    @Override
    public Map<String, Object> getAllAttributes() {
        return facade(FacadeOps::getAllAttributes);
    }

    @Override
    public void clearAttribute(@NonNull final String name) {
        facade(sdk -> {
            FacadeOps.clearAttribute(sdk, name);
            return null;
        });
    }

    @Override
    public void clearAllAttributes() {
        facade(sdk -> {
            FacadeOps.clearAllAttributes(sdk);
            return null;
        });
    }

    @Override
    public void setUserIdentifier(@Nullable final String identifier) {
        facade(sdk -> {
            FacadeOps.setUserIdentifier(sdk, identifier);
            return null;
        });
    }

    @Nullable
    @Override
    public String getUserIdentifier() {
        return facade(FacadeOps::getUserIdentifier);
    }

    @Override
    public void trace(@NonNull final String name, @NonNull final Object value) {
        facade(sdk -> {
            FacadeOps.trace(sdk, name, value);
            return null;
        });
    }

    @Override
    public void event(@NonNull final String name, @Nullable final Map<String, Object> params) {
        facade(sdk -> {
            FacadeOps.event(sdk, name, params);
            return null;
        });
    }

    @NonNull
    @Override
    public Boolean addBreadcrumb(@NonNull final Messages.BreadcrumbMessage crumb) {
        return facade(sdk -> FacadeOps.addBreadcrumb(sdk, crumb.getCategory(), crumb.getLevel(),
                crumb.getMessage(), crumb.getType(), crumb.getData()));
    }

    @Override
    public void relayNotification(
            @NonNull final String title,
            @Nullable final String body,
            @Nullable final Long severity,
            @Nullable final List<String> fields,
            @NonNull final Boolean urgent
    ) {
        facade(sdk -> {
            FacadeOps.relayNotification(sdk, title, body, severity, fields, urgent);
            return null;
        });
    }

    @Override
    public void log(@NonNull final String message, @NonNull final Long level) {
        facade(sdk -> {
            FacadeOps.log(sdk, message, level);
            return null;
        });
    }

    @Override
    public void startBlackout() {
        facade(sdk -> {
            FacadeOps.startBlackout(sdk);
            return null;
        });
    }

    @Override
    public void endBlackout() {
        facade(sdk -> {
            FacadeOps.endBlackout(sdk);
            return null;
        });
    }

    @NonNull
    @Override
    public Boolean isBlackout() {
        return facade(FacadeOps::isBlackout);
    }

    @Override
    public void showReportDialog(
            @Nullable final String summary,
            @Nullable final String description,
            @Nullable final Long severity,
            @Nullable final List<String> labels
    ) {
        facade(sdk -> {
            FacadeOps.showReportDialog(sdk, summary, description, severity, labels);
            return null;
        });
    }

    @Override
    public void upload(
            @NonNull final String summary,
            @NonNull final String description,
            @Nullable final Long severity,
            @Nullable final List<String> labels
    ) {
        facade(sdk -> {
            FacadeOps.upload(sdk, summary, description, severity, labels);
            return null;
        });
    }

    // ---- Network capture (Phase 5b; see NetworkOps) ---------------------------------------------

    @NonNull
    @Override
    public Long addNetworkEvents(@NonNull final List<Messages.NetworkEventMessage> events) {
        final NetworkOps.Sdk current = network;
        if (current == null) {
            throw new Messages.FlutterError(FacadeOps.NOT_ATTACHED,
                    "the plugin is not attached to an engine", null);
        }
        return (long) NetworkOps.addAll(current, events);
    }

    // ---- Exceptions (Phase 5a; see ExceptionOps) ----------------------------------------------

    @Override
    public void logException(
            @NonNull final String payload,
            @NonNull final Boolean handled,
            @Nullable final String domain,
            @NonNull final Messages.Result<Boolean> result
    ) {
        final ExceptionOps.Sdk current = exceptions;
        if (current == null) {
            result.error(new Messages.FlutterError(FacadeOps.NOT_ATTACHED,
                    "the plugin is not attached to an engine", null));
            return;
        }
        // Off the platform thread: the SDK writes an unhandled report on the calling one. The
        // launch gate is inside ExceptionOps.log, so it runs where and when the SDK call does.
        ExceptionDispatcher.shared().submit(
                () -> ExceptionOps.log(current, payload, handled, domain),
                new ExceptionDispatcher.Done() {
                    @Override
                    public void success(final boolean handedToSdk) {
                        onMain(() -> result.success(handedToSdk));
                    }

                    @Override
                    public void failure(@NonNull final String code, @NonNull final String message) {
                        onMain(() -> result.error(new Messages.FlutterError(code, message, null)));
                    }
                });
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
