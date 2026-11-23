package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;

import org.json.JSONObject;
import org.junit.Test;

import java.io.File;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Map;

/**
 * The SDK's OWN signature code (v7.4.2 {@code BugseeExceptionProcessor.generateSignature}, by
 * reflection: the SDK is minified) fed with the carrier the plugin hands it. The SDK hashes the carrier's class name, the
 * {@code signature} key of the reason's JSON and the Java stack of the calling thread. The last is the
 * same for every Dart error, so without the document's {@code signature} every Dart error would have
 * ONE signature: the server matches issues on it before the worker looks at the document, drops what it
 * has too many of and tells the device to blacklist a signature for good.
 *
 * <p>The documents are {@code test/fixtures/exceptions/signature_cases.json}, which the Dart test of the
 * signature regenerates and compares: a1 and a2 are one error on two days, b another.
 */
public class ExceptionSignatureTest {

    private static Map<String, String> documents() throws Exception {
        final File file = new File(new File("").getAbsoluteFile().getParentFile(),
                "test/fixtures/exceptions/signature_cases.json");
        final JSONObject all = new JSONObject(new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8))
                .getJSONObject("documents");
        final Map<String, String> result = new java.util.LinkedHashMap<>();
        final java.util.Iterator<String> keys = all.keys();
        while (keys.hasNext()) {
            final String key = keys.next();
            result.put(key, all.getString(key));
        }
        return result;
    }

    /** The SDK's signature of the carrier for [document], as {@code Bugsee.logException} would compute it. */
    private static String sdkSignature(final String document, final boolean handled) throws Exception {
        // The shipped SDK is minified: ExceptionSignature is renamed, but its public front door,
        // BugseeExceptionProcessor.generateSignature (what createErrorReportAndUpload and
        // createCrashReportAndUpload call), keeps its name.
        final Class<?> type = Class.forName("com.bugsee.library.reporting.exceptions.BugseeExceptionProcessor");
        final Method generate = type.getMethod("generateSignature", Throwable.class, boolean.class, Map.class);
        final Object signature = generate.invoke(null, new FlutterManagedException(document), handled, null);
        assertNotNull("the SDK computed a signature", signature);
        return (String) signature;
    }

    /**
     * The SDK's signature of every document, all from the SAME line: the Java stack of the calling
     * thread is part of what the SDK hashes, so a call site per document would differ by line number.
     */
    private static Map<String, String> signatures(final Map<String, String> docs, final boolean handled,
            final boolean dropSignature) throws Exception {
        final Map<String, String> result = new java.util.LinkedHashMap<>();
        for (final Map.Entry<String, String> doc : docs.entrySet()) {
            final String document = dropSignature ? withoutSignature(doc.getValue()) : doc.getValue();
            result.put(doc.getKey(), sdkSignature(document, handled));
        }
        return result;
    }

    private static String withoutSignature(final String document) throws Exception {
        final JSONObject json = new JSONObject(document);
        json.remove("signature");
        return json.toString();
    }

    @Test
    public void equalErrorsShareTheSdkSignatureAndDifferentOnesDoNot() throws Exception {
        for (final boolean handled : new boolean[] {true, false}) {
            final Map<String, String> sig = signatures(documents(), handled, false);
            assertEquals("one error on two days is one signature", sig.get("a1"), sig.get("a2"));
            assertNotEquals("another error is another signature", sig.get("a1"), sig.get("b"));
        }
    }

    @Test
    public void withoutTheDocumentsSignatureEveryDartErrorWouldShareOne() throws Exception {
        // The failure this guards against: the carrier's name and the calling thread's stack are all
        // that is left, and they do not depend on the error.
        final Map<String, String> sig = signatures(documents(), false, true);
        assertEquals(sig.get("a1"), sig.get("b"));
        assertEquals(sig.get("a1"), sig.get("a2"));
    }

    @Test
    public void theDocumentsSignatureIsAStringKeyAtTheTopLevel() throws Exception {
        for (final String document : documents().values()) {
            // How the SDK reads it (extractFromReason): top level, a string, non-empty.
            final String signature = new JSONObject(document).optString("signature", "");
            org.junit.Assert.assertTrue(signature.matches("[0-9a-f]{40}"));
        }
    }
}
