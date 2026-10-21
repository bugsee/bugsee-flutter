package com.bugsee.flutter;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.graphics.Bitmap;

import com.bugsee.library.contracts.reporting.Attachment;
import com.bugsee.library.contracts.reporting.Report;

import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Path-first attachments and screenshots (workbook 7.3.3, report-contract): what is validated before
 * the SDK is asked, how a refusal is named, and that a refused add never consumes the caller's file.
 * The SDK's own file work is modelled by {@link FakeReports} (a copy or a rename into a storage
 * folder, deleting the source for a move); the real SDK is shown on a device by
 * {@code example/integration_test/attachments_test.dart}.
 */
public class ReportOpsFilesTest {

    @Rule public TemporaryFolder tmp = new TemporaryFolder();

    private final FakeReports.State state = new FakeReports.State();
    private final Report report = FakeReports.create(state);
    private File source;

    @Before
    public void setUp() throws Exception {
        state.storage = tmp.newFolder("storage");
        source = tmp.newFile("app.log");
        Files.write(source.toPath(), "hello".getBytes(StandardCharsets.UTF_8));
    }

    private static String refusalOf(final ThrowingRunnable r) {
        try {
            r.run();
        } catch (final ReportOps.Refused e) {
            return e.code;
        } catch (final Exception e) {
            fail("expected Refused, got " + e);
        }
        fail("expected Refused");
        return null;
    }

    private static void assertBad(final ThrowingRunnable r) {
        try {
            r.run();
        } catch (final ReportOps.BadArgument expected) {
            return;
        } catch (final Exception e) {
            fail("expected BadArgument, got " + e);
        }
        fail("expected BadArgument");
    }

    private interface ThrowingRunnable {
        void run() throws Exception;
    }

    // ---- the file path -------------------------------------------------------------------------

    @Test
    public void aCopyHandsTheSdkTheFileAndLeavesTheSourceAlone() throws Exception {
        ReportOps.addFile(report, source.getPath(), "Log", "text/plain", false);
        assertEquals(1, state.adds.size());
        final Object[] add = state.adds.get(0);
        assertEquals(source, add[0]);
        assertEquals("Log", add[1]);
        assertEquals("text/plain", add[2]);
        assertEquals(Boolean.FALSE, add[3]);
        assertTrue("a copy leaves the source", source.exists());
        assertEquals(1, state.attachments.size());
    }

    @Test
    public void aMoveIsPassedOnAndTheSdkConsumesTheSource() throws Exception {
        ReportOps.addFile(report, source.getPath(), "Log", null, true);
        assertEquals(Boolean.TRUE, state.adds.get(0)[3]);
        assertNull("no type is passed as null", state.adds.get(0)[2]);
        assertFalse("the move consumed the source", source.exists());
    }

    @Test
    public void aRefusedMoveDoesNotConsumeTheSource() throws Exception {
        state.refuseAdds = true;
        assertEquals(ReportOps.REJECTED, refusalOf(
                () -> ReportOps.addFile(report, source.getPath(), "Log", null, true)));
        assertTrue("the SDK declined: the source is untouched", source.exists());
        assertEquals("hello", new String(Files.readAllBytes(source.toPath()), StandardCharsets.UTF_8));
        assertEquals(0, state.attachments.size());
    }

    @Test
    public void everyKindOfBadPathIsRefusedBeforeTheSdkIsAsked() {
        final String longPath = "/" + new String(new char[ReportOps.MAX_PATH_LENGTH]).replace('\0', 'a');
        for (final String path : new String[] {
                null, "", "relative/a.txt", "a.txt", "file:///data/a.txt", "content://media/1",
                "http://x/y", "/data/a\u0000b", "/data/a\nb", longPath}) {
            assertBad(() -> ReportOps.addFile(report, path, "n", null, false));
        }
        assertEquals("nothing reached the SDK", 0, state.adds.size());
    }

    @Test
    public void everyKindOfBadNameAndTypeIsRefusedBeforeTheSdkIsAsked() {
        final String path = source.getPath();
        final String tooLong = new String(new char[ReportOps.MAX_ATTACHMENT_NAME_LENGTH + 1]).replace('\0', 'n');
        for (final String name : new String[] {null, "", "   ", "../x", "a/b", "a\\b", "a\nb", "a\u007fb", tooLong}) {
            assertBad(() -> ReportOps.addFile(report, path, name, null, false));
        }
        for (final String mime : new String[] {"", "text", "text/", "/plain", "text/plain; charset=utf-8",
                "te xt/plain", "text/pl/ain", "a/b\n"}) {
            assertBad(() -> ReportOps.addFile(report, path, "n", mime, false));
        }
        assertEquals(0, state.adds.size());
    }

    @Test
    public void goodNamesAndTypesAreAccepted() throws Exception {
        final String path = source.getPath();
        ReportOps.addFile(report, path, "My log (1).txt", "application/vnd.api+json", false);
        ReportOps.addFile(report, path, "é日本", "image/svg+xml", false);
        ReportOps.addFile(report, path,
                new String(new char[ReportOps.MAX_ATTACHMENT_NAME_LENGTH]).replace('\0', 'n'), null, false);
        assertEquals(3, state.adds.size());
    }

    @Test
    public void aMissingFileIsNamedAndNothingIsAdded() {
        assertEquals(ReportOps.FILE_NOT_FOUND, refusalOf(() -> ReportOps.addFile(
                report, new File(tmp.getRoot(), "nope.txt").getPath(), "n", null, true)));
        assertEquals(0, state.adds.size());
    }

    @Test
    public void aDirectoryIsNotAFile() throws Exception {
        assertEquals(ReportOps.NOT_A_FILE, refusalOf(() -> ReportOps.addFile(
                report, tmp.newFolder("dir").getPath(), "n", null, true)));
        assertEquals(0, state.adds.size());
    }

    @Test
    public void anUnreadableFileIsNamedAndNotConsumed() throws Exception {
        final File secret = tmp.newFile("secret.txt");
        if (!secret.setReadable(false, false) || secret.canRead()) {
            // Running as root: permissions do not bind, nothing to show.
            org.junit.Assume.assumeTrue("file permissions do not apply to this user", false);
        }
        assertEquals(ReportOps.UNREADABLE, refusalOf(() -> ReportOps.addFile(
                report, secret.getPath(), "n", null, true)));
        assertTrue(secret.exists());
        assertEquals(0, state.adds.size());
    }

    @Test
    public void aSymbolicLinkToAFileIsFollowedAndAMoveOfALinkIsThePassedThrough() throws Exception {
        final File link = new File(tmp.getRoot(), "link.log");
        Files.createSymbolicLink(link.toPath(), source.toPath());
        ReportOps.addFile(report, link.getPath(), "via link", null, false);
        assertEquals(link, state.adds.get(0)[0]);
        assertTrue("the target is untouched", source.exists());
    }

    @Test
    public void aDanglingLinkIsMissingNotAFile() throws Exception {
        final File dangling = new File(tmp.getRoot(), "dangling");
        Files.createSymbolicLink(dangling.toPath(), new File(tmp.getRoot(), "gone").toPath());
        assertEquals(ReportOps.FILE_NOT_FOUND, refusalOf(() -> ReportOps.addFile(
                report, dangling.getPath(), "n", null, true)));
    }

    @Test
    public void theSdksAttachmentCountIsNamedBeforeItsBareNull() throws Exception {
        for (int i = 0; i < ReportOps.MAX_REPORT_ATTACHMENTS; i++) {
            ReportOps.addBytes(report, new byte[0], "n" + i, null);
        }
        assertEquals(ReportOps.MAX_REPORT_ATTACHMENTS, state.attachments.size());
        final int before = state.adds.size();
        assertEquals(ReportOps.LIMIT, refusalOf(() -> ReportOps.addFile(
                report, source.getPath(), "n", null, true)));
        assertEquals(ReportOps.LIMIT, refusalOf(() -> ReportOps.addBytes(report, new byte[1], "n", null)));
        assertEquals("the SDK was not asked", before, state.adds.size());
        assertTrue("and the source is untouched", source.exists());
    }

    @Test
    public void theLimitIsTheSdksOwn() {
        assertEquals(1000, ReportOps.MAX_REPORT_ATTACHMENTS);
    }

    // ---- bytes ---------------------------------------------------------------------------------------

    @Test
    public void bytesAreHandedOverUpToTheCapAndEmptyIsValid() throws Exception {
        ReportOps.addBytes(report, new byte[] {1, 2, 3}, "raw.bin", "application/octet-stream");
        ReportOps.addBytes(report, new byte[0], "empty", null);
        ReportOps.addBytes(report, new byte[ReportOps.MAX_ATTACHMENT_BYTES], "max", null);
        assertArrayEquals(new byte[] {1, 2, 3}, (byte[]) state.adds.get(0)[0]);
        assertEquals(3, state.attachments.size());
        assertEquals("raw.bin", state.attachments.get(0).getFileName(null));
    }

    @Test
    public void oneByteOverTheCapIsTooLargeAndNeverReachesTheSdk() {
        assertEquals(ReportOps.TOO_LARGE, refusalOf(() -> ReportOps.addBytes(
                report, new byte[ReportOps.MAX_ATTACHMENT_BYTES + 1], "big", null)));
        assertEquals(0, state.adds.size());
    }

    @Test
    public void nullBytesAreAnArgumentErrorAndABadNameIsToo() {
        assertBad(() -> ReportOps.addBytes(report, null, "n", null));
        assertBad(() -> ReportOps.addBytes(report, new byte[1], "../n", null));
        assertBad(() -> ReportOps.addBytes(report, new byte[1], "n", "bad"));
        assertEquals(0, state.adds.size());
    }

    @Test
    public void aDeclinedByteAddIsRejected() {
        state.refuseAdds = true;
        assertEquals(ReportOps.REJECTED, refusalOf(() -> ReportOps.addBytes(report, new byte[1], "n", null)));
    }

    @Test
    public void clearAttachmentsReachesTheSdk() throws Exception {
        ReportOps.addBytes(report, new byte[1], "n", null);
        ReportOps.clearAttachments(report);
        assertTrue(state.calls.contains("clearAttachments"));
        assertEquals(0, state.attachments.size());
    }

    // ---- screenshots ---------------------------------------------------------------------------------

    /** A Bitmap cannot be built off a device: the platform stub has no constructor to call. */
    private static Bitmap bitmap() throws Exception {
        // Reflection: android.jar, which this test compiles against, does not declare sun.misc.
        final Class<?> unsafe = Class.forName("sun.misc.Unsafe");
        final Field f = unsafe.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        return (Bitmap) unsafe.getMethod("allocateInstance", Class.class).invoke(f.get(null), Bitmap.class);
    }

    private static final class Decoder implements ReportOps.ImageDecoder {
        final List<Object[]> calls = new ArrayList<>();
        ReportOps.Refused refuse;
        Bitmap result;

        @Override
        public Bitmap decode(final File file, final long maxPixels) throws ReportOps.Refused {
            calls.add(new Object[] {file, maxPixels});
            if (refuse != null) {
                throw refuse;
            }
            return result;
        }
    }

    @Test
    public void aScreenshotIsDecodedNativelyAndStoredWithItsFlag() throws Exception {
        final Decoder decoder = new Decoder();
        decoder.result = bitmap();
        ReportOps.setScreenshot(report, decoder, source.getPath(), 2, true);
        assertEquals(ReportOps.MAX_SCREENSHOT_PIXELS, decoder.calls.get(0)[1]);
        assertSame(decoder.result, state.screenshots.get(2)[0]);
        assertEquals(Boolean.TRUE, state.screenshots.get(2)[1]);
        ReportOps.setScreenshot(report, decoder, source.getPath(), 0, false);
        assertEquals(Boolean.FALSE, state.screenshots.get(0)[1]);
        assertEquals(Arrays.asList(0, 2), new ArrayList<>(state.screenshots.keySet()));
    }

    @Test
    public void aReplacedScreenshotLosesTheAnnotatedFlag() throws Exception {
        final Decoder decoder = new Decoder();
        decoder.result = bitmap();
        ReportOps.setScreenshot(report, decoder, source.getPath(), 0, true);
        ReportOps.setScreenshot(report, decoder, source.getPath(), 0, false);
        assertEquals(Boolean.FALSE, state.screenshots.get(0)[1]);
    }

    @Test
    public void anImageThePlatformRefusesIsNamedAndStoresNothing() throws Exception {
        final Decoder decoder = new Decoder();
        for (final String code : new String[] {ReportOps.IMAGE_UNDECODABLE, ReportOps.IMAGE_TOO_LARGE}) {
            decoder.refuse = new ReportOps.Refused(code);
            assertEquals(code, refusalOf(() -> ReportOps.setScreenshot(
                    report, decoder, source.getPath(), 0, false)));
        }
        assertTrue(state.screenshots.isEmpty());
    }

    @Test
    public void aBadScreenshotPathOrDisplayIsRefusedBeforeDecoding() {
        final Decoder decoder = new Decoder();
        assertBad(() -> ReportOps.setScreenshot(report, decoder, "x.png", 0, false));
        assertBad(() -> ReportOps.setScreenshot(report, decoder, "file:///x.png", 0, false));
        assertBad(() -> ReportOps.setScreenshot(report, decoder, source.getPath(), -1, false));
        assertBad(() -> ReportOps.setScreenshot(report, decoder, source.getPath(), 1L << 31, false));
        assertEquals("missing", ReportOps.FILE_NOT_FOUND, refusalOf(() -> ReportOps.setScreenshot(
                report, decoder, new File(tmp.getRoot(), "no.png").getPath(), 0, false)));
        assertEquals(0, decoder.calls.size());
    }

    @Test
    public void removingAScreenshotSetsNullAndAnUnknownDisplayIsHarmless() throws Exception {
        final Decoder decoder = new Decoder();
        decoder.result = bitmap();
        ReportOps.setScreenshot(report, decoder, source.getPath(), 1, true);
        ReportOps.removeScreenshot(report, 1);
        ReportOps.removeScreenshot(report, 7);
        assertTrue(state.screenshots.isEmpty());
        assertBad(() -> ReportOps.removeScreenshot(report, -1));
    }

    // ---- read ----------------------------------------------------------------------------------------

    @Test
    public void readListsAttachmentMetadataAndScreenshotsAscending() throws Exception {
        ReportOps.addFile(report, source.getPath(), "Log", "text/plain", false);
        ReportOps.addBytes(report, new byte[2], "raw", null);
        final Decoder decoder = new Decoder();
        decoder.result = bitmap();
        ReportOps.setScreenshot(report, decoder, source.getPath(), 3, false);
        ReportOps.setScreenshot(report, decoder, source.getPath(), 0, true);
        final ReportOps.Snapshot s = ReportOps.read(report);
        assertEquals(2, s.attachments.size());
        assertArrayEquals(new String[] {"Log", "text/plain", "app.log"}, s.attachments.get(0));
        assertArrayEquals(new String[] {"raw", null, "raw"}, s.attachments.get(1));
        assertEquals(2, s.screenshots.size());
        assertArrayEquals(new int[] {0, 1}, s.screenshots.get(0));
        assertArrayEquals(new int[] {3, 0}, s.screenshots.get(1));
    }

    @Test
    public void theBridgesFailureCodesAreTheDartOnes() {
        // The Dart ReportWire strings, repeated; test/report_attachments_drift_test.dart compares all copies.
        assertEquals("not-live", ReportOps.NOT_LIVE);
        assertEquals("file-not-found", ReportOps.FILE_NOT_FOUND);
        assertEquals("not-a-file", ReportOps.NOT_A_FILE);
        assertEquals("unreadable", ReportOps.UNREADABLE);
        assertEquals("too-large", ReportOps.TOO_LARGE);
        assertEquals("limit", ReportOps.LIMIT);
        assertEquals("rejected", ReportOps.REJECTED);
        assertEquals("busy", ReportOps.BUSY);
        assertEquals("unsupported", ReportOps.UNSUPPORTED);
        assertEquals("image-undecodable", ReportOps.IMAGE_UNDECODABLE);
        assertEquals("image-too-large", ReportOps.IMAGE_TOO_LARGE);
        assertEquals(1024 * 1024, ReportOps.MAX_ATTACHMENT_BYTES);
    }
}
