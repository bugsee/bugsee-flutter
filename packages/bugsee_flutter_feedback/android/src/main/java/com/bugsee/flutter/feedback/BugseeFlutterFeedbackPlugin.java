package com.bugsee.flutter.feedback;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The Dart <-> native bridge of the feedback package. Registration of the feedback module with
 * the SDK is not done here: the module's own init provider (or the Bugsee Gradle plugin's injected
 * call) does it before the app runs. {@link BugseeFeedbackSdk#registerIfMissing} only covers a
 * build where neither did.
 *
 * <p>Internal: the public API is {@code lib/bugsee_flutter_feedback.dart}.
 */
public class BugseeFlutterFeedbackPlugin implements FlutterPlugin, Messages.FeedbackHostApi {

    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    /** Set once any engine found the SDK without the module and registered it itself. */
    private static final AtomicBoolean SAFETY_NET_USED = new AtomicBoolean(false);

    private FeedbackOps ops;
    private Messages.FeedbackFlutterApi dart;

    @Override
    public void onAttachedToEngine(@NonNull final FlutterPluginBinding binding) {
        final BugseeFeedbackSdk sdk = new BugseeFeedbackSdk();
        if (sdk.registerIfMissing()) {
            SAFETY_NET_USED.set(true);
        }
        dart = new Messages.FeedbackFlutterApi(binding.getBinaryMessenger());
        ops = new FeedbackOps(sdk, MAIN::post, new FeedbackOps.Sink() {
            @Override
            public void messagesReceived(@NonNull final List<String> messages) {
                dart.onMessagesReceived(messages, ignored());
            }

            @Override
            public void messageSent(@NonNull final String message) {
                dart.onMessageSent(message, ignored());
            }
        });
        Messages.FeedbackHostApi.setUp(binding.getBinaryMessenger(), this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull final FlutterPluginBinding binding) {
        Messages.FeedbackHostApi.setUp(binding.getBinaryMessenger(), null);
        if (ops != null) {
            ops.detach();
            ops = null;
        }
        dart = null;
    }

    /** No Dart receiver (a hot restart in progress): the event is not owed to anyone. */
    private static Messages.VoidResult ignored() {
        return new Messages.VoidResult() {
            @Override
            public void success() {
            }

            @Override
            public void error(@NonNull final Throwable error) {
                Log.d(BugseeFeedbackSdk.TAG, "no Dart receiver for a feedback event");
            }
        };
    }

    @NonNull
    @Override
    public Boolean attach() {
        return run(() -> ops.attach());
    }

    @NonNull
    @Override
    public Boolean registeredBySafetyNet() {
        return SAFETY_NET_USED.get();
    }

    @Override
    public void show() {
        run(() -> {
            ops.show();
            return null;
        });
    }

    @Override
    public void setGreeting(final String greeting) {
        run(() -> {
            ops.setGreeting(greeting);
            return null;
        });
    }

    @Override
    public void setListenerEnabled(@NonNull final Boolean enabled) {
        run(() -> {
            ops.setListenerEnabled(enabled);
            return null;
        });
    }

    private interface Body<T> {
        T run();
    }

    private <T> T run(@NonNull final Body<T> body) {
        final FeedbackOps current = ops;
        if (current == null) {
            throw new Messages.FlutterError("not-attached", "the plugin is not attached to an engine", null);
        }
        try {
            return body.run();
        } catch (final FeedbackException e) {
            throw new Messages.FlutterError(e.code, e.getMessage(), null);
        }
    }
}
