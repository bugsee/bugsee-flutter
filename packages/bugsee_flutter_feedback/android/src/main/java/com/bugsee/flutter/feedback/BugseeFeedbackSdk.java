package com.bugsee.flutter.feedback;

import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.bugsee.library.Bugsee;
import com.bugsee.library.BugseeFeedback;
import com.bugsee.library.contracts.extensions.Feedback;
import com.bugsee.library.contracts.feedback.FeedbackListener;

/** The one place this package calls {@code Bugsee.ext(Feedback.class)}. */
final class BugseeFeedbackSdk implements FeedbackSdk {

    static final String TAG = "BugseeFlutterFeedback";

    @Nullable
    private static Feedback extension() {
        return Bugsee.ext(Feedback.class);
    }

    @NonNull
    private static Feedback required() {
        final Feedback feedback = extension();
        if (feedback == null) {
            throw new FeedbackException(FeedbackOps.NOT_REGISTERED,
                    "the SDK has no feedback module registered");
        }
        return feedback;
    }

    @Override
    public boolean isRegistered() {
        return extension() != null;
    }

    @Override
    public boolean registerIfMissing() {
        try {
            if (extension() != null) {
                Log.i(TAG, "feedback module registered by the SDK (init provider or the Gradle"
                        + " plugin's injected call)");
                return false;
            }
            // Idempotent (the SDK checks isExtensionRegistered), and what the SDK's own provider
            // calls. A late registration is launched at once if the SDK is already running.
            BugseeFeedback.registerFeedbackExtension();
            Log.w(TAG, "the SDK had not registered the feedback module (its init provider was"
                    + " removed from the manifest, or the Bugsee Gradle plugin's injected call is"
                    + " missing); registered it from this plugin");
            return true;
        } catch (Throwable t) {
            Log.e(TAG, "could not register the feedback module: " + t.getClass().getName());
            return false;
        }
    }

    @Override
    public void show() {
        required().showFeedbackActivity();
    }

    @Override
    public void setGreeting(@Nullable final String greeting) {
        required().setDefaultFeedbackGreeting(greeting);
    }

    @Override
    public void setListener(@Nullable final FeedbackListener listener) {
        required().setOnNewFeedbackListener(listener);
    }
}
