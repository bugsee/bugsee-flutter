package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.DataInputStream;
import java.io.EOFException;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * Reads the pixel dimensions of an image from its HEADER, as plain Java, so the pixel cap that guards a
 * screenshot decode ({@link ReportOps#MAX_SCREENSHOT_PIXELS}) is unit-tested with real image bytes:
 * {@code BitmapFactory} does not run off a device. PNG, JPEG, GIF and WebP are read; any other format
 * (or a header this cannot parse) answers null and the caller asks {@code BitmapFactory} for the bounds.
 *
 * <p>Dimensions are the coded ones: a JPEG's EXIF orientation is not applied (as
 * {@code BitmapFactory}, and unlike {@code UIImage} on iOS), a GIF or an animated WebP gives the canvas of
 * the first frame, a multi-frame file is not decoded past it. The pixel COUNT is what the cap is about, and
 * rotation does not change it.
 */
final class ImageHeader {

    private ImageHeader() {
    }

    /** {width, height}, or null when the format or the header is not one this reads. */
    @Nullable
    static long[] dimensions(@NonNull final InputStream in) throws IOException {
        final DataInputStream data = new DataInputStream(in);
        final int b0 = data.read();
        final int b1 = data.read();
        if (b0 < 0 || b1 < 0) {
            return null;
        }
        try {
            if (b0 == 0x89 && b1 == 'P') {
                return png(data);
            }
            if (b0 == 0xFF && b1 == 0xD8) {
                return jpeg(data);
            }
            if (b0 == 'G' && b1 == 'I') {
                return gif(data);
            }
            if (b0 == 'R' && b1 == 'I') {
                return webp(data);
            }
        } catch (final EOFException truncated) {
            return null;
        }
        return null;
    }

    /**
     * Refuses an image whose header says it has more than {@code maxPixels}; answers normally for a
     * smaller one and for one this class cannot read.
     */
    static void requireWithin(@NonNull final File file, final long maxPixels) throws ReportOps.Refused {
        final long[] size;
        try (InputStream in = new FileInputStream(file)) {
            size = dimensions(in);
        } catch (final IOException e) {
            throw new ReportOps.Refused(ReportOps.IMAGE_UNDECODABLE);
        }
        // A division, not a product: two unsigned 32-bit sides can multiply past Long.MAX_VALUE and wrap negative.
        if (size != null && size[0] > 0 && size[1] > 0 && size[0] > maxPixels / size[1]) {
            throw new ReportOps.Refused(ReportOps.IMAGE_TOO_LARGE);
        }
    }

    private static long[] png(final DataInputStream in) throws IOException {
        // Already read 0x89 'P'; the rest of the signature is 'N' 'G' CR LF SUB LF.
        final byte[] rest = new byte[6];
        in.readFully(rest);
        if (rest[0] != 'N' || rest[1] != 'G') {
            return null;
        }
        in.readInt(); // IHDR length
        if (in.readInt() != 0x49484452) { // "IHDR"
            return null;
        }
        return new long[] {in.readInt() & 0xFFFFFFFFL, in.readInt() & 0xFFFFFFFFL};
    }

    private static long[] jpeg(final DataInputStream in) throws IOException {
        for (int segments = 0; segments < 4096; segments++) {
            int marker = in.readUnsignedByte();
            while (marker != 0xFF) {
                marker = in.readUnsignedByte();
            }
            int code = in.readUnsignedByte();
            while (code == 0xFF) {
                code = in.readUnsignedByte();
            }
            if (code == 0xD8 || code == 0x01 || (code >= 0xD0 && code <= 0xD7)) {
                continue; // no length
            }
            if (code == 0xD9 || code == 0xDA) {
                return null; // end of image / start of scan: no frame header was found
            }
            final int length = in.readUnsignedShort();
            final boolean frame = code >= 0xC0 && code <= 0xCF && code != 0xC4 && code != 0xC8 && code != 0xCC;
            if (frame) {
                in.readUnsignedByte(); // precision
                final int height = in.readUnsignedShort();
                final int width = in.readUnsignedShort();
                return new long[] {width, height};
            }
            skipFully(in, length - 2);
        }
        return null;
    }

    private static long[] gif(final DataInputStream in) throws IOException {
        final byte[] rest = new byte[4]; // 'F' '8' '7|9' 'a'
        in.readFully(rest);
        if (rest[0] != 'F' || rest[1] != '8') {
            return null;
        }
        final int width = in.readUnsignedByte() | (in.readUnsignedByte() << 8);
        final int height = in.readUnsignedByte() | (in.readUnsignedByte() << 8);
        return new long[] {width, height};
    }

    private static long[] webp(final DataInputStream in) throws IOException {
        final byte[] riff = new byte[10]; // 'F' 'F' size(4) "WEBP"
        in.readFully(riff);
        if (riff[0] != 'F' || riff[1] != 'F' || riff[6] != 'W' || riff[7] != 'E' || riff[8] != 'B'
                || riff[9] != 'P') {
            return null;
        }
        final byte[] fourcc = new byte[4];
        in.readFully(fourcc);
        in.readInt(); // chunk size (little endian; not needed)
        final String kind = new String(fourcc, java.nio.charset.StandardCharsets.US_ASCII);
        if ("VP8X".equals(kind)) {
            in.readInt(); // flags + reserved
            final long width = 1 + le24(in);
            final long height = 1 + le24(in);
            return new long[] {width, height};
        }
        if ("VP8L".equals(kind)) {
            if (in.readUnsignedByte() != 0x2F) {
                return null;
            }
            final int a = in.readUnsignedByte();
            final int b = in.readUnsignedByte();
            final int c = in.readUnsignedByte();
            final int d = in.readUnsignedByte();
            final long width = 1 + (a | ((b & 0x3F) << 8));
            final long height = 1 + ((b >> 6) | (c << 2) | ((d & 0x0F) << 10));
            return new long[] {width, height};
        }
        if ("VP8 ".equals(kind)) {
            in.skipBytes(3); // frame tag
            if (in.readUnsignedByte() != 0x9D || in.readUnsignedByte() != 0x01 || in.readUnsignedByte() != 0x2A) {
                return null;
            }
            final int width = (in.readUnsignedByte() | (in.readUnsignedByte() << 8)) & 0x3FFF;
            final int height = (in.readUnsignedByte() | (in.readUnsignedByte() << 8)) & 0x3FFF;
            return new long[] {width, height};
        }
        return null;
    }

    private static long le24(final DataInputStream in) throws IOException {
        return in.readUnsignedByte() | (in.readUnsignedByte() << 8) | (in.readUnsignedByte() << 16);
    }

    private static void skipFully(final DataInputStream in, final int count) throws IOException {
        int left = count;
        while (left > 0) {
            final int skipped = in.skipBytes(left);
            if (skipped <= 0) {
                if (in.read() < 0) {
                    throw new EOFException();
                }
                left -= 1;
            } else {
                left -= skipped;
            }
        }
    }
}
