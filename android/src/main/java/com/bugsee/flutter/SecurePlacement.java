package com.bugsee.flutter;

import android.app.Activity;
import android.util.Log;
import android.view.Display;
import android.view.View;
import android.view.ViewGroup;
import android.view.ViewTreeObserver;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.UiThread;

import io.flutter.embedding.android.FlutterView;
import io.flutter.embedding.engine.FlutterEngine;

/**
 * Keeps {@link SecureRectangleStore}'s idea of where this engine's Flutter view
 * sits on the display current.
 *
 * <p>Dart measures in the view's own logical pixels; the SDK wants the display's
 * physical pixels, the space {@code View.getLocationOnScreen} reports. The view
 * is not always at the display's origin: a status bar above it (edge-to-edge
 * off), split-screen, freeform windows, a display cutout, a keyboard that pans
 * the window. So the view's on-screen position is added to every rectangle.
 *
 * <p>The state it reports, and why:
 * <ul>
 *   <li>no activity attached: {@link SecureRectangleStore.Placement#ABSENT}, no
 *       Flutter pixels can be on screen (also across a configuration change,
 *       where the new activity re-attaches within the same frame of the main
 *       thread);</li>
 *   <li>an activity but no (or an ambiguous, or detached) Flutter view:
 *       {@link SecureRectangleStore.Placement#UNKNOWN}, which the store serves
 *       as the whole display, because the regions might be anywhere;</li>
 *   <li>otherwise the view's display id and on-screen position.</li>
 * </ul>
 * Only the engine's implicit view (id 0) exists on Android; any other view id
 * has no placement and so is served as the whole display.
 *
 * <p>Re-read on a global layout, when an activity attaches, on every publish
 * from Dart and, throttled, on every SDK pull ({@link PullThrottle}). All view
 * access is on the main thread.
 */
final class SecurePlacement implements ViewTreeObserver.OnGlobalLayoutListener {

    private static final String TAG = FlutterWrapperInitProvider.TAG;

    /** The implicit view: the only one a mobile engine has. */
    static final int IMPLICIT_VIEW_ID = 0;

    private final long owner;
    private final FlutterEngine engine;
    private final SecureRectangleStore store;
    private final SecureEnvironment environment;

    @Nullable
    private Activity activity;
    @Nullable
    private FlutterView observed;
    private final int[] location = new int[2];

    SecurePlacement(
            final long owner,
            @NonNull final FlutterEngine engine,
            @NonNull final SecureRectangleStore store,
            @NonNull final SecureEnvironment environment
    ) {
        this.owner = owner;
        this.engine = engine;
        this.store = store;
        this.environment = environment;
    }

    @UiThread
    void setActivity(@Nullable final Activity activity) {
        this.activity = activity;
        refresh();
    }

    /** Stops observing. The caller drops the owner's rectangles. */
    @UiThread
    void dispose() {
        activity = null;
        unobserve();
    }

    @Override
    public void onGlobalLayout() {
        refresh();
    }

    /** Never throws: it runs from the host app's layout and from the pull's refresh. */
    @UiThread
    void refresh() {
        try {
            if (activity == null) {
                unobserve();
                store.setPlacement(owner, IMPLICIT_VIEW_ID, SecureRectangleStore.Placement.ABSENT);
                return;
            }
            final FlutterView view = find(activity.getWindow().getDecorView(), engine);
            if (view == null || !view.isAttachedToWindow()) {
                unobserve();
                store.setPlacement(owner, IMPLICIT_VIEW_ID, SecureRectangleStore.Placement.UNKNOWN);
                return;
            }
            observe(view);
            final Display display = view.getDisplay();
            final int displayId = display == null ? 0 : display.getDisplayId();
            view.getLocationOnScreen(location);
            environment.setResources(displayId, view.getResources());
            store.setPlacement(owner, IMPLICIT_VIEW_ID,
                    SecureRectangleStore.Placement.known(displayId, location[0], location[1]));
        } catch (Throwable t) {
            Log.w(TAG, "secure rectangles: could not read the Flutter view's position: "
                    + t.getClass().getName());
            try {
                store.setPlacement(owner, IMPLICIT_VIEW_ID, SecureRectangleStore.Placement.UNKNOWN);
            } catch (Throwable ignored) {
                // nothing more to do
            }
        }
    }

    private void observe(@NonNull final FlutterView view) {
        if (view == observed) {
            return;
        }
        unobserve();
        view.getViewTreeObserver().addOnGlobalLayoutListener(this);
        observed = view;
    }

    private void unobserve() {
        final FlutterView view = observed;
        observed = null;
        if (view != null && view.getViewTreeObserver().isAlive()) {
            view.getViewTreeObserver().removeOnGlobalLayoutListener(this);
        }
    }

    /**
     * The Flutter view attached to {@code engine} in {@code root}'s tree, or
     * null when there is none or when it is ambiguous (two attached to the same
     * engine: which one the rectangles belong to cannot be told).
     */
    @Nullable
    static FlutterView find(@NonNull final View root, @NonNull final FlutterEngine engine) {
        final FlutterView[] found = new FlutterView[1];
        final int[] count = new int[1];
        walk(root, engine, found, count);
        return count[0] == 1 ? found[0] : null;
    }

    private static void walk(
            @NonNull final View view,
            @NonNull final FlutterEngine engine,
            @NonNull final FlutterView[] found,
            @NonNull final int[] count
    ) {
        if (view instanceof FlutterView && ((FlutterView) view).getAttachedFlutterEngine() == engine) {
            found[0] = (FlutterView) view;
            count[0]++;
        }
        if (view instanceof ViewGroup) {
            final ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                walk(group.getChildAt(i), engine, found, count);
            }
        }
    }
}
