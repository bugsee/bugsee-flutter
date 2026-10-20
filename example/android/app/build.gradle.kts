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
        }
    }
}

flutter {
    source = "../.."
}

// The Bugsee Gradle plugin's injectBugsee<Variant>BuildId task writes into the merged
// assets that Flutter's copyFlutter<Variant>Assets produces, without declaring that
// ordering; Gradle 8.14 rejects the build. Declare it here until the plugin does.
tasks.matching { it.name.startsWith("injectBugsee") && it.name.endsWith("BuildId") }.configureEach {
    val variant = name.removePrefix("injectBugsee").removeSuffix("BuildId")
    mustRunAfter("copyFlutterAssets$variant")
}
