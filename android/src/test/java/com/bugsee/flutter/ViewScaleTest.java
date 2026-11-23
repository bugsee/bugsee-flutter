package com.bugsee.flutter;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertNull;

import org.junit.Test;

import java.util.Arrays;

public class ViewScaleTest {

    private static float[] m(final float sx, final float sy, final float skewX, final float skewY) {
        return new float[] {sx, skewX, 0, skewY, sy, 0, 0, 0, 1};
    }

    @Test
    public void identityIsScaleOne() {
        assertArrayEquals(new double[] {1, 1},
                ViewScale.accumulate(Arrays.asList(m(1, 1, 0, 0), m(1, 1, 0, 0))), 1e-9);
    }

    @Test
    public void scalesMultiplyUpTheAncestorChain() {
        assertArrayEquals(new double[] {0.45, 0.9},
                ViewScale.accumulate(Arrays.asList(m(0.9f, 1, 0, 0), m(0.5f, 0.9f, 0, 0))), 1e-6);
    }

    @Test
    public void aRotationOrSkewIsNotAScaleAndCoversTheWholeDisplay() {
        assertNull(ViewScale.accumulate(Arrays.asList(m(1, 1, 0.1f, -0.1f))));
        assertNull(ViewScale.accumulate(Arrays.asList(m(1, 1, 0, 0), m(1, 1, 0, 0.05f))));
    }

    @Test
    public void aPerspectiveTermOrANonPositiveScaleIsNotUsable() {
        final float[] perspective = {1, 0, 0, 0, 1, 0, 0.001f, 0, 1};
        assertNull(ViewScale.accumulate(Arrays.asList(perspective)));
        assertNull(ViewScale.accumulate(Arrays.asList(m(0, 1, 0, 0))));
        assertNull(ViewScale.accumulate(Arrays.asList(m(-1, 1, 0, 0))));
    }
}
