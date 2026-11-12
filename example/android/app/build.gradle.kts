plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
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

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
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
            // Device verification only (scripts/device, doc/verification.md): a phone without root
            // cannot read the private data of a non-debuggable app, so the harness may build the
            // release type debuggable (still R8, obfuscation and the Gradle plugin). Never set in a
            // normal build; the report says when it was.
            isDebuggable = System.getenv("BUGSEE_VERIFY_DEBUGGABLE_RELEASE") == "1"
        }
    }
}

flutter {
    source = "../.."
}

// Native crash FRAMES are only readable with the native symbols: this uploads the unstripped
// libraries (libflutter.so and every other .so the app ships) of each non-debuggable build, keyed
// by build id. It is OFF by default in the plugin; without it a native crash in a release build
// reaches the backend as raw addresses. It needs the app token (`bugsee.properties` in this
// directory or `appToken("...")` here); with none it skips quietly.
bugsee {
    ndk { enabled.set(true) }
}
