package com.bugsee.flutter;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.List;

/** The scale a view appears at on screen, from the view matrices up its ancestor chain. */
final class ViewScale {

    private static final double TOLERANCE = 1e-4;

    private ViewScale() {}

    /**
     * The product of the x and y scales of {@code matrices} (9 values each, as
     * {@code Matrix.getValues}), or {@code null} when one has a skew or rotation
     * term, a perspective term, or a non-positive scale: not a pure scale and
     * translation, so the caller covers the whole display.
     */
    @Nullable
    static double[] accumulate(@NonNull final List<float[]> matrices) {
        double sx = 1;
        double sy = 1;
        for (final float[] m : matrices) {
            // MSCALE_X 0, MSKEW_X 1, MSKEW_Y 3, MSCALE_Y 4, MPERSP_0..2 6..8
            final boolean pure = Math.abs(m[1]) < TOLERANCE && Math.abs(m[3]) < TOLERANCE
                    && Math.abs(m[6]) < TOLERANCE && Math.abs(m[7]) < TOLERANCE
                    && Math.abs(m[8] - 1) < TOLERANCE;
            if (!pure || !(m[0] > 0) || !(m[4] > 0)) {
                return null;
            }
            sx *= m[0];
            sy *= m[4];
        }
        return new double[] {sx, sy};
    }
}
