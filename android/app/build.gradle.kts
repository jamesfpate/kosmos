plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "net.jamespate.winnow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "net.jamespate.winnow"
        // Android 11: moving photos to the system trash (MediaStore.createTrashRequest).
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing: the keystore comes from CI secrets (backup on the homelab server,
    // /mnt/user/appdata/winnow/, winnow-release.jks + keystore.env). Same key as the earlier Capacitor app, so this
    // installs as an update over it.
    signingConfigs {
        create("release") {
            val keystore = System.getenv("WINNOW_KEYSTORE_FILE")
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = System.getenv("WINNOW_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("WINNOW_KEY_ALIAS")
                keyPassword = System.getenv("WINNOW_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (System.getenv("WINNOW_KEYSTORE_FILE") != null) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
            manifestPlaceholders["appName"] = "Winnow"
        }
        debug {
            // Installs next to the release build as "Winnow dev".
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appName"] = "Winnow dev"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
