allprojects {
    repositories {
        google()
        mavenCentral()
        // Phase 64: JitPack — hosts libadb-android (embedded wireless-ADB
        // client) for reaching Android/data without root. Milestone 0 just
        // verifies FlutLab can fetch from here before we build on it.
        maven { url = uri("https://jitpack.io") }
    }

    // FORCE Kotlin 2.1.0 across all subprojects.
    // Some Flutter plugins pull in kotlin-stdlib 2.2.0 transitively,
    // which is incompatible with the Kotlin compiler version we use.
    // This resolution strategy ensures every module resolves to 2.1.0.
    configurations.all {
        resolutionStrategy.eachDependency {
            if (requested.group == "org.jetbrains.kotlin") {
                useVersion("2.1.0")
                because("Force consistent Kotlin runtime across all plugins")
            }
        }
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
