import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "org.opensource.openscribe"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.opensource.openscribe"
        minSdk = 29
        targetSdk = 36
        versionCode = 70
        versionName = "0.7.0"
    }

    // Release signing lives outside the repo, on the release machine only:
    // ~/.openscribe-release/android-keystore.properties (storeFile, storePassword, keyAlias, keyPassword),
    // or the file named by OPENSCRIBE_ANDROID_SIGNING. Without it, release builds are unsigned.
    val signingFile = file(System.getenv("OPENSCRIBE_ANDROID_SIGNING") ?: "${System.getProperty("user.home")}/.openscribe-release/android-keystore.properties")
    val signing = Properties().apply { if (signingFile.exists()) signingFile.inputStream().use(::load) }
    signingConfigs {
        if (signing.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // R8 shrinks the APK from about 30 MB to a fraction of that.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfigs.findByName("release")?.let { signingConfig = it }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.08.00")
    implementation(composeBom)
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    // OpenScribe Cloud: the relay WebSocket and encrypted image blobs.
    implementation("com.squareup.okhttp3:okhttp:5.4.0")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
    // android.jar's org.json is a stub on the JVM; the real one runs the protocol tests.
    testImplementation("org.json:json:20250517")
    testImplementation("com.squareup.okhttp3:mockwebserver3:5.4.0")
}
