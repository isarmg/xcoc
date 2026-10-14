plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "org.sarmg.xcoc"
    compileSdk = 36
    if (providers.gradleProperty("xcocEmulatorTests").orNull == "true") {
        useLibrary("android.test.runner")
        useLibrary("android.test.base")
        sourceSets["androidTest"].java.srcDir("src/emulatorTest/java")
    }
    defaultConfig {
        applicationId = "org.sarmg.xcoc"
        minSdk = 26
        targetSdk = 36
        versionCode = 1_000_000
        versionName = "1.0.0"
        // Emulator candidates never change the shipping arm64 default.
        ndk { abiFilters += if (providers.gradleProperty("xcocEmulatorTests").orNull == "true") "x86_64" else "arm64-v8a" }
        testInstrumentationRunner = "android.test.InstrumentationTestRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    sourceSets["main"].jniLibs.srcDir("src/main/jniLibs")
    testOptions.unitTests.all {
        it.jvmArgs("-Djava.library.path=${file("../../../target/debug").absolutePath}")
    }
}
dependencies { testImplementation("junit:junit:4.13.2") }
