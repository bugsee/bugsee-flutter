package com.bugsee.flutter;

import android.graphics.Bitmap;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.IssueType;
import com.bugsee.library.contracts.reporting.Attachment;
import com.bugsee.library.contracts.reporting.Report;

import java.io.File;
import java.io.Serializable;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

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
 * <p>Attachments and screenshots are path-first (workbook 7.3.3, report-contract): a PATH crosses,
 * never a stream or a bitmap, and the file work is the SDK's ({@code addAttachment(File, ...)}
 * copies or moves it into storage the report owns). What this class adds is what the SDK reports as a
 * bare {@code null}: it says WHY a file was refused (missing, not a file, unreadable, over the count
 * limit) before the SDK is asked, and it validates names, MIME types, sizes and image dimensions
 * (the SDK checks none of them). Every such operation may take as long as the disk does, so the
 * caller runs them off the platform thread ({@link ReportFileWorker}).
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

    /** The most bytes a bytes attachment may have; repeated in Dart ({@code maxAttachmentBytes}). */
    static final int MAX_ATTACHMENT_BYTES = 1024 * 1024;
    static final int MAX_ATTACHMENT_NAME_LENGTH = 255;
    static final int MAX_MIME_TYPE_LENGTH = 255;
    static final int MAX_PATH_LENGTH = 4096;
    /** The most pixels a screenshot image may have (4096 x 4096), about 64 MiB decoded. */
    static final long MAX_SCREENSHOT_PIXELS = 4096L * 4096L;
    /** {@code IssueReport.MAX_ATTACHMENTS} (v7.4.2): the SDK refuses the 1001st. */
    static final int MAX_REPORT_ATTACHMENTS = 1000;

    // The failure codes of a file operation's reply (Dart: ReportWire). Repeated in Objective-C.
    static final String NOT_LIVE = "not-live";
    static final String FILE_NOT_FOUND = "file-not-found";
    static final String NOT_A_FILE = "not-a-file";
    static final String UNREADABLE = "unreadable";
    static final String TOO_LARGE = "too-large";
    static final String LIMIT = "limit";
    static final String REJECTED = "rejected";
    static final String BUSY = "busy";
    static final String UNSUPPORTED = "unsupported";
    static final String IMAGE_UNDECODABLE = "image-undecodable";
    static final String IMAGE_TOO_LARGE = "image-too-large";

    /** A file, bytes or an image the SDK or the file system refused; nothing changed. */
    static final class Refused extends Exception {
        @NonNull final String code;

        Refused(@NonNull final String code) {
            super(code);
            this.code = code;
        }
    }

    /** Decodes an image file; the production one is {@code BitmapFactory}. */
    interface ImageDecoder {
        /**
         * @param maxPixels the most width x height the image may have: refuse before decoding
         * @throws Refused {@link #IMAGE_TOO_LARGE} or {@link #IMAGE_UNDECODABLE}
         */
        @NonNull
        Bitmap decode(@NonNull File file, long maxPixels) throws Refused;
    }

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
        @NonNull List<String[]> attachments = new ArrayList<>();
        /** {displayId, annotated (0/1)} ascending by display id. */
        @NonNull List<int[]> screenshots = new ArrayList<>();
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
        readFiles(report, s);
        return s;
    }

    /** The attachments' metadata and the screenshots' ids and flags; never content. */
    private static void readFiles(@NonNull final Report report, @NonNull final Snapshot s) {
        final List<Attachment> attachments = report.getAttachments();
        if (attachments != null) {
            for (final Attachment attachment : attachments) {
                if (attachment != null) {
                    // {name, mimeType, fileName}: each may be null.
                    s.attachments.add(new String[] {
                            attachment.getName(), attachment.getMimeType(), attachment.getFileName(null)});
                }
            }
        }
        final List<Integer> ids = report.getScreenshotDisplayIds();
        if (ids != null) {
            for (final Integer id : ids) {
                if (id != null) {
                    s.screenshots.add(new int[] {id, report.isScreenshotAnnotated(id) ? 1 : 0});
                }
            }
        }
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

    // ---- Attachments and screenshots (Phase 6) ------------------------------------------------------

    private static final Pattern MIME = Pattern.compile(
            "^[A-Za-z0-9][A-Za-z0-9!#$&^_.+\\-]{0,126}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+\\-]{0,126}$");

    private static boolean hasControl(@NonNull final String s) {
        for (int i = 0; i < s.length(); i++) {
            final char c = s.charAt(i);
            if (c < 0x20 || c == 0x7f) {
                return true;
            }
        }
        return false;
    }

    /** An absolute file system path: a URL, a relative path or a control character is refused. */
    @NonNull
    static File checkedPath(@Nullable final String path) throws BadArgument {
        if (path == null || path.isEmpty() || path.length() > MAX_PATH_LENGTH || hasControl(path)) {
            throw new BadArgument("a file path must be 1.." + MAX_PATH_LENGTH
                    + " characters without control characters");
        }
        if (path.matches("^[A-Za-z][A-Za-z0-9+.\\-]*:.*")) {
            throw new BadArgument("pass a file system path, not a URL such as file: or content:");
        }
        if (path.charAt(0) != '/') {
            throw new BadArgument("a file path must be absolute");
        }
        return new File(path);
    }

    @NonNull
    static String checkedName(@Nullable final String name) throws BadArgument {
        if (name == null || name.trim().isEmpty() || name.length() > MAX_ATTACHMENT_NAME_LENGTH
                || hasControl(name) || name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
            throw new BadArgument("an attachment name must be 1.." + MAX_ATTACHMENT_NAME_LENGTH
                    + " characters without control characters or a path separator");
        }
        return name;
    }

    @Nullable
    static String checkedMimeType(@Nullable final String mimeType) throws BadArgument {
        if (mimeType != null
                && (mimeType.length() > MAX_MIME_TYPE_LENGTH || !MIME.matcher(mimeType).matches())) {
            throw new BadArgument("a MIME type must look like type/subtype, without parameters");
        }
        return mimeType;
    }

    static int checkedDisplayId(final long displayId) throws BadArgument {
        if (displayId < 0 || displayId > Integer.MAX_VALUE) {
            throw new BadArgument("a display id must be between 0 and " + Integer.MAX_VALUE);
        }
        return (int) displayId;
    }

    /**
     * Says why a path cannot be attached, in the order a developer would fix it: nothing there, not
     * a regular file, not readable. A symbolic link is followed (the SDK copies its content).
     */
    private static void requireReadableFile(@NonNull final File file) throws Refused {
        try {
            if (!file.exists()) {
                throw new Refused(FILE_NOT_FOUND);
            }
            if (!file.isFile()) {
                throw new Refused(NOT_A_FILE);
            }
            if (!file.canRead()) {
                throw new Refused(UNREADABLE);
            }
        } catch (final SecurityException e) {
            throw new Refused(UNREADABLE);
        }
    }

    private static void requireRoomForAttachment(@NonNull final Report report) throws Refused {
        final List<Attachment> held = report.getAttachments();
        if (held != null && held.size() >= MAX_REPORT_ATTACHMENTS) {
            throw new Refused(LIMIT);
        }
    }

    /**
     * Copies ({@code move} false) or moves the file into the report. The SDK does the file work and
     * returns null for everything it declines (the report no longer takes attachments, a failed copy,
     * the cap); a refusal never consumes the source. The reasons the SDK does not name are checked
     * first, so the caller can tell a typo from a closed report.
     */
    static void addFile(
            @NonNull final Report report,
            @Nullable final String path,
            @Nullable final String name,
            @Nullable final String mimeType,
            final boolean move
    ) throws BadArgument, Refused {
        final File file = checkedPath(path);
        final String checkedName = checkedName(name);
        final String checkedMime = checkedMimeType(mimeType);
        requireReadableFile(file);
        requireRoomForAttachment(report);
        if (report.addAttachment(file, checkedName, checkedMime, move) == null) {
            throw new Refused(REJECTED);
        }
    }

    static void addBytes(
            @NonNull final Report report,
            @Nullable final byte[] data,
            @Nullable final String name,
            @Nullable final String mimeType
    ) throws BadArgument, Refused {
        final String checkedName = checkedName(name);
        final String checkedMime = checkedMimeType(mimeType);
        if (data == null) {
            throw new BadArgument("attachment data must not be null");
        }
        if (data.length > MAX_ATTACHMENT_BYTES) {
            throw new Refused(TOO_LARGE);
        }
        requireRoomForAttachment(report);
        if (report.addAttachment(data, checkedName, checkedMime) == null) {
            throw new Refused(REJECTED);
        }
    }

    /** The SDK deletes each attachment's backing file, not only its reference. */
    static void clearAttachments(@NonNull final Report report) {
        report.clearAttachments();
    }

    /**
     * Decodes the image at {@code path} and stores it as the screenshot of {@code displayId}. The
     * decoder refuses an image over {@link #MAX_SCREENSHOT_PIXELS} before it allocates it. The
     * bitmap is recycled afterwards (the SDK writes it to its own file before returning).
     */
    static void setScreenshot(
            @NonNull final Report report,
            @NonNull final ImageDecoder decoder,
            @Nullable final String path,
            final long displayId,
            final boolean annotated
    ) throws BadArgument, Refused {
        final File file = checkedPath(path);
        final int id = checkedDisplayId(displayId);
        requireReadableFile(file);
        final Bitmap bitmap = decoder.decode(file, MAX_SCREENSHOT_PIXELS);
        try {
            report.setScreenshot(id, bitmap, annotated);
        } finally {
            bitmap.recycle();
        }
    }

    /** A null bitmap removes the display's entry and its file (SDK 7.4.2: as iOS does). */
    static void removeScreenshot(@NonNull final Report report, final long displayId)
            throws BadArgument {
        report.setScreenshot(checkedDisplayId(displayId), null, false);
    }
}
