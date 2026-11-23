package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/**
 * Dart errors with a fake SDK behind the seam: which SDK call a handled and an unhandled error make,
 * with what (the carrier's name and message), and what does not reach the SDK. The real SDK's
 * behaviour (v7.4.2 {@code BugseeInternal}) is noted in doc/exceptions.md.
 */
public class ExceptionOpsTest {

    private static final String DOC = "{\"internalType\":\"FlutterManagedException\",\"name\":\"StateError\"}";

    private static final class FakeSdk implements ExceptionOps.Sdk {
        final List<String> calls = new ArrayList<>();
        boolean running = true;
        RuntimeException throwsOn;
        Throwable thrown;
        String domain;
        int skipFrames = -1;
        Map<String, Object> options;

        @Override
        public boolean isLaunchedOrLaunching() {
            return running;
        }

        @Override
        public void logException(Throwable throwable, String domain, int skipFrames) {
            calls.add("logException");
            this.thrown = throwable;
            this.domain = domain;
            this.skipFrames = skipFrames;
            if (throwsOn != null) {
                throw throwsOn;
            }
        }

        @Override
        public void logUnhandledException(Throwable throwable, Map<String, Object> options) {
            calls.add("logUnhandledException");
            this.thrown = throwable;
            this.options = options;
            if (throwsOn != null) {
                throw throwsOn;
            }
        }
    }

    private static FacadeOps.Failure failure(final FakeSdk sdk, final String payload, final boolean handled,
            final String domain) {
        try {
            ExceptionOps.log(sdk, payload, handled, domain);
        } catch (final FacadeOps.Failure f) {
            return f;
        }
        fail("expected a failure");
        return null;
    }

    @Test
    public void handledGoesToLogExceptionWithTheDocumentAsTheCarriersMessage() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        assertTrue(ExceptionOps.log(sdk, DOC, true, "checkout"));
        assertEquals(Collections.singletonList("logException"), sdk.calls);
        // The backend routes on the class NAME and reads the JSON out of the message.
        assertEquals("com.bugsee.flutter.FlutterManagedException", sdk.thrown.getClass().getName());
        assertEquals(DOC, sdk.thrown.getMessage());
        assertEquals("checkout", sdk.domain);
        // The Java stack is the carrier's, not the app's: nothing to skip.
        assertEquals(0, sdk.skipFrames);
    }

    @Test
    public void unhandledGoesToLogUnhandledExceptionAndNeverToLogException() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        assertTrue(ExceptionOps.log(sdk, DOC, false, null));
        assertEquals(Collections.singletonList("logUnhandledException"), sdk.calls);
        assertEquals(DOC, sdk.thrown.getMessage());
        assertNull(sdk.options);
    }

    @Test
    public void unhandledCarriesTheDomainInTheOptionsMap() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        ExceptionOps.log(sdk, DOC, false, "checkout");
        assertEquals(1, sdk.options.size());
        assertEquals("checkout", sdk.options.get("domain"));
    }

    @Test
    public void notLaunchedIsNotHandedToTheSdkAndTheAnswerSaysSo() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        sdk.running = false;
        assertFalse(ExceptionOps.log(sdk, DOC, true, null));
        assertFalse(ExceptionOps.log(sdk, DOC, false, null));
        assertTrue(sdk.calls.isEmpty());
    }

    @Test
    public void anEmptyDocumentIsRefusedBeforeTheSdk() {
        final FakeSdk sdk = new FakeSdk();
        assertEquals(FacadeOps.INVALID_ARGUMENT, failure(sdk, "", true, null).code);
        assertEquals(FacadeOps.INVALID_ARGUMENT, failure(sdk, null, true, null).code);
        assertTrue(sdk.calls.isEmpty());
    }

    @Test
    public void theLimitOfTheDocumentIsInclusive() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        final StringBuilder atLimit = new StringBuilder();
        for (int i = 0; i < ExceptionOps.MAX_PAYLOAD_LENGTH; i++) {
            atLimit.append('a');
        }
        assertTrue(ExceptionOps.log(sdk, atLimit.toString(), true, null));
        assertEquals(FacadeOps.INVALID_ARGUMENT, failure(sdk, atLimit + "a", true, null).code);
        assertEquals(1, sdk.calls.size());
    }

    @Test
    public void aBadDomainIsRefusedBeforeTheSdk() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        assertEquals(FacadeOps.INVALID_ARGUMENT, failure(sdk, DOC, true, "").code);
        final StringBuilder longDomain = new StringBuilder();
        for (int i = 0; i <= ExceptionOps.MAX_DOMAIN_LENGTH; i++) {
            longDomain.append('d');
        }
        assertEquals(FacadeOps.INVALID_ARGUMENT, failure(sdk, DOC, false, longDomain.toString()).code);
        assertTrue(sdk.calls.isEmpty());
        longDomain.setLength(ExceptionOps.MAX_DOMAIN_LENGTH);
        assertTrue(ExceptionOps.log(sdk, DOC, true, longDomain.toString()));
    }

    @Test
    public void anSdkExceptionIsAFailureNamingOnlyItsClass() {
        final FakeSdk sdk = new FakeSdk();
        sdk.throwsOn = new IllegalStateException("carries " + DOC);
        final FacadeOps.Failure f = failure(sdk, DOC, false, null);
        assertEquals(FacadeOps.SDK_ERROR, f.code);
        assertFalse(f.getMessage().contains("internalType"));
        assertTrue(f.getMessage().contains("java.lang.IllegalStateException"));
        assertSame(sdk.throwsOn, f.getCause());
    }

    @Test
    public void unicodeAndLargeStackDocumentsPassUntouched() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        final String doc = "{\"reason\":\"café 😀 \u0000 line\\nbreak\"}";
        ExceptionOps.log(sdk, doc, true, null);
        assertEquals(doc, sdk.thrown.getMessage());
    }
}
