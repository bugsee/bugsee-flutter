package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.exchange.Breadcrumb;
import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.LogLevel;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

/**
 * The rest of the public facade (Phase 4b): attributes, identity, events, traces, logs, breadcrumbs,
 * notifications, blackout and the two report entry points. What is decided here, with the SDK
 * behind {@link Sdk} so a unit test can see what reaches it.
 *
 * <p>Dart validates every argument first; this defends again (a message that does not come from
 * this Dart version must not reach the SDK in a shape it would silently mishandle) and turns an
 * SDK exception into a {@link Failure} instead of letting it escape onto the platform thread.
 *
 * <p><b>Before launch</b> the wrapper queues and gates nothing: each SDK entry point does what it
 * does (doc/api-surface.md, per method, from v7.4.2 source). Attributes and the user identifier
 * are persisted and work; blackout is held and applied at launch; event, trace, log, breadcrumb,
 * notification, the dialog and upload are dropped by the SDK.
 */
final class FacadeOps {

    /** The strings of a failure's code; {@code test/facade_drift_test.dart} compares them with Dart. */
    static final String INVALID_ARGUMENT = "invalid-argument";
    static final String ATTRIBUTE_REJECTED = "attribute-rejected";
    static final String SDK_ERROR = "sdk-error";
    static final String NOT_ATTACHED = "not-attached";

    /**
     * The longest attribute string Android keeps, in UTF-16 units: {@code BugseeAttributes}
     * {@code CUSTOM_ATTRIBUTE_MAX_LENGTH_LIMIT} (package-private there, so repeated; the device test
     * stores a string of exactly this length and one unit more). Compared with Dart's by the drift guard.
     */
    static final int ATTRIBUTE_STRING_MAX_LENGTH = 1024;

    /** {@code Float.MAX_VALUE}: Android refuses a double at or above it, silently. */
    static final double ATTRIBUTE_NUMBER_LIMIT = (double) Float.MAX_VALUE;

    /** Why a call did not go through: reported to Dart under {@link #code}. */
    static final class Failure extends Exception {
        @NonNull final String code;

        Failure(@NonNull final String code, @NonNull final String message, @Nullable final Throwable cause) {
            super(message, cause);
            this.code = code;
        }

        Failure(@NonNull final String code, @NonNull final String message) {
            this(code, message, null);
        }
    }

    /** The SDK entry points the facade uses; the real ones are {@link BugseeFacadeSdk}. */
    interface Sdk {
        void setAttribute(@NonNull String name, @NonNull Serializable value);

        @Nullable
        Object getAttribute(@NonNull String name);

        @Nullable
        Map<String, ? extends Serializable> getAllAttributes();

        void clearAttribute(@NonNull String name);

        void clearAllAttributes();

        void setUserIdentifier(@Nullable String identifier);

        @Nullable
        String getUserIdentifier();

        void clearUserIdentifier();

        void trace(@NonNull String name, @NonNull Object value);

        /** {@code params} null is the one-argument overload. */
        void event(@NonNull String name, @Nullable LinkedHashMap<String, Object> params);

        void log(@NonNull String message, @NonNull LogLevel level);

        void notifyRelay(
                @NonNull String title,
                @Nullable String body,
                @Nullable IssueSeverity severity,
                @Nullable LinkedHashMap<String, String> fields,
                boolean urgent);

        /**
         * Whether the SDK is {@code Launching} or {@code Launched}: the only states in which
         * {@code BugseeInternal.addBreadcrumb} (v7.4.2:989, {@code isStartedOrStarting}) records.
         */
        boolean isLaunchedOrLaunching();

        /** Whether the SDK was handed the crumb (false: capture off, no crumb made). */
        boolean addBreadcrumb(
                @NonNull String category,
                @NonNull Breadcrumb.Level level,
                @NonNull String message,
                @NonNull String type,
                @Nullable Map<String, Object> data);

        void startBlackout();

        void endBlackout();

        boolean isBlackout();

        void showReportDialog(
                @Nullable String summary,
                @Nullable String description,
                @Nullable IssueSeverity severity,
                @Nullable ArrayList<String> labels);

        void upload(
                @NonNull String summary,
                @NonNull String description,
                @Nullable IssueSeverity severity,
                @Nullable List<String> labels);
    }

    private FacadeOps() {
    }

    // ---- Attributes ---------------------------------------------------------------------------

    /**
     * Sets the attribute and reads it back. The SDK's {@code setAttribute} is void and drops a value
     * over its limit with only a log line, so the read-back is the only way to know: a value the SDK
     * did not keep is {@link #ATTRIBUTE_REJECTED} (and the previous value stays).
     */
    static void setAttribute(@NonNull final Sdk sdk, @Nullable final String name, @Nullable final Object value)
            throws Failure {
        if (name == null || name.isEmpty()) {
            throw new Failure(INVALID_ARGUMENT, "an attribute needs a non-empty name");
        }
        final Serializable checked = checkAttributeValue(value);
        final Object stored;
        try {
            sdk.setAttribute(name, checked);
            stored = sdk.getAttribute(name);
        } catch (final RuntimeException e) {
            throw sdkError("setAttribute", e);
        }
        if (!sameValue(checked, stored)) {
            // Never the value: it is user data.
            throw new Failure(ATTRIBUTE_REJECTED,
                    "the SDK did not keep the attribute (over its size limit, or it could not store it)");
        }
    }

    @NonNull
    static Serializable checkAttributeValue(@Nullable final Object value) throws Failure {
        if (value instanceof String) {
            if (((String) value).length() > ATTRIBUTE_STRING_MAX_LENGTH) {
                throw new Failure(INVALID_ARGUMENT, "an attribute string is at most "
                        + ATTRIBUTE_STRING_MAX_LENGTH + " UTF-16 units");
            }
            return (String) value;
        }
        if (value instanceof Boolean || value instanceof Integer || value instanceof Long) {
            return (Serializable) value;
        }
        if (value instanceof Double) {
            final double d = (Double) value;
            if (Double.isNaN(d) || Double.isInfinite(d) || Math.abs(d) >= ATTRIBUTE_NUMBER_LIMIT) {
                throw new Failure(INVALID_ARGUMENT,
                        "an attribute number must be finite and below the largest 32-bit float");
            }
            return (Double) value;
        }
        throw new Failure(INVALID_ARGUMENT,
                "an attribute value must be a string, a bool, an int or a double");
    }

    /**
     * Whether what the SDK holds is what was sent. A non-integer is stored by Android as a 32-bit
     * float, so a double matches when it equals the stored float after the same narrowing.
     */
    static boolean sameValue(@NonNull final Serializable sent, @Nullable final Object stored) {
        if (stored == null) {
            return false;
        }
        if (sent instanceof String || sent instanceof Boolean) {
            return sent.equals(stored);
        }
        if (sent instanceof Double) {
            // Stored as a 32-bit float (persisted) or still the double (in memory): the same after
            // the same narrowing.
            if (stored instanceof Float) {
                return (float) ((Double) sent).doubleValue() == (Float) stored;
            }
            return stored instanceof Double
                    && (float) ((Double) sent).doubleValue() == (float) ((Double) stored).doubleValue();
        }
        // Integer or Long.
        if (stored instanceof Integer || stored instanceof Long) {
            return ((Number) sent).longValue() == ((Number) stored).longValue();
        }
        return false;
    }

    /**
     * A stored value as the channel carries it: String, Boolean, Integer, Long, Double (a Float as
     * the shortest decimal that names it, {@code 0.1f} is {@code 0.1}, not
     * {@code 0.10000000149011612}) or a sorted List of strings (Android keeps a Set of strings that
     * Dart cannot create). Anything else is {@code null}: a toString would read as a real value.
     */
    @Nullable
    static Object toDartValue(@Nullable final Object stored) {
        if (stored instanceof String || stored instanceof Boolean
                || stored instanceof Integer || stored instanceof Long) {
            return stored;
        }
        // A double is narrowed like a float: Android persists a non-integer as a 32-bit float, and
        // `getAttribute` (in-memory, still the double) and `getAllAttributes` (preferences, the
        // float) would otherwise answer differently in one session (3.141592653589793 against
        // 3.1415927). One answer, the persisted one.
        if (stored instanceof Float || stored instanceof Double) {
            final float f = stored instanceof Float ? (Float) stored : (float) ((Double) stored).doubleValue();
            if (Float.isNaN(f) || Float.isInfinite(f)) {
                return null;
            }
            return Double.valueOf(Float.toString(f));
        }
        if (stored instanceof Set) {
            final TreeSet<String> sorted = new TreeSet<>();
            for (final Object element : (Set<?>) stored) {
                if (!(element instanceof String)) {
                    return null;
                }
                sorted.add((String) element);
            }
            return new ArrayList<>(sorted);
        }
        return null;
    }

    @Nullable
    static Object getAttribute(@NonNull final Sdk sdk, @Nullable final String name) throws Failure {
        if (name == null || name.isEmpty()) {
            throw new Failure(INVALID_ARGUMENT, "an attribute needs a non-empty name");
        }
        try {
            return toDartValue(sdk.getAttribute(name));
        } catch (final RuntimeException e) {
            throw sdkError("getAttribute", e);
        }
    }

    @NonNull
    static Map<String, Object> getAllAttributes(@NonNull final Sdk sdk) throws Failure {
        final Map<String, ? extends Serializable> all;
        try {
            all = sdk.getAllAttributes();
        } catch (final RuntimeException e) {
            throw sdkError("getAllAttributes", e);
        }
        final Map<String, Object> out = new LinkedHashMap<>();
        if (all != null) {
            for (final Map.Entry<String, ? extends Serializable> entry : all.entrySet()) {
                final Object value = toDartValue(entry.getValue());
                if (entry.getKey() != null && value != null) {
                    out.put(entry.getKey(), value);
                }
            }
        }
        return out;
    }

    static void clearAttribute(@NonNull final Sdk sdk, @Nullable final String name) throws Failure {
        if (name == null || name.isEmpty()) {
            throw new Failure(INVALID_ARGUMENT, "an attribute needs a non-empty name");
        }
        try {
            sdk.clearAttribute(name);
        } catch (final RuntimeException e) {
            throw sdkError("clearAttribute", e);
        }
    }

    static void clearAllAttributes(@NonNull final Sdk sdk) throws Failure {
        try {
            sdk.clearAllAttributes();
        } catch (final RuntimeException e) {
            throw sdkError("clearAllAttributes", e);
        }
    }

    // ---- User identifier ----------------------------------------------------------------------

    /**
     * Null or empty clears. Android would otherwise store the empty string and read it back as one
     * while iOS treats setting one as a clear; one behaviour for both.
     */
    static void setUserIdentifier(@NonNull final Sdk sdk, @Nullable final String identifier) throws Failure {
        try {
            if (identifier == null || identifier.isEmpty()) {
                sdk.clearUserIdentifier();
            } else {
                sdk.setUserIdentifier(identifier);
            }
        } catch (final RuntimeException e) {
            throw sdkError("setUserIdentifier", e);
        }
    }

    /** Null when none is set; an empty string (an older run's) reads as none. */
    @Nullable
    static String getUserIdentifier(@NonNull final Sdk sdk) throws Failure {
        try {
            final String id = sdk.getUserIdentifier();
            return id == null || id.isEmpty() ? null : id;
        } catch (final RuntimeException e) {
            throw sdkError("getUserIdentifier", e);
        }
    }

    // ---- Events, traces, logs -----------------------------------------------------------------

    static void trace(@NonNull final Sdk sdk, @Nullable final String name, @Nullable final Object value)
            throws Failure {
        requireName(name, "trace");
        if (!(value instanceof String || value instanceof Boolean || value instanceof Integer
                || value instanceof Long || value instanceof Double)) {
            throw new Failure(INVALID_ARGUMENT, "a trace value must be a string, a bool, an int or a double");
        }
        try {
            sdk.trace(name, value);
        } catch (final RuntimeException e) {
            throw sdkError("trace", e);
        }
    }

    static void event(@NonNull final Sdk sdk, @Nullable final String name, @Nullable final Map<?, ?> params)
            throws Failure {
        requireName(name, "event");
        LinkedHashMap<String, Object> copy = null;
        if (params != null) {
            copy = new LinkedHashMap<>();
            for (final Map.Entry<?, ?> entry : params.entrySet()) {
                if (!(entry.getKey() instanceof String)) {
                    throw new Failure(INVALID_ARGUMENT, "event parameters need string keys");
                }
                copy.put((String) entry.getKey(), entry.getValue());
            }
        }
        try {
            sdk.event(name, copy);
        } catch (final RuntimeException e) {
            throw sdkError("event", e);
        }
    }

    static void log(@NonNull final Sdk sdk, @Nullable final String message, final long level) throws Failure {
        if (message == null) {
            throw new Failure(INVALID_ARGUMENT, "a log message is required");
        }
        final LogLevel constant = level >= Integer.MIN_VALUE && level <= Integer.MAX_VALUE
                ? LaunchOptionValues.logLevel((int) level)
                : null;
        if (constant == null) {
            throw new Failure(INVALID_ARGUMENT, "level must be an SDK log level value (1..5)");
        }
        try {
            sdk.log(message, constant);
        } catch (final RuntimeException e) {
            throw sdkError("log", e);
        }
    }

    // ---- Breadcrumbs, notifications -----------------------------------------------------------

    /** The SDK's level for the wire NAME, or {@code null}. Android's own values are debug 1 .. fatal 5. */
    @Nullable
    static Breadcrumb.Level breadcrumbLevel(@Nullable final String name) {
        if (name == null) {
            return null;
        }
        switch (name) {
            case "debug":
                return Breadcrumb.Level.DEBUG;
            case "info":
                return Breadcrumb.Level.INFO;
            case "warning":
                return Breadcrumb.Level.WARNING;
            case "error":
                return Breadcrumb.Level.ERROR;
            case "fatal":
                return Breadcrumb.Level.FATAL;
            default:
                return null;
        }
    }

    static boolean addBreadcrumb(
            @NonNull final Sdk sdk,
            @Nullable final String category,
            @Nullable final String level,
            @Nullable final String message,
            @Nullable final String type,
            @Nullable final Map<?, ?> data
    ) throws Failure {
        final Breadcrumb.Level parsed = breadcrumbLevel(level);
        if (parsed == null) {
            throw new Failure(INVALID_ARGUMENT, "level must be debug, info, warning, error or fatal");
        }
        if (category == null || message == null || type == null) {
            throw new Failure(INVALID_ARGUMENT, "a breadcrumb needs a category, a message and a type");
        }
        Map<String, Object> copy = null;
        if (data != null) {
            copy = new LinkedHashMap<>();
            for (final Map.Entry<?, ?> entry : data.entrySet()) {
                if (!(entry.getKey() instanceof String)) {
                    throw new Failure(INVALID_ARGUMENT, "breadcrumb data needs string keys");
                }
                copy.put((String) entry.getKey(), entry.getValue());
            }
        }
        try {
            // The factory's consumer is cached for good, and `Bugsee.addBreadcrumb` drops the crumb
            // when the SDK is not running; the answer must say so, so the gate is here, not only in
            // the launch option.
            if (!sdk.isLaunchedOrLaunching()) {
                return false;
            }
            return sdk.addBreadcrumb(category, parsed, message, type, copy);
        } catch (final RuntimeException e) {
            throw sdkError("addBreadcrumb", e);
        }
    }

    static void relayNotification(
            @NonNull final Sdk sdk,
            @Nullable final String title,
            @Nullable final String body,
            @Nullable final Long severity,
            @Nullable final List<?> flatFields,
            final boolean urgent
    ) throws Failure {
        if (title == null || title.trim().isEmpty()) {
            // Both SDKs drop it and only log.
            throw new Failure(INVALID_ARGUMENT, "a notification needs a non-empty title");
        }
        final IssueSeverity sev = optionalSeverity(severity);
        LinkedHashMap<String, String> fields = null;
        if (flatFields != null) {
            if (flatFields.size() % 2 != 0) {
                throw new Failure(INVALID_ARGUMENT, "notification fields are key, value pairs");
            }
            fields = new LinkedHashMap<>();
            for (int i = 0; i < flatFields.size(); i += 2) {
                final Object key = flatFields.get(i);
                final Object value = flatFields.get(i + 1);
                if (!(key instanceof String) || !(value instanceof String)) {
                    throw new Failure(INVALID_ARGUMENT, "notification fields must be strings");
                }
                fields.put((String) key, (String) value);
            }
        }
        try {
            sdk.notifyRelay(title, body, sev, fields, urgent);
        } catch (final RuntimeException e) {
            throw sdkError("notify", e);
        }
    }

    // ---- Blackout -----------------------------------------------------------------------------

    static void startBlackout(@NonNull final Sdk sdk) throws Failure {
        try {
            sdk.startBlackout();
        } catch (final RuntimeException e) {
            throw sdkError("startBlackout", e);
        }
    }

    static void endBlackout(@NonNull final Sdk sdk) throws Failure {
        try {
            sdk.endBlackout();
        } catch (final RuntimeException e) {
            throw sdkError("endBlackout", e);
        }
    }

    static boolean isBlackout(@NonNull final Sdk sdk) throws Failure {
        try {
            return sdk.isBlackout();
        } catch (final RuntimeException e) {
            throw sdkError("isBlackout", e);
        }
    }

    // ---- Reports (no handlers, no attachments: those are the report pipeline's) ---------------

    static void showReportDialog(
            @NonNull final Sdk sdk,
            @Nullable final String summary,
            @Nullable final String description,
            @Nullable final Long severity,
            @Nullable final List<?> labels
    ) throws Failure {
        final IssueSeverity sev = optionalSeverity(severity);
        final ArrayList<String> checked = optionalLabels(labels);
        try {
            sdk.showReportDialog(summary, description, sev, checked);
        } catch (final RuntimeException e) {
            throw sdkError("showReportDialog", e);
        }
    }

    static void upload(
            @NonNull final Sdk sdk,
            @Nullable final String summary,
            @Nullable final String description,
            @Nullable final Long severity,
            @Nullable final List<?> labels
    ) throws Failure {
        if (summary == null || description == null) {
            throw new Failure(INVALID_ARGUMENT, "a report needs a summary and a description");
        }
        final IssueSeverity sev = optionalSeverity(severity);
        final ArrayList<String> checked = optionalLabels(labels);
        try {
            sdk.upload(summary, description, sev, checked);
        } catch (final RuntimeException e) {
            throw sdkError("upload", e);
        }
    }

    // ---- Shared -------------------------------------------------------------------------------

    private static void requireName(@Nullable final String name, @NonNull final String kind) throws Failure {
        if (name == null || name.isEmpty()) {
            throw new Failure(INVALID_ARGUMENT, "a " + kind + " needs a non-empty name");
        }
    }

    @Nullable
    private static IssueSeverity optionalSeverity(@Nullable final Long wire) throws Failure {
        if (wire == null) {
            return null;
        }
        try {
            return ReportOps.severity(wire);
        } catch (final ReportOps.BadArgument e) {
            throw new Failure(INVALID_ARGUMENT, e.getMessage());
        }
    }

    @Nullable
    private static ArrayList<String> optionalLabels(@Nullable final List<?> labels) throws Failure {
        if (labels == null) {
            return null;
        }
        try {
            return ReportOps.labels(labels);
        } catch (final ReportOps.BadArgument e) {
            throw new Failure(INVALID_ARGUMENT, e.getMessage());
        }
    }

    /** The exception's class only: the SDK's message may carry user data. */
    @NonNull
    private static Failure sdkError(@NonNull final String what, @NonNull final RuntimeException e) {
        return new Failure(SDK_ERROR, what + ": the SDK threw " + e.getClass().getName(), e);
    }
}
