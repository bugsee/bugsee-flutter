package com.bugsee.flutter.feedback;

import androidx.annotation.Nullable;

import com.bugsee.library.contracts.feedback.FeedbackListener;

/**
 * What the plugin needs from the SDK's feedback module: a seam, so JUnit can see what reaches it
 * (the real module needs an Android runtime).
 */
interface FeedbackSdk {

    /** Whether {@code Bugsee.ext(Feedback.class)} has an instance. */
    boolean isRegistered();

    /**
     * Registers the module with the SDK if the SDK did not do it itself, and says whether it had to.
     * Never throws.
     */
    boolean registerIfMissing();

    /** {@code Feedback.showFeedbackActivity()}. Throws if the module is not registered. */
    void show();

    /** {@code Feedback.setDefaultFeedbackGreeting}. Throws if the module is not registered. */
    void setGreeting(@Nullable String greeting);

    /** {@code Feedback.setOnNewFeedbackListener}. Throws if the module is not registered. */
    void setListener(@Nullable FeedbackListener listener);
}
