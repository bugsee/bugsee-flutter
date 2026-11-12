package com.bugsee.flutter;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

/**
 * Ends the SDK's startup hold (manifest meta-data {@code com.bugsee.wrapper-hold}, Android SDK
 * 7.5.x).
 *
 * <p>With the meta-data set the SDK blacks out every display (video, touches, view hierarchy,
 * screenshots) from process start until the wrapper says, through its channel
 * ({@code BugseeWrapperChannel.onWrapperReady()}), that its runtime is up and has published what
 * it masks. Before Dart has published anything the secure-rectangle store answers "unknown and
 * empty", so without the hold the first seconds of a session, in which a secure view may already
 * be on screen, are recorded in the clear.
 *
 * <p>The hold must NEVER outlive a runtime that cannot end it, because a held display records
 * nothing. Three things end it, the first one wins:
 *
 * <ul>
 *   <li>the first frame the Flutter engine displays, plus {@link #SETTLE_MS}: the secure views of
 *       that frame are measured and published right after it by Dart (no Bugsee call from the app
 *       is needed);
 *   <li>{@link #CAP_MS} after a Flutter engine attached ({@link #engineAttached}): an engine that
 *       never shows a frame (a background isolate, a failed start) must not black out the
 *       recording. It counts from the ENGINE, not the process: a slow cold start (a debug build
 *       on a slow phone took 10 s to reach Dart) would otherwise end the hold before the runtime
 *       exists, which is when it matters;
 *   <li>{@link #PROCESS_CAP_MS} after process start, for a process that never attaches an engine
 *       at all (the SDK warns after 15 s that a hold is still on, and records nothing meanwhile);
 *   <li>nothing else: there is no Dart signal, so the hold does not depend on the app calling
 *       any Bugsee API.
 * </ul>
 *
 * <p>The SDK's release is sticky (a ready signal given before the hold or before launch also
 * counts), so a second engine, a hot restart or a relaunch is not held again. The signal needs
 * the SDK's channel; while there is none the release is retried every {@link #RETRY_MS} until
 * {@link #CAP_MS} has passed. Everything runs on the main thread except {@link #start} and
 * {@link #uiDisplayed}, which only post.
 */
final class WrapperHold {

    static final String TAG = "BugseeFlutter";

    /** The first frame's secure rectangles are published by Dart right after it. */
    static final long SETTLE_MS = 750;
    /** After an engine attached and showed nothing. */
    static final long CAP_MS = 10_000;
    /** A process that never attaches an engine; the SDK warns at 15 s (only a log line). */
    static final long PROCESS_CAP_MS = 20_000;
    static final long RETRY_MS = 250;

    /** Posts to the main thread; a seam for tests (and for {@code java.util.function} at API 21). */
    interface Scheduler {
        void postDelayed(@NonNull Runnable task, long delayMs);

        void cancel(@NonNull Runnable task);
    }

    /** Tells the SDK; returns false when it could not be told (no channel yet). */
    interface Signal {
        boolean deliver();
    }

    private static final WrapperHold SHARED = new WrapperHold(mainThread(), () -> {
        final com.bugsee.library.contracts.internal.BugseeWrapperChannel channel =
                NetworkChannelHolder.shared().get();
        if (channel == null) {
            return false;
        }
        channel.onWrapperReady();
        return true;
    });

    @NonNull
    static WrapperHold shared() {
        return SHARED;
    }

    private final Scheduler scheduler;
    private final Signal signal;

    private boolean started;
    private boolean settleArmed;
    private boolean engineSeen;
    private boolean released;
    private int attempts;

    private final Runnable settleTask = () -> release("the first frame was displayed");
    private final Runnable capTask = () -> release("the time cap passed");
    private final Runnable retryTask = () -> release(null);

    WrapperHold(@NonNull final Scheduler scheduler, @NonNull final Signal signal) {
        this.scheduler = scheduler;
        this.signal = signal;
    }

    /** The process started and the wrapper registered: the cap begins. Idempotent. */
    synchronized void start() {
        if (started) {
            return;
        }
        started = true;
        scheduler.postDelayed(capTask, PROCESS_CAP_MS);
    }

    /** A Flutter engine attached: the cap now counts from here. Idempotent. */
    synchronized void engineAttached() {
        if (released || engineSeen) {
            return;
        }
        engineSeen = true;
        Log.i(TAG, "wrapper-hold: a Flutter engine attached; the cap counts from here");
        scheduler.cancel(capTask);
        scheduler.postDelayed(capTask, CAP_MS);
    }

    /** The Flutter engine displayed a frame. Idempotent. */
    synchronized void uiDisplayed() {
        if (released || settleArmed) {
            return;
        }
        settleArmed = true;
        Log.i(TAG, "wrapper-hold: the first Flutter frame was displayed");
        scheduler.postDelayed(settleTask, SETTLE_MS);
    }

    synchronized boolean isReleased() {
        return released;
    }

    /** {@code why == null}: a retry of one already decided. */
    private synchronized void release(final String why) {
        if (released) {
            return;
        }
        boolean delivered = false;
        try {
            delivered = signal.deliver();
        } catch (Throwable t) {
            Log.e(TAG, "wrapper-hold: the ready signal failed: " + t.getClass().getName());
        }
        if (!delivered) {
            // No channel (yet). Try again shortly, but not forever: the SDK warns at 15 s.
            attempts++;
            if (attempts * RETRY_MS <= PROCESS_CAP_MS) {
                scheduler.postDelayed(retryTask, RETRY_MS);
            } else {
                Log.w(TAG, "wrapper-hold: no SDK channel to release the hold through");
            }
            return;
        }
        released = true;
        scheduler.cancel(settleTask);
        scheduler.cancel(capTask);
        scheduler.cancel(retryTask);
        if (why != null) {
            Log.i(TAG, "wrapper-hold released: " + why);
        } else {
            Log.i(TAG, "wrapper-hold released after retrying");
        }
    }

    @NonNull
    private static Scheduler mainThread() {
        final Handler handler = new Handler(Looper.getMainLooper());
        return new Scheduler() {
            @Override
            public void postDelayed(@NonNull final Runnable task, final long delayMs) {
                handler.postDelayed(task, delayMs);
            }

            @Override
            public void cancel(@NonNull final Runnable task) {
                handler.removeCallbacks(task);
            }
        };
    }
}
