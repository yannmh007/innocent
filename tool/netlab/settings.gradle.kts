// The Local Network core, built and tested on a plain JVM against real servers
// (Samba, vsftpd, OpenSSH) — see README.md. The sources are the app's own:
// android/app/src/main/kotlin/com/innocent/media/net/core.
pluginManagement {
    repositories {
        maven("https://maven-central.storage-download.googleapis.com/maven2/")
        gradlePluginPortal()
    }
}
rootProject.name = "netlab"
