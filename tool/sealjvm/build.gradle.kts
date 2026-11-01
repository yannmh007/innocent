// The app's media seal (android/app/src/main/kotlin/com/innocent/media/seal)
// on a plain JVM, against the vectors Google Tink opens
// (test/fixtures/media_seal_vectors.json). Pure javax.crypto, so what passes here is
// the code the APK carries.
//
//   cd tool/sealjvm && gradle test
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
        kotlin.srcDir("../../android/app/src/main/kotlin/com/innocent/media/seal")
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
    systemProperty("seal.vectors", file("../../test/fixtures/media_seal_vectors.json").absolutePath)
}
