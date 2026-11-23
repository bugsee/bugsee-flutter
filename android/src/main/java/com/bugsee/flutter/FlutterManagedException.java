package com.bugsee.flutter;

import androidx.annotation.NonNull;

/**
 * The carrier of a Dart error through the Android SDK's exception APIs. The backend routes a
 * Flutter exception on this class's name (worker {@code crash/managed/__init__.py}:
 * {@code 'FlutterManagedException' in name}) and reads the JSON document in {@link #getMessage()}
 * (the SDK writes it as the exception's {@code reason}, untouched). {@code consumer-rules.pro}
 * keeps the name through R8; the document's own {@code internalType} says the same, so a build
 * that renamed the class is still recognised (the worker also routes on the reason).
 *
 * <p>Never rename, never nest it: the name is the contract (doc/exceptions.md). It has no stack of
 * its own to speak of: the SDK records the Java stack of the platform thread, which the worker
 * replaces with the frames in the document.
 */
final class FlutterManagedException extends Exception {

    FlutterManagedException(@NonNull final String document) {
        super(document);
    }
}
