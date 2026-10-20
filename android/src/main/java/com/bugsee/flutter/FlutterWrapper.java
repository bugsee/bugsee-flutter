package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.common.DataRequestResultCallback;
import com.bugsee.library.contracts.internal.BugseeWrapper;
import com.bugsee.library.contracts.reporting.Report;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/**
 * The Flutter wrapper registered with the SDK.
 *
 * <p>Identity is real (workbook Part 3). Everything else is a deliberately
 * inert stub until Phase 3 gives it behaviour: data requests are answered
 * with {@code null}, lifecycle events are dropped, no secure rectangles are
 * contributed, and report handlers complete immediately. Every stub is safe
 * to be called by the SDK at any time, from any thread, and none throws.
 */
final class FlutterWrapper implements BugseeWrapper {

    /**
     * The backend's identifier for this wrapper. Duplicated from
     * {@code wrapperType} in {@code lib/src/wrapper_identity.dart} because this
     * registers before Dart exists; a test compares the copies.
     */
    static final String WRAPPER_TYPE = "flutter";

    static final String UNKNOWN = "unknown";

    /**
     * {@link BugseeWrapper#SECURE_RECTANGLES_VERSION_UNKNOWN}: the SDK then
     * compares the rectangles themselves. A constant real version would let a
     * later wrapper that also starts at that version, with real rectangles, be
     * ignored: the SDK caches by version per display (unredacted capture).
     */
    private static final int EMPTY_SET_VERSION = SECURE_RECTANGLES_VERSION_UNKNOWN;

    private final String type;
    private final String version;
    @Nullable
    private final String build;
    private final Map<String, String> context;

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
                cleaned);
    }

    private static String stringOr(@Nullable final Object value, @NonNull final String fallback) {
        return value instanceof String && !((String) value).isEmpty() ? (String) value : fallback;
    }

    private FlutterWrapper(
            @NonNull final String type,
            @NonNull final String version,
            @Nullable final String build,
            @NonNull final Map<String, String> context
    ) {
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

    /** Phase 3 replaces this. Unknown types are always answered with null. */
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
    }

    @Nullable
    @Override
    public int[] getSecureRectangles(final int display) {
        // [version, count]: no rectangles, version unknown.
        return new int[] {EMPTY_SET_VERSION, 0};
    }

    @Override
    public void onBeforeReportCreated(
            @NonNull final Report report,
            final boolean isTerminating,
            @NonNull final Runnable completionCallback
    ) {
        completionCallback.run();
    }

    @Override
    public void onAfterReportCreated(
            @NonNull final Report report,
            final boolean isTerminating,
            @NonNull final Runnable completionCallback
    ) {
        completionCallback.run();
    }
}
