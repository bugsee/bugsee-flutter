package com.bugsee.flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import com.bugsee.library.contracts.exchange.Breadcrumb;
import com.bugsee.library.contracts.options.IssueSeverity;
import com.bugsee.library.contracts.options.LogLevel;

import org.junit.Test;

import java.io.Serializable;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The facade operations with a fake SDK behind the seam: what reaches the SDK, what does not, what
 * Dart is told. The real SDK's behaviour per method (v7.4.2 {@code BugseeInternal}) is noted at each
 * test and in docs/api-surface.md.
 */
public class FacadeOpsTest {

    /** Records every call; stores attributes the way the SDK does (a double as a 32-bit float). */
    private static final class FakeSdk implements FacadeOps.Sdk {
        final List<String> calls = new ArrayList<>();
        final Map<String, Serializable> attributes = new LinkedHashMap<>();
        /** Mimics the SDK's silent drop of an over-limit string. */
        int dropStringsLongerThan = Integer.MAX_VALUE;
        RuntimeException throwsOn;
        String userIdentifier;
        String lastTraceName;
        Object lastTraceValue;
        String lastEventName;
        LinkedHashMap<String, Object> lastEventParams;
        LogLevel lastLevel;
        String lastLogMessage;
        String[] lastNotify;
        IssueSeverity lastNotifySeverity;
        LinkedHashMap<String, String> lastNotifyFields;
        boolean lastNotifyUrgent;
        boolean crumbAccepted = true;
        Breadcrumb.Level lastCrumbLevel;
        Map<String, Object> lastCrumbData;
        boolean blackout;
        IssueSeverity lastSeverity;
        List<String> lastLabels;
        String[] lastReport;

        private void record(String call) {
            calls.add(call);
            if (throwsOn != null) {
                throw throwsOn;
            }
        }

        @Override
        public void setAttribute(String name, Serializable value) {
            record("setAttribute");
            if (value instanceof String && ((String) value).length() > dropStringsLongerThan) {
                return; // the SDK's put() returns false and Bugsee.setAttribute is void
            }
            attributes.put(name, value instanceof Double ? (Serializable) Float.valueOf((float) (double) (Double) value) : value);
        }

        @Override
        public Object getAttribute(String name) {
            record("getAttribute");
            return attributes.get(name);
        }

        @Override
        public Map<String, ? extends Serializable> getAllAttributes() {
            record("getAllAttributes");
            return attributes.isEmpty() ? null : attributes;
        }

        @Override
        public void clearAttribute(String name) {
            record("clearAttribute");
            attributes.remove(name);
        }

        @Override
        public void clearAllAttributes() {
            record("clearAllAttributes");
            attributes.clear();
        }

        @Override
        public void setUserIdentifier(String identifier) {
            record("setUserIdentifier");
            userIdentifier = identifier;
        }

        @Override
        public String getUserIdentifier() {
            record("getUserIdentifier");
            return userIdentifier;
        }

        @Override
        public void clearUserIdentifier() {
            record("clearUserIdentifier");
            userIdentifier = null;
        }

        @Override
        public void trace(String name, Object value) {
            record("trace");
            lastTraceName = name;
            lastTraceValue = value;
        }

        @Override
        public void event(String name, LinkedHashMap<String, Object> params) {
            record("event");
            lastEventName = name;
            lastEventParams = params;
        }

        @Override
        public void log(String message, LogLevel level) {
            record("log");
            lastLogMessage = message;
            lastLevel = level;
        }

        @Override
        public void notifyRelay(String title, String body, IssueSeverity severity,
                LinkedHashMap<String, String> fields, boolean urgent) {
            record("notify");
            lastNotify = new String[] {title, body};
            lastNotifySeverity = severity;
            lastNotifyFields = fields;
            lastNotifyUrgent = urgent;
        }

        @Override
        public boolean addBreadcrumb(String category, Breadcrumb.Level level, String message,
                String type, Map<String, Object> data) {
            record("addBreadcrumb");
            lastCrumbLevel = level;
            lastCrumbData = data;
            return crumbAccepted;
        }

        @Override
        public void startBlackout() {
            record("startBlackout");
            blackout = true;
        }

        @Override
        public void endBlackout() {
            record("endBlackout");
            blackout = false;
        }

        @Override
        public boolean isBlackout() {
            record("isBlackout");
            return blackout;
        }

        @Override
        public void showReportDialog(String summary, String description, IssueSeverity severity,
                ArrayList<String> labels) {
            record("showReportDialog");
            lastReport = new String[] {summary, description};
            lastSeverity = severity;
            lastLabels = labels;
        }

        @Override
        public void upload(String summary, String description, IssueSeverity severity,
                List<String> labels) {
            record("upload");
            lastReport = new String[] {summary, description};
            lastSeverity = severity;
            lastLabels = labels;
        }
    }

    private static void assertInvalid(FacadeCall call, FakeSdk sdk) {
        try {
            call.run();
            fail("expected an invalid-argument failure");
        } catch (final FacadeOps.Failure f) {
            assertEquals(FacadeOps.INVALID_ARGUMENT, f.code);
        }
        // Whatever was refused did not reach the SDK.
        assertTrue(sdk.calls.toString(), sdk.calls.isEmpty());
    }

    private interface FacadeCall {
        void run() throws FacadeOps.Failure;
    }

    // ---- attributes ---------------------------------------------------------------------------

    @Test
    public void everyAcceptedAttributeTypeIsStoredAndReadBack() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        FacadeOps.setAttribute(sdk, "s", "text");
        FacadeOps.setAttribute(sdk, "b", true);
        FacadeOps.setAttribute(sdk, "i", 7);
        FacadeOps.setAttribute(sdk, "l", 1L << 40);
        FacadeOps.setAttribute(sdk, "d", 0.1);
        assertEquals("text", FacadeOps.getAttribute(sdk, "s"));
        assertEquals(Boolean.TRUE, FacadeOps.getAttribute(sdk, "b"));
        assertEquals(7, FacadeOps.getAttribute(sdk, "i"));
        assertEquals(1L << 40, FacadeOps.getAttribute(sdk, "l"));
        // Android keeps 0.1 as a float; it is read back as the decimal that names the float, not as
        // 0.10000000149011612.
        assertEquals(0.1, (Double) FacadeOps.getAttribute(sdk, "d"), 0.0);
    }

    @Test
    public void anAttributeTheSdkDroppedIsRejectedAndTheOldValueStays() throws Exception {
        // SDK source: BugseeAttributes.put returns false for a string over 1024 UTF-16 units and
        // Bugsee.setAttribute is void, so the read-back is the only signal.
        final FakeSdk sdk = new FakeSdk();
        sdk.dropStringsLongerThan = 3;
        FacadeOps.setAttribute(sdk, "k", "abc");
        try {
            FacadeOps.setAttribute(sdk, "k", "abcd");
            fail("expected a rejection");
        } catch (final FacadeOps.Failure f) {
            assertEquals(FacadeOps.ATTRIBUTE_REJECTED, f.code);
            assertFalse("never the value", f.getMessage().contains("abcd"));
        }
        assertEquals("abc", FacadeOps.getAttribute(sdk, "k"));
    }

    @Test
    public void aStringOverTheAndroidLimitNeverReachesTheSdk() {
        final FakeSdk sdk = new FakeSdk();
        char[] ok = new char[FacadeOps.ATTRIBUTE_STRING_MAX_LENGTH];
        Arrays.fill(ok, 'x');
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "k", new String(ok) + "x"), sdk);
    }

    @Test
    public void theLimitItselfIsAccepted() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        final char[] ok = new char[FacadeOps.ATTRIBUTE_STRING_MAX_LENGTH];
        Arrays.fill(ok, 'x');
        FacadeOps.setAttribute(sdk, "k", new String(ok));
        assertEquals(1024, ((String) sdk.attributes.get("k")).length());
    }

    @Test
    public void badAttributeNamesAndValuesNeverReachTheSdk() {
        final FakeSdk sdk = new FakeSdk();
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "", "v"), sdk);
        assertInvalid(() -> FacadeOps.setAttribute(sdk, null, "v"), sdk);
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "k", null), sdk);
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "k", Double.NaN), sdk);
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "k", Double.POSITIVE_INFINITY), sdk);
        // The SDK refuses a double at or above Float.MAX_VALUE, silently.
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "k", (double) Float.MAX_VALUE), sdk);
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "k", new ArrayList<String>()), sdk);
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "k", new HashSet<String>()), sdk);
        assertInvalid(() -> FacadeOps.setAttribute(sdk, "k", Float.valueOf(1f)), sdk);
        assertInvalid(() -> FacadeOps.getAttribute(sdk, ""), sdk);
        assertInvalid(() -> FacadeOps.clearAttribute(sdk, ""), sdk);
    }

    @Test
    public void aStoredSetOfStringsIsReadAsASortedList() {
        // Insertion order c, b, a: only an actual sort gives a, b, c.
        final Set<String> set = new java.util.LinkedHashSet<>(Arrays.asList("c", "b", "a"));
        assertEquals(Arrays.asList("a", "b", "c"), FacadeOps.toDartValue(set));
        assertNull(FacadeOps.toDartValue(new HashSet<>(Arrays.asList("a", 1))));
    }

    @Test
    public void aValueDartCannotRepresentReadsAsAbsentNotAsAString() {
        assertNull(FacadeOps.toDartValue(new Object()));
        assertNull(FacadeOps.toDartValue(Float.NaN));
        assertNull(FacadeOps.toDartValue(null));
        // A float is the shortest decimal that names it, not the widened binary value.
        assertEquals(0.1, (Double) FacadeOps.toDartValue(0.1f), 0.0);
        assertEquals(3.0, (Double) FacadeOps.toDartValue(3.0f), 0.0);
    }

    @Test
    public void aSingleAttributeDartCannotHoldReadsAsAbsent() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        sdk.attributes.put("when", new java.util.Date());
        assertNull(FacadeOps.getAttribute(sdk, "when"));
    }

    @Test
    public void getAllAttributesIsEmptyWhenTheSdkSaysNullAndSkipsWhatDartCannotHold() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        assertEquals(Collections.emptyMap(), FacadeOps.getAllAttributes(sdk));
        sdk.attributes.put("a", "x");
        sdk.attributes.put("f", 2.5f);
        final HashSet<String> set = new HashSet<>(Arrays.asList("z", "y"));
        sdk.attributes.put("set", (Serializable) set);
        final Map<String, Object> all = FacadeOps.getAllAttributes(sdk);
        assertEquals("x", all.get("a"));
        assertEquals(2.5, (Double) all.get("f"), 0.0);
        assertEquals(Arrays.asList("y", "z"), all.get("set"));
    }

    @Test
    public void clearAttributeAndClearAllReachTheSdk() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        FacadeOps.setAttribute(sdk, "a", "1");
        FacadeOps.clearAttribute(sdk, "a");
        assertNull(FacadeOps.getAttribute(sdk, "a"));
        FacadeOps.setAttribute(sdk, "b", "1");
        FacadeOps.clearAllAttributes(sdk);
        assertTrue(sdk.attributes.isEmpty());
    }

    @Test
    public void anSdkExceptionIsAFailureNeverAnEscapedException() {
        final FakeSdk sdk = new FakeSdk();
        sdk.throwsOn = new IllegalStateException("secret user data");
        try {
            FacadeOps.setAttribute(sdk, "k", "v");
            fail();
        } catch (final FacadeOps.Failure f) {
            assertEquals(FacadeOps.SDK_ERROR, f.code);
            // The class, never the message (it may carry user data).
            assertFalse(f.getMessage().contains("secret"));
            assertTrue(f.getMessage().contains("IllegalStateException"));
        }
    }

    // ---- user identifier ----------------------------------------------------------------------

    @Test
    public void anEmptyOrNullIdentifierClearsInsteadOfStoringAnEmptyString() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        FacadeOps.setUserIdentifier(sdk, "u1");
        assertEquals("u1", FacadeOps.getUserIdentifier(sdk));
        FacadeOps.setUserIdentifier(sdk, "");
        assertEquals("clear, not set(\"\")", "clearUserIdentifier", sdk.calls.get(sdk.calls.size() - 1));
        assertNull(FacadeOps.getUserIdentifier(sdk));
        FacadeOps.setUserIdentifier(sdk, "u2");
        FacadeOps.setUserIdentifier(sdk, null);
        assertNull(FacadeOps.getUserIdentifier(sdk));
    }

    @Test
    public void anEmptyStoredIdentifierReadsAsNone() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        sdk.userIdentifier = "";
        assertNull(FacadeOps.getUserIdentifier(sdk));
    }

    // ---- events, traces, logs -----------------------------------------------------------------

    @Test
    public void aTraceCarriesItsTypeToTheSdk() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        FacadeOps.trace(sdk, "t", "s");
        assertEquals("s", sdk.lastTraceValue);
        FacadeOps.trace(sdk, "t", true);
        assertEquals(Boolean.TRUE, sdk.lastTraceValue);
        FacadeOps.trace(sdk, "t", 5);
        assertEquals(5, sdk.lastTraceValue);
        FacadeOps.trace(sdk, "t", 1.5);
        assertEquals(1.5, sdk.lastTraceValue);
        assertEquals("t", sdk.lastTraceName);
    }

    @Test
    public void badTracesNeverReachTheSdk() {
        final FakeSdk sdk = new FakeSdk();
        assertInvalid(() -> FacadeOps.trace(sdk, "", 1), sdk);
        assertInvalid(() -> FacadeOps.trace(sdk, null, 1), sdk);
        assertInvalid(() -> FacadeOps.trace(sdk, "t", null), sdk);
        assertInvalid(() -> FacadeOps.trace(sdk, "t", new ArrayList<>()), sdk);
    }

    @Test
    public void anEventWithoutParamsUsesTheOneArgumentForm() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        FacadeOps.event(sdk, "e", null);
        assertEquals("e", sdk.lastEventName);
        assertNull(sdk.lastEventParams);
    }

    @Test
    public void eventParamsReachTheSdkAsAnOrderedMapKeepingNullsAndNesting() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        final Map<String, Object> inner = new HashMap<>();
        inner.put("zip", "12345");
        final Map<String, Object> params = new LinkedHashMap<>();
        params.put("b", 1);
        params.put("a", null);
        params.put("list", Arrays.asList(1, "x", null));
        params.put("map", inner);
        FacadeOps.event(sdk, "e", params);
        assertEquals(Arrays.asList("b", "a", "list", "map"), new ArrayList<>(sdk.lastEventParams.keySet()));
        assertTrue(sdk.lastEventParams.containsKey("a"));
        assertNull(sdk.lastEventParams.get("a"));
        assertSame(inner, sdk.lastEventParams.get("map"));
    }

    @Test
    public void badEventsNeverReachTheSdk() {
        final FakeSdk sdk = new FakeSdk();
        assertInvalid(() -> FacadeOps.event(sdk, "", null), sdk);
        assertInvalid(() -> FacadeOps.event(sdk, null, null), sdk);
        final Map<Object, Object> badKey = new HashMap<>();
        badKey.put(1, "x");
        assertInvalid(() -> FacadeOps.event(sdk, "e", badKey), sdk);
    }

    @Test
    public void logCrossesByTheSdksLevelValueNeverTheOrdinal() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        for (final LogLevel level : LogLevel.values()) {
            FacadeOps.log(sdk, "m", level.getValue());
            assertSame(level, sdk.lastLevel);
        }
        assertEquals("m", sdk.lastLogMessage);
    }

    @Test
    public void aLogLevelTheSdkDoesNotHaveIsRefused() {
        final FakeSdk sdk = new FakeSdk();
        for (final long bad : new long[] {0, -1, 6, 99, Long.MAX_VALUE, Long.MIN_VALUE}) {
            assertInvalid(() -> FacadeOps.log(sdk, "m", bad), sdk);
        }
        assertInvalid(() -> FacadeOps.log(sdk, null, 3), sdk);
    }

    // ---- breadcrumbs, notifications -----------------------------------------------------------

    @Test
    public void breadcrumbLevelNamesMapToTheSdksLevelsAndNothingElse() {
        assertSame(Breadcrumb.Level.DEBUG, FacadeOps.breadcrumbLevel("debug"));
        assertSame(Breadcrumb.Level.INFO, FacadeOps.breadcrumbLevel("info"));
        assertSame(Breadcrumb.Level.WARNING, FacadeOps.breadcrumbLevel("warning"));
        assertSame(Breadcrumb.Level.ERROR, FacadeOps.breadcrumbLevel("error"));
        assertSame(Breadcrumb.Level.FATAL, FacadeOps.breadcrumbLevel("fatal"));
        assertNull(FacadeOps.breadcrumbLevel("verbose"));
        assertNull(FacadeOps.breadcrumbLevel("2"));
        assertNull(FacadeOps.breadcrumbLevel(null));
        // The set of names is the SDK's set of levels: a new SDK level fails here.
        assertEquals(5, Breadcrumb.Level.values().length);
    }

    @Test
    public void aBreadcrumbReportsWhetherTheSdkTookIt() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        assertTrue(FacadeOps.addBreadcrumb(sdk, "nav", "warning", "m", "t", null));
        assertSame(Breadcrumb.Level.WARNING, sdk.lastCrumbLevel);
        assertNull("no data stays unset", sdk.lastCrumbData);
        sdk.crumbAccepted = false;
        assertFalse(FacadeOps.addBreadcrumb(sdk, "nav", "info", "m", "t", Collections.singletonMap("k", "v")));
        assertEquals("v", sdk.lastCrumbData.get("k"));
    }

    @Test
    public void badBreadcrumbsNeverReachTheSdk() {
        final FakeSdk sdk = new FakeSdk();
        assertInvalid(() -> FacadeOps.addBreadcrumb(sdk, "c", "loud", "m", "t", null), sdk);
        assertInvalid(() -> FacadeOps.addBreadcrumb(sdk, null, "info", "m", "t", null), sdk);
        assertInvalid(() -> FacadeOps.addBreadcrumb(sdk, "c", "info", null, "t", null), sdk);
        assertInvalid(() -> FacadeOps.addBreadcrumb(sdk, "c", "info", "m", null, null), sdk);
    }

    @Test
    public void aNotificationKeepsTheOrderOfItsFieldsAndMapsTheSeverityByValue() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        FacadeOps.relayNotification(sdk, "T", "B", 4L, Arrays.asList("z", "1", "a", "2"), true);
        assertEquals("T", sdk.lastNotify[0]);
        assertEquals("B", sdk.lastNotify[1]);
        assertSame(IssueSeverity.Critical, sdk.lastNotifySeverity);
        assertEquals(Arrays.asList("z", "a"), new ArrayList<>(sdk.lastNotifyFields.keySet()));
        assertTrue(sdk.lastNotifyUrgent);
        FacadeOps.relayNotification(sdk, "T", null, null, null, false);
        assertNull(sdk.lastNotifySeverity);
        assertNull(sdk.lastNotifyFields);
        assertFalse(sdk.lastNotifyUrgent);
    }

    @Test
    public void badNotificationsNeverReachTheSdk() {
        final FakeSdk sdk = new FakeSdk();
        assertInvalid(() -> FacadeOps.relayNotification(sdk, "", null, null, null, false), sdk);
        assertInvalid(() -> FacadeOps.relayNotification(sdk, "  ", null, null, null, false), sdk);
        assertInvalid(() -> FacadeOps.relayNotification(sdk, null, null, null, null, false), sdk);
        assertInvalid(() -> FacadeOps.relayNotification(sdk, "T", null, 0L, null, false), sdk);
        assertInvalid(() -> FacadeOps.relayNotification(sdk, "T", null, 6L, null, false), sdk);
        assertInvalid(() -> FacadeOps.relayNotification(sdk, "T", null, null, Arrays.asList("k"), false), sdk);
        assertInvalid(() -> FacadeOps.relayNotification(sdk, "T", null, null, Arrays.asList("k", 1), false), sdk);
    }

    // ---- blackout -----------------------------------------------------------------------------

    @Test
    public void blackoutIsPassedThroughAndReadBackFromTheSdk() throws Exception {
        // SDK source (BugseeInternal.startBlackout): a call before launch is HELD and applied at
        // launch; isBlackout reflects it. The wrapper adds nothing.
        final FakeSdk sdk = new FakeSdk();
        assertFalse(FacadeOps.isBlackout(sdk));
        FacadeOps.startBlackout(sdk);
        assertTrue(FacadeOps.isBlackout(sdk));
        FacadeOps.endBlackout(sdk);
        assertFalse(FacadeOps.isBlackout(sdk));
        assertEquals(Arrays.asList("isBlackout", "startBlackout", "isBlackout", "endBlackout", "isBlackout"), sdk.calls);
    }

    // ---- reports ------------------------------------------------------------------------------

    @Test
    public void uploadAndTheDialogMapSeverityByValueAndKeepUnsetAsNull() throws Exception {
        final FakeSdk sdk = new FakeSdk();
        FacadeOps.upload(sdk, "s", "d", 5L, Arrays.asList("x", "y"));
        assertSame(IssueSeverity.Blocker, sdk.lastSeverity);
        assertEquals(Arrays.asList("x", "y"), sdk.lastLabels);
        FacadeOps.upload(sdk, "s", "d", null, null);
        assertNull("null lets the SDK apply its default priority", sdk.lastSeverity);
        assertNull(sdk.lastLabels);
        FacadeOps.showReportDialog(sdk, null, null, null, null);
        assertNull(sdk.lastReport[0]);
        FacadeOps.showReportDialog(sdk, "s", "d", 1L, Arrays.asList("l"));
        assertSame(IssueSeverity.VeryLow, sdk.lastSeverity);
    }

    @Test
    public void badReportArgumentsNeverReachTheSdk() {
        final FakeSdk sdk = new FakeSdk();
        assertInvalid(() -> FacadeOps.upload(sdk, null, "d", null, null), sdk);
        assertInvalid(() -> FacadeOps.upload(sdk, "s", null, null, null), sdk);
        assertInvalid(() -> FacadeOps.upload(sdk, "s", "d", 0L, null), sdk);
        assertInvalid(() -> FacadeOps.upload(sdk, "s", "d", 6L, null), sdk);
        assertInvalid(() -> FacadeOps.upload(sdk, "s", "d", null, Arrays.asList("ok", 1)), sdk);
        assertInvalid(() -> FacadeOps.showReportDialog(sdk, "s", "d", 9L, null), sdk);
        assertInvalid(() -> FacadeOps.showReportDialog(sdk, "s", "d", null, Arrays.asList((Object) null)), sdk);
    }

    @Test
    public void everyPublicOperationTurnsAnSdkExceptionIntoAFailure() {
        final FakeSdk sdk = new FakeSdk();
        sdk.throwsOn = new IllegalStateException("boom");
        final FacadeCall[] all = {
            () -> FacadeOps.getAttribute(sdk, "k"),
            () -> FacadeOps.getAllAttributes(sdk),
            () -> FacadeOps.clearAttribute(sdk, "k"),
            () -> FacadeOps.clearAllAttributes(sdk),
            () -> FacadeOps.setUserIdentifier(sdk, "u"),
            () -> FacadeOps.getUserIdentifier(sdk),
            () -> FacadeOps.trace(sdk, "t", 1),
            () -> FacadeOps.event(sdk, "e", null),
            () -> FacadeOps.log(sdk, "m", 3),
            () -> FacadeOps.addBreadcrumb(sdk, "c", "info", "m", "t", null),
            () -> FacadeOps.relayNotification(sdk, "T", null, null, null, false),
            () -> FacadeOps.startBlackout(sdk),
            () -> FacadeOps.endBlackout(sdk),
            () -> FacadeOps.isBlackout(sdk),
            () -> FacadeOps.showReportDialog(sdk, null, null, null, null),
            () -> FacadeOps.upload(sdk, "s", "d", null, null),
        };
        for (final FacadeCall call : all) {
            try {
                call.run();
                fail("expected sdk-error");
            } catch (final FacadeOps.Failure f) {
                assertEquals(FacadeOps.SDK_ERROR, f.code);
            }
        }
    }
}
