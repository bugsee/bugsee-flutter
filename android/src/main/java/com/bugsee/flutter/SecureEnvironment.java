package com.bugsee.flutter;

import android.content.Context;
import android.content.res.Resources;
import android.hardware.display.DisplayManager;
import android.util.DisplayMetrics;
import android.view.Display;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.lang.ref.WeakReference;
import java.util.concurrent.ConcurrentHashMap;

/**
 * What {@link SecureRectangleStore} reads off the device, at every pull.
 *
 * <p>The density is the one Flutter itself divides by: {@code
 * getResources().getDisplayMetrics().density} of the Flutter view's context
 * (that is what {@code FlutterView} sends as the device pixel ratio). It is read
 * from the live {@link Resources} object on every call, so a density change is
 * seen at the next pull and no value is cached here.
 */
final class SecureEnvironment implements SecureRectangleStore.Environment {

    private final Context appContext;
    private final ConcurrentHashMap<Integer, WeakReference<Resources>> resources =
            new ConcurrentHashMap<>();

    SecureEnvironment(@NonNull final Context appContext) {
        this.appContext = appContext.getApplicationContext() == null
                ? appContext : appContext.getApplicationContext();
    }

    /** The Flutter view on {@code display} draws with these resources. */
    void setResources(final int display, @NonNull final Resources r) {
        resources.put(display, new WeakReference<>(r));
    }

    @Override
    public double pixelsPerLogicalPixel(final int display) {
        try {
            final WeakReference<Resources> ref = resources.get(display);
            final Resources r = ref == null ? null : ref.get();
            if (r != null) {
                return r.getDisplayMetrics().density;
            }
            final DisplayMetrics metrics = metricsOf(display);
            return metrics == null ? Double.NaN : metrics.density;
        } catch (Throwable t) {
            return Double.NaN;
        }
    }

    @Nullable
    @Override
    public int[] displayBounds(final int display) {
        try {
            final DisplayMetrics metrics = metricsOf(display);
            return metrics == null
                    ? null : new int[] {metrics.widthPixels, metrics.heightPixels};
        } catch (Throwable t) {
            return null;
        }
    }

    @Nullable
    @SuppressWarnings("deprecation") // getRealMetrics: still the real size on every API
    private DisplayMetrics metricsOf(final int display) {
        final DisplayManager dm =
                (DisplayManager) appContext.getSystemService(Context.DISPLAY_SERVICE);
        final Display d = dm == null ? null : dm.getDisplay(display);
        if (d == null) {
            return null;
        }
        final DisplayMetrics out = new DisplayMetrics();
        d.getRealMetrics(out);
        return out;
    }
}
