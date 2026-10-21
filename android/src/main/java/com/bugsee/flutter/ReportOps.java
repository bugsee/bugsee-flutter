package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.IssueType;
import com.bugsee.library.contracts.reporting.Report;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The operations the Dart report proxy performs on the SDK's {@link Report}
 * (workbook 7.3). Plain Java so every rule here is unit-tested without Flutter.
 *
 * <p>Whether the report is still live is not decided here: the caller looks the report
 * up through {@link ReportHandlerPipeline#reportFor}, which is null after the SDK's
 * completion ran (7.3.4). What this class owns is what the SDK would otherwise accept
 * silently and get wrong: a severity outside 1..5 ({@code IssueSeverity.fromIntValue}
 * maps it to {@code VeryLow}), an attribute value the backend cannot carry, a label that
 * is not a string.
 *
 * <p>Attachments and screenshots are NOT here (Phase 6, path-first: native does the
 * file work and no stream or bitmap crosses the bridge; workbook 7.3.3).
 */
final class ReportOps {

    /**
     * The severity range the SDKs accept: {@code IssueSeverity} 1..5 here and
     * {@code BugseeSeverityLevel} 1..5 on iOS. The same two numbers are repeated in Dart
     * ({@code ReportSeverity}) and Objective-C; {@code test/report_enum_parity_test.dart}
     * compares all three copies, and the JUnit test compares them to the SDK's enum.
     */
    static final int MIN_SEVERITY = 1;
    static final int MAX_SEVERITY = 5;

    /** An argument the SDK cannot take; nothing was applied. */
    static final class BadArgument extends Exception {
        BadArgument(@NonNull final String message) {
            super(message);
        }
    }

    /** What a read returns; plain, so the pigeon message is built where Flutter is available. */
    static final class Snapshot {
        @NonNull String id = "";
        @NonNull String type = "";
        @Nullable String summary;
        @Nullable String description;
        @Nullable String email;
        /** The SDK's internal value (1..5), never an ordinal. */
        @Nullable Integer severity;
        @NonNull List<String> labels = new ArrayList<>();
        @NonNull Map<String, Object> attributes = new LinkedHashMap<>();
    }

    private ReportOps() {
    }

    /** {@code toString()}, the wire name ({@code "crash"}); {@code name()} is "Crash". */
    @NonNull
    static String typeOf(@NonNull final Report report) {
        try {
            final IssueType type = report.getType();
            return type == null ? "" : type.toString();
        } catch (final Throwable t) {
            return "";
        }
    }

    @NonNull
    static Snapshot read(@NonNull final Report report) {
        final Snapshot s = new Snapshot();
        final String id = report.getId();
        s.id = id == null ? "" : id;
        s.type = typeOf(report);
        s.summary = report.getSummary();
        s.description = report.getDescription();
        s.email = report.getEmail();
        // By value, never ordinal(): Critical is ordinal 3 and value 4.
        final IssueSeverity severity = report.getSeverity();
        s.severity = severity == null ? null : severity.getValue();
        final List<String> labels = report.getLabels();
        if (labels != null) {
            for (final String label : labels) {
                if (label != null) {
                    s.labels.add(label);
                }
            }
        }
        final Map<String, Serializable> attributes = report.getAttributes();
        if (attributes != null) {
            for (final Map.Entry<String, Serializable> entry : attributes.entrySet()) {
                final Object value = entry.getValue();
                // Only what both SDKs accept, so a value another platform could not take is
                // not offered. Anything else has no Dart representation, and a toString would
                // read as a real value.
                if (entry.getKey() != null && isAllowedAttributeValue(value)) {
                    s.attributes.put(entry.getKey(), value);
                }
            }
        }
        return s;
    }

    /** The SDK's severity for the wire value; anything outside 1..5 is refused, not coerced. */
    @NonNull
    static IssueSeverity severity(final long wire) throws BadArgument {
        if (wire < MIN_SEVERITY || wire > MAX_SEVERITY) {
            // Never the value itself: a severity is app data, and a message may be logged.
            throw new BadArgument("severity must be an SDK severity value (1..5)");
        }
        return IssueSeverity.fromIntValue((int) wire);
    }

    static void setSeverity(@NonNull final Report report, final long wire) throws BadArgument {
        report.setSeverity(severity(wire));
    }

    /**
     * Strings only. A null or non-string element is refused as a whole, so a list that is
     * partly valid changes nothing.
     */
    @NonNull
    static ArrayList<String> labels(@Nullable final List<?> wire) throws BadArgument {
        if (wire == null) {
            throw new BadArgument("labels must be a list of strings");
        }
        final ArrayList<String> result = new ArrayList<>(wire.size());
        for (final Object item : wire) {
            if (!(item instanceof String)) {
                throw new BadArgument("labels must be a list of strings");
            }
            result.add((String) item);
        }
        return result;
    }

    /** One call: clear-then-add would expose a label-less report between the two. */
    static void replaceLabels(@NonNull final Report report, @Nullable final List<?> wire)
            throws BadArgument {
        report.setLabels(labels(wire));
    }

    static void addLabels(@NonNull final Report report, @Nullable final List<?> wire)
            throws BadArgument {
        report.addLabels(labels(wire));
    }

    /**
     * The value types both SDKs take: String, Boolean and a finite number (Android also
     * takes {@code Set<String>}, iOS does not, so it is not offered).
     */
    static boolean isAllowedAttributeValue(@Nullable final Object value) {
        if (value instanceof String || value instanceof Boolean) {
            return true;
        }
        if (value instanceof Integer || value instanceof Long
                || value instanceof Short || value instanceof Byte) {
            return true;
        }
        if (value instanceof Double || value instanceof Float) {
            final double d = ((Number) value).doubleValue();
            return !Double.isNaN(d) && !Double.isInfinite(d);
        }
        return false;
    }

    static void setAttribute(
            @NonNull final Report report,
            @Nullable final String name,
            @Nullable final Object value
    ) throws BadArgument {
        if (name == null || name.isEmpty()) {
            throw new BadArgument("an attribute needs a non-empty name");
        }
        if (!isAllowedAttributeValue(value)) {
            throw new BadArgument(
                    "an attribute value must be a string, a bool or a finite number");
        }
        report.setAttribute(name, (Serializable) value);
    }
}
