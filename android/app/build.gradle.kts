plugins { id("com.android.application"); id("org.jetbrains.kotlin.android") }
android {
    namespace = "chat.xucheri.androidonmac.receiver"
    compileSdk = 35
    buildToolsVersion = "35.0.0"
    defaultConfig {
        applicationId = "chat.xucheri.androidonmac.receiver"
        minSdk = 30
        targetSdk = 35
        versionCode = 2
        versionName = "0.2.0-preview.1"
    }
    buildTypes { release { isMinifyEnabled = false } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isReturnDefaultValues = true }
}
dependencies {
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    // ZXing 4.3.0's published POM omits its implementation dependencies.
    // These exact versions match the upstream v4.3.0 build.gradle.
    implementation("androidx.core:core:1.6.0")
    implementation("androidx.fragment:fragment:1.3.6")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}

dependencyLocking { lockAllConfigurations(); lockMode.set(org.gradle.api.artifacts.dsl.LockMode.STRICT) }
