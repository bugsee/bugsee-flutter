package com.bugsee.bugsee_flutter_example;

import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {

    /**
     * The crash lab of the device verification app (example/lib/crash_lab.dart): ways to take this
     * process down from native Java code, which the Dart side cannot do itself. Example code only.
     * An exception thrown inside the handler would be caught by the channel and answered as an
     * error, so each one is thrown from its own message or thread.
     */
    @Override
    public void configureFlutterEngine(@NonNull final FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "verify/crashlab")
                .setMethodCallHandler((call, result) -> {
                    switch (call.method) {
                        case "javaMain":
                            new Handler(Looper.getMainLooper()).post(() -> {
                                throw new IllegalStateException("verify-java-main");
                            });
                            result.success(null);
                            break;
                        case "javaThread":
                            new Thread(() -> {
                                throw new IllegalArgumentException("verify-java-thread");
                            }, "verify-crash-thread").start();
                            result.success(null);
                            break;
                        case "nested":
                            new Handler(Looper.getMainLooper()).post(() -> {
                                throw new RuntimeException("verify-java-outer",
                                        new IllegalStateException("verify-java-cause"));
                            });
                            result.success(null);
                            break;
                        default:
                            result.notImplemented();
                    }
                });
    }
}
