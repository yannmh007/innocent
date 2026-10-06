plugins {
    kotlin("jvm") version "2.1.0"
}

repositories {
    // Google's mirror of Maven Central first: Central rate-limits busy CI egress.
    maven("https://maven-central.storage-download.googleapis.com/maven2/")
    mavenCentral()
}

// Bytecode 17, like the app (android/app/build.gradle.kts compileOptions).
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}
kotlin {
    compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) }
}

sourceSets {
    main {
        kotlin.srcDir("../../android/app/src/main/kotlin/com/innocent/media/net/core")
    }
}

// Exactly the app's set (android/app/build.gradle.kts), so what passes here
// is what ships.
dependencies {
    implementation("com.hierynomus:smbj:0.11.5") {
        exclude(group = "org.bouncycastle")
    }
    implementation("eu.agno3.jcifs:jcifs-ng:2.1.10") {
        exclude(group = "org.bouncycastle")
    }
    implementation("com.hierynomus:sshj:0.40.0") {
        exclude(group = "org.bouncycastle")
    }
    implementation("org.bouncycastle:bcprov-jdk15to18:1.81")
    implementation("org.bouncycastle:bcpkix-jdk15to18:1.81")
    implementation("commons-net:commons-net:3.13.0")
    testImplementation(kotlin("test"))
    testImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showStandardStreams = true
    }
    // The servers' addresses come from tool/netlab/servers.sh.
    environment("NETLAB_HOST", System.getenv("NETLAB_HOST") ?: "127.0.0.1")
    // vsftpd issues TLS tickets with a lifetime of INT_MAX seconds, and the
    // desktop JDK discards any ticket over 7 days (RFC 8446 §4.6.1) — so on
    // a JDK the data channel can only resume by session ID. Android's TLS
    // stack is a different implementation; the device lab checks it.
    systemProperty("jdk.tls.client.enableSessionTicketExtension", "false")
}

// For reading the libraries' APIs: gradle -q cp
tasks.register("cp") {
    doLast { println(sourceSets["main"].runtimeClasspath.asPath) }
}
