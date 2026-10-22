package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.reporting.Attachment;
import com.bugsee.library.contracts.reporting.Report;

import java.io.Serializable;
import java.util.AbstractMap;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * What the Dart {@code CreatedReport} does to the SDK's {@link Report} that
 * {@code Bugsee.createReport} handed out (Phase 6). The file operations are {@link ReportOps}'s (the
 * same {@code Report} contract); this adds the read and the whole-patch edit, as plain Java for JUnit.
 */
final class CreatedReportOps {

    private CreatedReportOps() {
    }

    /** What a read returns. */
    static final class Snapshot {
        @NonNull String id = "";
        @NonNull String type = "";
        @Nullable String summary;
        @Nullable String description;
        @Nullable Integer severity;
        @NonNull List<String> labels = new ArrayList<>();
        @NonNull Map<String, Object> attributes = new LinkedHashMap<>();
        @NonNull List<String> attachmentNames = new ArrayList<>();
        @NonNull List<Integer> screenshotDisplayIds = new ArrayList<>();
    }

    /** The edits of one {@code createdReportApply}; a {@code set*} flag makes a null a clear. */
    static final class Patch {
        boolean setSummary;
        @Nullable String summary;
        boolean setDescription;
        @Nullable String description;
        @Nullable Long severity;
        @Nullable List<?> labels;
        boolean clearAttributes;
        @Nullable Map<?, ?> attributes;
        @Nullable List<?> removeAttributes;
    }

    @NonNull
    static Snapshot read(@NonNull final Report report) {
        final ReportOps.Snapshot full = ReportOps.read(report);
        final Snapshot s = new Snapshot();
        s.id = full.id;
        s.type = full.type;
        s.summary = full.summary;
        s.description = full.description;
        s.severity = full.severity;
        s.labels = full.labels;
        s.attributes = full.attributes;
        for (final String[] attachment : full.attachments) {
            if (attachment[0] != null) {
                s.attachmentNames.add(attachment[0]);
            }
        }
        for (final int[] shot : full.screenshots) {
            s.screenshotDisplayIds.add(shot[0]);
        }
        return s;
    }

    /**
     * Validates every field FIRST, then applies: a patch with one bad field changes nothing. Order of
     * application: the scalar fields, the labels, clear attributes, set attributes, remove attributes.
     */
    static void apply(@NonNull final Report report, @NonNull final Patch patch)
            throws ReportOps.BadArgument {
        final IssueSeverity severity = patch.severity == null ? null : ReportOps.severity(patch.severity);
        final ArrayList<String> labels = patch.labels == null ? null : ReportOps.labels(patch.labels);
        final List<String> removals = new ArrayList<>();
        if (patch.removeAttributes != null) {
            for (final Object name : patch.removeAttributes) {
                if (!(name instanceof String) || ((String) name).isEmpty()) {
                    throw new ReportOps.BadArgument("an attribute needs a non-empty name");
                }
                removals.add((String) name);
            }
        }
        final List<Map.Entry<String, Serializable>> sets = new ArrayList<>();
        if (patch.attributes != null) {
            for (final Map.Entry<?, ?> entry : patch.attributes.entrySet()) {
                final Object key = entry.getKey();
                final Object value = entry.getValue();
                if (!(key instanceof String) || ((String) key).isEmpty()) {
                    throw new ReportOps.BadArgument("an attribute needs a non-empty name");
                }
                if (!ReportOps.isAllowedAttributeValue(value)) {
                    throw new ReportOps.BadArgument(
                            "an attribute value must be a string, a bool or a finite number");
                }
                sets.add(new AbstractMap.SimpleEntry<>((String) key, (Serializable) value));
            }
        }

        if (patch.setSummary) {
            report.setSummary(patch.summary);
        }
        if (patch.setDescription) {
            report.setDescription(patch.description);
        }
        if (severity != null) {
            report.setSeverity(severity);
        }
        if (labels != null) {
            report.setLabels(labels);
        }
        if (patch.clearAttributes) {
            report.clearAllAttributes();
        }
        for (final Map.Entry<String, Serializable> set : sets) {
            report.setAttribute(set.getKey(), set.getValue());
        }
        for (final String name : removals) {
            report.removeAttribute(name);
        }
    }

    /** Releases a created report that will not be sent: deletes the files the app added to it. */
    static void discard(@Nullable final Report report) {
        if (report == null) {
            return;
        }
        try {
            report.clearAttachments();
        } catch (final Throwable ignored) {
            // Best effort: nothing here may throw into a timer or a channel reply.
        }
    }
}
