package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.common.DataRequestResultCallback;
import com.bugsee.library.contracts.internal.BugseeWrapper;
import com.bugsee.library.contracts.internal.BugseeWrapperChannel;
import com.bugsee.library.contracts.reporting.Report;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/**
 * The Flutter wrapper registered with the SDK.
 *
 * <p>Identity is real (workbook Part 3), and lifecycle events are forwarded
 * (Part 4). The rest is a deliberately inert stub until Phase 3 gives it
 * behaviour: data requests are answered with {@code null}. Report handlers go through
 * {@link ReportHandlerPipeline}. Every method is
 * safe to be called by the SDK at any time, from any thread, and none throws.
 *
 * <p>This object is replaced mid-session when Dart refines the identity, so it
 * holds no state that must survive: lifecycle events go to the process-wide
 * {@link LifecycleHub} and secure rectangles come from the process-wide
 * {@link SecureRectangleStore} (5.4.2).
 */
final class FlutterWrapper implements BugseeWrapper {

    /**
     * The backend's identifier for this wrapper. Duplicated from
     * {@code wrapperType} in {@code lib/src/wrapper_identity.dart} because this
     * registers before Dart exists; a test compares the copies.
     */
    static final String WRAPPER_TYPE = "flutter";

    static final String UNKNOWN = "unknown";

    private final String type;
    private final String version;
    @Nullable
    private final String build;
    private final Map<String, String> context;
    private final LifecycleHub lifecycle;
    private final SecureRectangleStore secureRectangles;
    private final ReportHandlerPipeline reports;

    /** The identity knowable before Dart exists: type and version only. */
    @NonNull
    static FlutterWrapper atProcessStart() {
        return create(WRAPPER_TYPE, BuildConfig.WRAPPER_VERSION, null, null);
    }

    /**
     * Builds an identity the way the contract wants it: a missing or empty
     * type/version becomes {@code "unknown"} (an empty version reads as "this
     * wrapper has no version"), and context entries that are not
     * string-to-string are dropped, not stringified.
     */
    @NonNull
    static FlutterWrapper create(
            @Nullable final Object type,
            @Nullable final Object version,
            @Nullable final Object build,
            @Nullable final Object context
    ) {
        return create(type, version, build, context,
                LifecycleHub.shared(), SecureRectangleStore.shared(), ReportHandlerPipeline.shared());
    }

    /** As above with the process-wide collaborators supplied; for tests. */
    @NonNull
    static FlutterWrapper create(
            @Nullable final Object type,
            @Nullable final Object version,
            @Nullable final Object build,
            @Nullable final Object context,
            @NonNull final LifecycleHub lifecycle,
            @NonNull final SecureRectangleStore secureRectangles
    ) {
        return create(type, version, build, context, lifecycle, secureRectangles,
                ReportHandlerPipeline.shared());
    }

    /** As above with every process-wide collaborator supplied; for tests. */
    @NonNull
    static FlutterWrapper create(
            @Nullable final Object type,
            @Nullable final Object version,
            @Nullable final Object build,
            @Nullable final Object context,
            @NonNull final LifecycleHub lifecycle,
            @NonNull final SecureRectangleStore secureRectangles,
            @NonNull final ReportHandlerPipeline reports
    ) {
        final Map<String, String> cleaned = new HashMap<>();
        if (context instanceof Map) {
            for (final Map.Entry<?, ?> e : ((Map<?, ?>) context).entrySet()) {
                if (e.getKey() instanceof String && e.getValue() instanceof String) {
                    cleaned.put((String) e.getKey(), (String) e.getValue());
                }
            }
        }
        return new FlutterWrapper(
                stringOr(type, UNKNOWN),
                stringOr(version, UNKNOWN),
                build instanceof String ? (String) build : null,
                cleaned,
                lifecycle,
                secureRectangles,
                reports);
    }

    private static String stringOr(@Nullable final Object value, @NonNull final String fallback) {
        return value instanceof String && !((String) value).isEmpty() ? (String) value : fallback;
    }

    private FlutterWrapper(
            @NonNull final String type,
            @NonNull final String version,
            @Nullable final String build,
            @NonNull final Map<String, String> context,
            @NonNull final LifecycleHub lifecycle,
            @NonNull final SecureRectangleStore secureRectangles,
            @NonNull final ReportHandlerPipeline reports
    ) {
        this.lifecycle = lifecycle;
        this.secureRectangles = secureRectangles;
        this.reports = reports;
        this.type = type;
        this.version = version;
        this.build = build;
        this.context = Collections.unmodifiableMap(context);
    }

    @NonNull
    @Override
    public String getWrapperType() {
        return type;
    }

    @NonNull
    @Override
    public String getWrapperVersion() {
        return version;
    }

    @Nullable
    @Override
    public String getWrapperBuild() {
        return build;
    }

    @Nullable
    @Override
    public Map<String, String> getContext() {
        return context;
    }

    /**
     * Always answers, and always with null for now: the one flow that exists is {@code vh}
     * (the managed view hierarchy, Phase 5), and an unknown type is answered with null
     * (workbook 6.1). Silence would cost the SDK the whole 500 ms budget, so even a
     * {@code vh} request is answered, with null, until Phase 5 produces a payload.
     * Never throws, whatever the SDK or its callback does.
     */
    @Override
    public void requestData(
            @NonNull final String dataType,
            @NonNull final DataRequestResultCallback callback
    ) {
        try {
            callback.onResult(null);
        } catch (Throwable ignored) {
            // The SDK must never see a throw from a wrapper.
        }
    }

    @Override
    public void onLifecycleEvent(@NonNull final String eventType, @Nullable final Object data) {
        // The SDK's worker thread. The hub strips the prefix, hops to the main
        // thread and never throws.
        lifecycle.dispatch(eventType, data);
    }

    /**
     * The SDK's data-injection channel for THIS registration (v7.4.2 {@code BugseeWrapperChannel}),
     * delivered synchronously inside {@code Bugsee.setWrapper}, under the SDK's registration lock.
     * Store and return, nothing else (calling back into the SDK from here is what the contract
     * warns about). It goes to the process-wide holder: this object is replaced on a refined
     * identity, and the previous channel is retired by the SDK at that moment.
     */
    @Override
    public void onWrapperChannelAvailable(@NonNull final BugseeWrapperChannel channel) {
        NetworkChannelHolder.shared().set(channel);
    }

    @Nullable
    @Override
    public int[] getSecureRectangles(final int display) {
        // From the store, not from this object: this wrapper is replaced.
        return secureRectangles.pull(display);
    }

    /**
     * Report handlers (workbook Part 7): see {@link ReportHandlerPipeline}. The SDK calls
     * these on a thread of its own (never main on the healthy path, but possibly main on a
     * crash path), so nothing here may block, and the SDK's completion runs exactly once
     * whatever happens. The pipeline is process-wide, not part of this replaceable object.
     */
    @Override
    public void onBeforeReportCreated(
            @NonNull final Report report,
            final boolean isTerminating,
            @NonNull final Runnable completionCallback
    ) {
        reports.dispatch(ReportHandlerPipeline.Phase.BEFORE, report, isTerminating, completionCallback);
    }

    @Override
    public void onAfterReportCreated(
            @NonNull final Report report,
            final boolean isTerminating,
            @NonNull final Runnable completionCallback
    ) {
        reports.dispatch(ReportHandlerPipeline.Phase.AFTER, report, isTerminating, completionCallback);
    }
}
