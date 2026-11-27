// The film's sound as ExoPlayer's ♪ shapes it (Stereo mode, Night mode:
// android/app/src/main/kotlin/com/innocent/media/audio) on a plain JVM.
// Plain Kotlin on 16-bit PCM, so what passes here is the code the APK
// carries.
//
//   cd tool/audiojvm && gradle test
plugins {
    kotlin("jvm") version "2.1.0"
}

repositories {
    maven("https://maven-central.storage-download.googleapis.com/maven2/")
    mavenCentral()
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

sourceSets {
    main {
        kotlin.srcDir("../../android/app/src/main/kotlin/com/innocent/media/audio")
    }
}

dependencies {
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
