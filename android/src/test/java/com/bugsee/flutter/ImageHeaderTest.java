package com.bugsee.flutter;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.fail;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.Base64;

/**
 * The pixel cap of a screenshot decode, with REAL image bytes (BitmapFactory does not run off a device):
 * a real 1x1 PNG, and headers built to the formats' specifications for the cases a real file would be
 * too big to keep (a huge canvas, EXIF orientation, several frames).
 */
public class ImageHeaderTest {

    @Rule public TemporaryFolder tmp = new TemporaryFolder();

    // A real PNG: 1x1, one red pixel.
    private static final byte[] REAL_PNG = Base64.getDecoder().decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEAQH/"
                    + "X9fmEwAAAABJRU5ErkJggg==");

    private static long[] dims(final byte[] bytes) throws IOException {
        return ImageHeader.dimensions(new ByteArrayInputStream(bytes));
    }

    private static byte[] png(final long width, final long height, final boolean animated) {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0x89);
        out.write('P'); out.write('N'); out.write('G');
        out.write(0x0D); out.write(0x0A); out.write(0x1A); out.write(0x0A);
        be32(out, 13);
        out.write('I'); out.write('H'); out.write('D'); out.write('R');
        be32(out, width);
        be32(out, height);
        out.write(8); out.write(6); out.write(0); out.write(0); out.write(0);
        be32(out, 0); // crc (not read)
        if (animated) {
            be32(out, 8);
            out.write('a'); out.write('c'); out.write('T'); out.write('L');
            be32(out, 3); // three frames
            be32(out, 0);
            be32(out, 0);
        }
        return out.toByteArray();
    }

    private static void be32(final ByteArrayOutputStream out, final long v) {
        out.write((int) (v >> 24) & 0xFF);
        out.write((int) (v >> 16) & 0xFF);
        out.write((int) (v >> 8) & 0xFF);
        out.write((int) v & 0xFF);
    }

    /** SOI, an EXIF APP1 (orientation 6 = rotated 90 degrees), an unrelated APP2, then SOF0. */
    private static byte[] jpeg(final int width, final int height, final boolean exifRotated) {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0xFF); out.write(0xD8);
        if (exifRotated) {
            final byte[] exif = {'E', 'x', 'i', 'f', 0, 0, 'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1,
                    0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, 6, 0, 0, 0, 0, 0, 0};
            out.write(0xFF); out.write(0xE1);
            out.write((exif.length + 2) >> 8); out.write((exif.length + 2) & 0xFF);
            out.write(exif, 0, exif.length);
        }
        out.write(0xFF); out.write(0xE2);
        out.write(0); out.write(6);
        out.write(1); out.write(2); out.write(3); out.write(4);
        out.write(0xFF); out.write(0xC0);
        out.write(0); out.write(17);
        out.write(8);
        out.write(height >> 8); out.write(height & 0xFF);
        out.write(width >> 8); out.write(width & 0xFF);
        out.write(3);
        return out.toByteArray();
    }

    private static byte[] gif(final int width, final int height) {
        return new byte[] {'G', 'I', 'F', '8', '9', 'a', (byte) width, (byte) (width >> 8),
                (byte) height, (byte) (height >> 8), 0, 0, 0, 0x21, (byte) 0xF9, 4, 0, 10, 0, 0, 0, 0x2C};
    }

    private static byte[] webpX(final long width, final long height) {
        final ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write('R'); out.write('I'); out.write('F'); out.write('F');
        out.write(0); out.write(0); out.write(0); out.write(0);
        out.write('W'); out.write('E'); out.write('B'); out.write('P');
        out.write('V'); out.write('P'); out.write('8'); out.write('X');
        out.write(10); out.write(0); out.write(0); out.write(0);
        out.write(0x02); out.write(0); out.write(0); out.write(0); // animation flag
        final long w = width - 1;
        final long h = height - 1;
        out.write((int) w & 0xFF); out.write((int) (w >> 8) & 0xFF); out.write((int) (w >> 16) & 0xFF);
        out.write((int) h & 0xFF); out.write((int) (h >> 8) & 0xFF); out.write((int) (h >> 16) & 0xFF);
        return out.toByteArray();
    }

    @Test
    public void aRealPngSaysOneByOne() throws Exception {
        assertArrayEquals(new long[] {1, 1}, dims(REAL_PNG));
    }

    @Test
    public void everyFormatGivesItsCodedDimensions() throws Exception {
        assertArrayEquals(new long[] {64, 48}, dims(png(64, 48, false)));
        assertArrayEquals(new long[] {64, 48}, dims(jpeg(64, 48, false)));
        assertArrayEquals(new long[] {300, 200}, dims(gif(300, 200)));
        assertArrayEquals(new long[] {5000, 4000}, dims(webpX(5000, 4000)));
    }

    @Test
    public void exifOrientationIsNotAppliedAndTheSofIsFoundBehindOtherSegments() throws Exception {
        // 64 x 48 coded, orientation 6: BitmapFactory ignores it, so does this (iOS applies it: documented).
        assertArrayEquals(new long[] {64, 48}, dims(jpeg(64, 48, true)));
    }

    @Test
    public void aHugeCanvasIsRefusedFromTheHeaderAloneInEveryFormat() throws Exception {
        final long cap = ReportOps.MAX_SCREENSHOT_PIXELS;
        final byte[][] huge = {
            png(70000, 70000, false), jpeg(65000, 65000, false), gif(65535, 65535), webpX(16384, 16384)};
        for (final byte[] bytes : huge) {
            final File f = tmp.newFile();
            Files.write(f.toPath(), bytes);
            try {
                ImageHeader.requireWithin(f, cap);
                fail("accepted a header over the cap");
            } catch (final ReportOps.Refused e) {
                assertEquals(ReportOps.IMAGE_TOO_LARGE, e.code);
            }
        }
    }

    @Test
    public void theCapIsInclusiveOnThePixelCount() throws Exception {
        final long cap = ReportOps.MAX_SCREENSHOT_PIXELS;
        final File edge = tmp.newFile();
        Files.write(edge.toPath(), png(4096, 4096, false));
        ImageHeader.requireWithin(edge, cap);
        final File over = tmp.newFile();
        Files.write(over.toPath(), png(4097, 4096, false));
        try {
            ImageHeader.requireWithin(over, cap);
            fail("one row over the cap was accepted");
        } catch (final ReportOps.Refused e) {
            assertEquals(ReportOps.IMAGE_TOO_LARGE, e.code);
        }
    }

    @Test
    public void aMultiFrameFileIsJudgedByItsCanvasNotDecodedPastIt() throws Exception {
        assertArrayEquals(new long[] {10, 20}, dims(png(10, 20, true)));
        final File f = tmp.newFile();
        Files.write(f.toPath(), png(10, 20, true));
        ImageHeader.requireWithin(f, ReportOps.MAX_SCREENSHOT_PIXELS);
    }

    @Test
    public void whatItCannotReadIsLeftToThePlatform() throws Exception {
        assertNull(dims(new byte[] {'B', 'M', 0, 0}));
        assertNull(dims(new byte[0]));
        assertNull(dims(new byte[] {(byte) 0xFF}));
        assertNull("a truncated header", dims(new byte[] {(byte) 0x89, 'P', 'N', 'G'}));
        final File junk = tmp.newFile();
        Files.write(junk.toPath(), "not an image at all".getBytes());
        ImageHeader.requireWithin(junk, 10); // no verdict: BitmapFactory says undecodable
    }

    @Test
    public void aJpegWithoutAFrameHeaderIsNotMisread() throws Exception {
        final byte[] noFrame = {(byte) 0xFF, (byte) 0xD8, (byte) 0xFF, (byte) 0xDA, 0, 2};
        assertNull(dims(noFrame));
    }
}
