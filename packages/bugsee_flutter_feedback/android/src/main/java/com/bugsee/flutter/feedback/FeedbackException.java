package com.bugsee.flutter.feedback;

import androidx.annotation.NonNull;

/**
 * A failure with the code the Dart side maps ({@link FeedbackOps#NOT_REGISTERED},
 * {@link FeedbackOps#SDK_ERROR}). The message never carries user data: only what was wrong.
 */
final class FeedbackException extends RuntimeException {

    @NonNull
    final String code;

    FeedbackException(@NonNull final String code, @NonNull final String message) {
        super(message);
        this.code = code;
    }
}
