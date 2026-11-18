plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.bugsee.android.gradle")
}

android {
    namespace = "com.bugsee.bugsee_flutter_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bugsee.bugsee_flutter_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Native crash FRAMES are only readable with the native symbols: this uploads the unstripped
// libraries (libflutter.so and the other .so files the app packages) of each non-debuggable build,
// keyed by build id; a library that ships already stripped stays unsymbolicated. It is OFF by default
// in the plugin; without it a native crash in a release build reaches the backend as raw addresses.
// It needs the app token: `bugsee.properties` in the Gradle ROOT directory (`example/android`, the
// plugin reads `<rootProject>/bugsee.properties`; do not commit a real token) or `appToken("...")`
// here; with none it skips quietly.
bugsee {
    ndk { enabled.set(true) }
}
