import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("io.github.takahirom.roborazzi")
}

android {
    namespace = "org.zaviya.installer"
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "org.zaviya.installer"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        ndk { abiFilters += "arm64-v8a" }
    }

    buildTypes {
        release { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging {
        // zstd is shipped as a library file so root can run it from the app's folder.
        jniLibs { useLegacyPackaging = true }
    }
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
        }
    }
}

// The bootloader files must be exactly the pinned OpenABL 1.2 ones.
val pinnedAbl = mapOf(
    "SM8250" to "628dbff74f5b570b897c14725f2c36ff2ca5fe018998e2c248a3d15d906ccef9",
    "SM8550" to "2a2808d12f2d494ddd2c39093bbffa90bc43402050be1a87baf6a4c37c830163",
    "SM8650" to "303e389b1e3909074b42415276872c3fc0dcc997200918b4d055fd264b0736dc",
    "SM8750" to "0dba7b90d1a36e13977c00fec87f4f5ccc8f49b98864ad495a1ed04d35e33c3a",
)
val verifyAbl by tasks.registering {
    val dir = layout.projectDirectory.dir("src/main/assets/openabl")
    inputs.dir(dir)
    doLast {
        pinnedAbl.forEach { (soc, want) ->
            val f = dir.file("abl_signed-$soc.elf").asFile
            check(f.isFile) { "Missing ${f.name}. Run tools/fetch-openabl.sh." }
            val got = MessageDigest.getInstance("SHA-256").digest(f.readBytes()).joinToString("") { "%02x".format(it) }
            check(got == want) { "${f.name} does not match the pinned hash." }
        }
    }
}
tasks.named("preBuild") { dependsOn(verifyAbl) }

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.05.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.runtime:runtime")
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("org.robolectric:robolectric:4.14.1")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.41.0")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.41.0")
    testImplementation(platform("androidx.compose:compose-bom:2025.05.01"))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

// The screen tests always write their PNGs to ../design/screens.
tasks.withType<Test>().configureEach {
    systemProperty("roborazzi.test.record", "true")
}
