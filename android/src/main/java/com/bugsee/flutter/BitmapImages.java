package com.bugsee.flutter;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

import androidx.annotation.NonNull;

import java.io.File;

/** The real decoder behind {@link ReportOps.ImageDecoder}: {@link BitmapFactory}, bounds first. */
final class BitmapImages implements ReportOps.ImageDecoder {

    @NonNull
    @Override
    public Bitmap decode(@NonNull final File file, final long maxPixels) throws ReportOps.Refused {
        // The header first (unit-tested with real image bytes): an image over the cap is refused before
        // anything is decoded. A format it does not read falls through to the platform's own bounds.
        ImageHeader.requireWithin(file, maxPixels);
        final BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(file.getPath(), bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            throw new ReportOps.Refused(ReportOps.IMAGE_UNDECODABLE);
        }
        if ((long) bounds.outWidth * (long) bounds.outHeight > maxPixels) {
            throw new ReportOps.Refused(ReportOps.IMAGE_TOO_LARGE);
        }
        final Bitmap bitmap;
        try {
            bitmap = BitmapFactory.decodeFile(file.getPath());
        } catch (final OutOfMemoryError e) {
            // Within the cap but the heap is short: the same answer as an image too large.
            throw new ReportOps.Refused(ReportOps.IMAGE_TOO_LARGE);
        }
        if (bitmap == null) {
            throw new ReportOps.Refused(ReportOps.IMAGE_UNDECODABLE);
        }
        return bitmap;
    }
}
