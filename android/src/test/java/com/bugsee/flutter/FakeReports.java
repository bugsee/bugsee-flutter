package com.bugsee.flutter;

import android.graphics.Bitmap;

import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.IssueType;
import com.bugsee.library.contracts.reporting.Attachment;
import com.bugsee.library.contracts.reporting.Report;

import java.io.File;
import java.io.Serializable;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.TreeMap;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A {@link Report} built with {@link Proxy}: the interface has around forty methods, and a
 * hand-written fake would be mostly boilerplate that drifts every time the SDK adds one.
 *
 * <p>Records every method called by name, so a test can assert on HOW the report was changed
 * ({@code setLabels} rather than {@code clearLabels} + {@code addLabels}) and not only on the
 * end state. A method this fake does not model throws, so a test cannot pass through a call
 * the bridge was never meant to make (attachments, screenshots: Phase 6).
 */
final class FakeReports {

    private FakeReports() {
    }

    static final class State {
        String id = "report-1";
        /** When true, getId throws: an unreadable id. */
        boolean idThrows;
        IssueType type = IssueType.Bug;
        String summary;
        String description;
        String email;
        IssueSeverity severity = IssueSeverity.Medium;
        final List<String> labels = new ArrayList<>();
        final Map<String, Serializable> attributes = new LinkedHashMap<>();
        /** Runs before / after the summary is stored; lets a test widen or observe the window. */
        Runnable beforeSetSummary;
        Runnable onSummarySet;
        /** Every method called, by name, in order. */
        final List<String> calls = new ArrayList<>();

        // ---- Attachments and screenshots: a model of what the SDK does (v7.4.2) ----------------
        /** The attachments the report holds (Attachment proxies). */
        final List<Attachment> attachments = new ArrayList<>();
        /** What each add received: {File or byte[], name, mime, move}. */
        final List<Object[]> adds = new ArrayList<>();
        /** The SDK declines every add (null), as it does for a report that is no longer live. */
        boolean refuseAdds;
        /** Where the model SDK stores what it was given; null: it stores nothing. */
        File storage;
        /** displayId -> {Bitmap, Boolean annotated}, ascending like the SDK's. */
        final TreeMap<Integer, Object[]> screenshots = new TreeMap<>();

        /** Everything but getters. */
        List<String> mutations() {
            final List<String> result = new ArrayList<>();
            for (final String call : calls) {
                if (!call.startsWith("get")) {
                    result.add(call);
                }
            }
            return result;
        }
    }

    static Report create(final State state) {
        return (Report) Proxy.newProxyInstance(
                Report.class.getClassLoader(),
                new Class<?>[] {Report.class},
                (proxy, method, args) -> invoke(state, proxy, method, args));
    }

    private static Object addAttachment(final State s, final Object[] args) {
        // (File, name, mime, move) or (byte[], name, mime): the SDK's two overloads.
        final boolean file = args[0] instanceof File;
        s.adds.add(file
                ? new Object[] {args[0], args[1], args[2], args[3]}
                : new Object[] {args[0], args[1], args[2], Boolean.FALSE});
        if (s.refuseAdds) {
            return null;
        }
        try {
            if (s.storage != null) {
                final File target = new File(s.storage, "stored-" + s.attachments.size() + ".attachment.bgsfile");
                if (file) {
                    final File source = (File) args[0];
                    Files.copy(source.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING);
                    if ((Boolean) args[3]) {
                        // The SDK renames or copies-then-deletes; either way the source is consumed.
                        source.delete();
                    }
                } else {
                    Files.write(target.toPath(), (byte[]) args[0]);
                }
            }
        } catch (final java.io.IOException e) {
            return null;
        }
        final String name = (String) args[1];
        final String mime = (String) args[2];
        final String fileName = file ? ((File) args[0]).getName() : name;
        final Attachment attachment = (Attachment) Proxy.newProxyInstance(
                Attachment.class.getClassLoader(),
                new Class<?>[] {Attachment.class},
                (p, m, a) -> {
                    switch (m.getName()) {
                        case "getName":
                            return name;
                        case "getMimeType":
                            return mime;
                        case "getFileName":
                            return fileName;
                        case "hashCode":
                            return System.identityHashCode(p);
                        case "equals":
                            return p == a[0];
                        case "toString":
                            return "FakeAttachment(" + name + ")";
                        default:
                            throw new UnsupportedOperationException(m.getName());
                    }
                });
        s.attachments.add(attachment);
        return attachment;
    }

    @SuppressWarnings("unchecked")
    private static Object invoke(
            final State s, final Object proxy, final Method method, final Object[] args) {
        final String name = method.getName();
        switch (name) {
            case "hashCode":
                return System.identityHashCode(proxy);
            case "equals":
                return proxy == args[0];
            case "toString":
                return "FakeReport(" + s.id + ")";
            default:
                break;
        }
        s.calls.add(name);
        switch (name) {
            case "getId":
                if (s.idThrows) {
                    throw new IllegalStateException("id unreadable");
                }
                return s.id;
            case "getType":
                return s.type;
            case "getSummary":
                return s.summary;
            case "setSummary":
                if (s.beforeSetSummary != null) {
                    s.beforeSetSummary.run();
                }
                s.summary = (String) args[0];
                if (s.onSummarySet != null) {
                    s.onSummarySet.run();
                }
                return null;
            case "getDescription":
                return s.description;
            case "setDescription":
                s.description = (String) args[0];
                return null;
            case "getEmail":
                return s.email;
            case "setEmail":
                s.email = (String) args[0];
                return null;
            case "getSeverity":
                return s.severity;
            case "setSeverity":
                s.severity = (IssueSeverity) args[0];
                return null;
            case "getLabels":
                return Collections.unmodifiableList(new ArrayList<>(s.labels));
            case "setLabels":
                s.labels.clear();
                s.labels.addAll((List<String>) args[0]);
                return null;
            case "clearLabels":
                s.labels.clear();
                return null;
            case "addLabels":
                s.labels.addAll((List<String>) args[0]);
                return null;
            case "addLabel":
                s.labels.add((String) args[0]);
                return null;
            case "getAttributes":
                return Collections.unmodifiableMap(new LinkedHashMap<>(s.attributes));
            case "setAttribute":
                s.attributes.put((String) args[0], (Serializable) args[1]);
                return null;
            case "removeAttribute":
                s.attributes.remove((String) args[0]);
                return null;
            case "clearAllAttributes":
                s.attributes.clear();
                return null;
            case "getAttachments":
                return new ArrayList<>(s.attachments);
            case "addAttachment":
                return addAttachment(s, args);
            case "clearAttachments":
                s.attachments.clear();
                return null;
            case "getScreenshotDisplayIds":
                return new ArrayList<>(s.screenshots.keySet());
            case "isScreenshotAnnotated":
                return s.screenshots.containsKey((Integer) args[0])
                        && (Boolean) s.screenshots.get((Integer) args[0])[1];
            case "setScreenshot":
                // setScreenshot(int, Bitmap, boolean) is the one writer; null removes the display.
                if (args.length == 3) {
                    if (args[1] == null) {
                        s.screenshots.remove((Integer) args[0]);
                    } else {
                        s.screenshots.put((Integer) args[0], new Object[] {args[1], args[2]});
                    }
                    return null;
                }
                throw new UnsupportedOperationException("FakeReports models only the 3-argument setScreenshot");
            default:
                throw new UnsupportedOperationException("FakeReports does not model " + name);
        }
    }
}
