import java.util.Properties
import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// ─────────────────────────────────────────────────────────────────────────────
// RELEASE SIGNING (added 30 Aug 2026)
//
// Release builds used to be signed with the DEBUG key. The debug key is
// generated per build machine, is not owned and is not backed up, so the app's
// identity was an accident of whichever container last built it. Android
// refuses an update signed with a different key
// (INSTALL_FAILED_UPDATE_INCOMPATIBLE), and the in-app updater is the only
// distribution channel there is — so the key has to become a real, owned,
// backed-up one BEFORE the first public build.
//
// Where the secrets live:
//   android/key.properties   passwords + alias + the .jks filename  (NEVER shipped)
//   android/app/innocent.jks the keystore itself                    (NEVER shipped)
//
// WHY THE IMPORTS ARE AT THE TOP, and must stay there:
// writing `java.util.Properties()` inline FAILS in this file with
// "Unresolved reference: util". In an Android application module something
// named `java` is already in scope (the Java plugin's extension), so Kotlin
// resolves the leading `java` to that value and then looks for a member
// called `util` on it. settings.gradle.kts gets away with the inline form
// because no such extension exists in settings scope. Importing the class
// sidesteps the name entirely — and imports above `plugins {}` are the
// documented Flutter pattern.
//
// v1.63.3 — WHY THIS READS `signing.properties` AND NOT `key.properties`.
//
// FlutLab RESERVES the filename `android/key.properties`. Uploading one reports
// success and silently discards it; creating one by hand answers "file already
// exists"; the Explorer never shows it. FlutLab writes that file itself, from
// Settings → App Signing, and our copy never lands. Two release builds were
// signed with the throwaway DEBUG key before the APK certificate was actually
// checked — the settings screen looked correct the whole time.
//
// `signing.properties` is not a name FlutLab claims, so it survives the import.
// `key.properties` is still read as a fallback for any environment (a real
// checkout, CI, Android Studio) where the conventional name works fine.
// ─────────────────────────────────────────────────────────────────────────────
// v1.63.4 — LAST-RESORT FALLBACK, BAKED INTO THIS FILE.
//
// FlutLab drops `key.properties`. It MIGHT also drop `signing.properties` —
// unknown, and the owner is on a free plan where the signed-build flow is rate
// limited, so guessing costs a build he cannot spare. `build.gradle.kts` and
// `android/app/innocent.jks` both demonstrably survive the import (both are
// visible in the Explorer), so putting the credentials here makes release
// signing work no matter what happens to the properties file.
//
// v1.64.7 — THE PASSWORDS ARE GONE FROM THIS FILE, AND THE REASON MATTERS.
//
// They were here because FlutLab's import can drop a properties file, and a
// build that silently loses its signing config produces an APK that no
// existing install can update. While this project only ever built inside
// FlutLab, that trade was worth making: the zip carried `innocent.jks` anyway,
// so the file added no exposure that the zip didn't already have.
//
// It stops being worth making the moment this tree lives in git. This file is
// COMMITTED; `signing.properties` is not. A password that reaches git history
// cannot be deleted later — rewriting history does not remove it from forks,
// clones, caches or any CI log that ever printed the file. So the constants
// are replaced by environment variables, which CI supplies from encrypted
// secrets and which never touch the repository.
//
// Resolution order, first match wins:
//
//   1. android/signing.properties  — FlutLab and any local build
//   2. android/key.properties      — the Flutter convention
//   3. environment variables       — CI, where secrets arrive as env vars
//
// With none of the three, `releaseKeystoreFile` stays null, the release
// variant gets NO signing config, and the warning below fires. That is the
// correct failure: an APK that will not install, rather than one silently
// signed with the wrong key and stranding every existing install forever.
val fallbackStoreFile = System.getenv("INNOCENT_STORE_FILE") ?: ""
val fallbackStorePassword = System.getenv("INNOCENT_STORE_PASSWORD") ?: ""
val fallbackKeyAlias = System.getenv("INNOCENT_KEY_ALIAS") ?: ""
val fallbackKeyPassword = System.getenv("INNOCENT_KEY_PASSWORD") ?: ""

val keystoreProperties = Properties()

val keystorePropertiesFile = listOf(
    rootProject.file("signing.properties"),
    rootProject.file("key.properties"),
).firstOrNull { it.exists() }

// Seed the fallback FIRST, then let a real properties file overwrite it. That
// ordering means a properties file always wins when one exists, and the build
// still signs correctly when none does.
keystoreProperties.setProperty("storeFile", fallbackStoreFile)
keystoreProperties.setProperty("storePassword", fallbackStorePassword)
keystoreProperties.setProperty("keyAlias", fallbackKeyAlias)
keystoreProperties.setProperty("keyPassword", fallbackKeyPassword)

// file(...) here resolves against THIS module's directory, android/app — so a
// bare `storeFile=innocent.jks` means android/app/innocent.jks. An absolute
// path works too. Null when anything is missing; every decision below is made
// from this one value.
val releaseKeystoreFile: File? = run {
    keystorePropertiesFile?.inputStream()?.use { keystoreProperties.load(it) }
    val declared = keystoreProperties.getProperty("storeFile")
    val resolved = if (declared.isNullOrBlank()) null else file(declared)
    if (resolved != null && resolved.exists()) resolved else null
}

logger.lifecycle(
    "Innocent signing: " + (keystorePropertiesFile?.name ?: "environment variables") +
    " -> " + (releaseKeystoreFile?.name ?: "NO KEYSTORE")
)

// DEVICE LAB ONLY (.github/workflows/device-lab.yml): INNOCENT_LAB_ABI=x86_64
// builds the same app for an x86_64 emulator, which cannot run the arm64
// libraries through Android's ARM translation (it dies on a SIMD instruction
// the translator does not know). Such an APK is debug-signed, whatever key
// is present, so it can never be mistaken for — or installed over — a
// release. Unset, nothing below changes by a byte.
val labAbi: String? = System.getenv("INNOCENT_LAB_ABI")?.takeIf { it.isNotBlank() }

if (releaseKeystoreFile == null) {
    logger.warn("*****************************************************************")
    logger.warn("* Innocent: NO RELEASE KEYSTORE FOUND.                          *")
    logger.warn("* Looked for android/signing.properties, then key.properties.   *")
    logger.warn("*                                                               *")
    logger.warn("* The release variant is deliberately left WITHOUT a signing     *")
    logger.warn("* config. Two things can happen and both are safe:              *")
    logger.warn("*   - the host injects its own signing and the APK is signed     *")
    logger.warn("*     with whatever key the host was told to use; or             *")
    logger.warn("*   - nothing does, and the APK comes out UNSIGNED and will      *")
    logger.warn("*     refuse to install.                                         *")
    logger.warn("*                                                               *")
    logger.warn("* It used to fall back to the DEBUG key here. That was worse:    *")
    logger.warn("* the APK installed, ran perfectly, and was signed with a key    *")
    logger.warn("* generated fresh on the build machine — undetectable by eye.    *")
    logger.warn("* VERIFY EVERY RELEASE APK'S CERTIFICATE BEFORE SHARING IT.      *")
    logger.warn("*****************************************************************")
}

android {
    namespace = "com.innocent.media"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    // DEVICE LAB ONLY: a lab APK also answers Test Lab's game-loop launch
    // (src/lab/AndroidManifest.xml). A release build never sees that file.
    if (labAbi != null) {
        sourceSets.getByName("release").manifest.srcFile("src/lab/AndroidManifest.xml")
    }

    // v1.64.13 — 11 -> 17, ahead of google_sign_in needing it.
    //
    // NOT REQUIRED BY THE BUILD AS IT RESOLVES TODAY, and saying otherwise
    // would be the kind of claim this file exists to stop. The exact
    // versions, checked rather than assumed:
    //
    //     google_sign_in_android 7.2.1   Java 11   needs Flutter >=3.29.0
    //     google_sign_in_android 7.2.2   Java 17   needs Flutter >=3.35.0
    //     google_sign_in_android 7.2.17  Java 17   needs Flutter >=3.44.0
    //
    // CI pins Flutter 3.32.8, so pub correctly holds at 7.2.1, which targets
    // 11 and would have built against 11. The bump is for the next step, not
    // this one: the moment that Flutter pin moves past 3.35 — a routine bump,
    // and one this project has already made twice — pub takes 7.2.2+ and a
    // module targeting 11 can no longer read its class files:
    //
    //     class file has wrong version 61.0, should be 55.0
    //
    // with the Kotlin half reporting an "Inconsistent JVM-target
    // compatibility" error naming 11 and 17. Neither is fixable from the Dart
    // side. Paying for it now, against a green build, is cheaper than paying
    // for it inside an unrelated Flutter upgrade where it looks like the
    // upgrade broke.
    //
    // NOTHING ELSE MOVES. The JDK that RUNS Gradle was already 17 — the CI
    // workflow sets it up and says so, and AGP 8.7 refuses to start on
    // anything lower. This is the bytecode target catching up with a
    // toolchain that was already there, not a toolchain upgrade. Java 17 has
    // been a supported desugaring target since AGP 8.0, minSdk 24 is
    // unchanged, and Kotlin 2.1.0 has emitted 17 for several major versions.
    //
    // The 11 was never a decision. It is the number Flutter's template wrote
    // and nothing since had a reason to touch.
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Local Network (net/): Apache Commons Net times every FTP data
        // connection with java.time.Duration, which Android only has from
        // API 26. Desugaring supplies it on 24–25 (Android 7), the same way
        // Material Files ships the same library.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // The app's identity on the device, and the string Android developer
        // verification registers.
        //
        // 30 Aug 2026: renamed from com.example.mx_clone, together with
        // `namespace` above and every Kotlin/AIDL package declaration, so the
        // whole project speaks one name. `com.example.*` is reserved for
        // samples and is rejected by Play.
        //
        // Changing this makes a NEW app as far as Android is concerned: any
        // old com.example.mx_clone install stays put beside it with its own
        // data, and must be uninstalled by hand. Safe to do now, and only now,
        // because the app has no users.
        applicationId = "com.innocent.media"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Phase 33 / v0.60.0: FlutLab build-OOM fix — pack ONLY arm64-v8a.
        // Bundling 2+ ABIs of libmpv (~80 MB each) at once peaks the ~4 GB CI
        // container's memory during native packaging and kills the Gradle
        // daemon ("the daemon has disappeared"). Even with R8 disabled, the
        // .so packaging peak for two ABIs was over the line, so we're back to
        // a single ABI.
        //
        // Compatibility: arm64-v8a covers virtually every phone from ~2019+.
        // 32-bit-only budget devices (a few older itel / Tecno / Infinix
        // models) won't be able to install this arm64 APK — if that matters,
        // build a separate armeabi-v7a APK on its own so its packaging peak
        // doesn't stack on top of arm64:
        //   flutter build apk --release --target-platform android-arm
        // x86 / x86_64 (emulator-only) stay excluded.
        ndk {
            // CLEAR FIRST. `+=` only ever ADDS: with Flutter's Gradle plugin
            // populating this set for a fat APK, adding "arm64-v8a" to a set
            // that already contains it restricted nothing, and the build went
            // on packing all four ABIs while this block claimed otherwise.
            // The build log is the proof — merged_native_libs held arm64-v8a,
            // armeabi-v7a, x86 AND x86_64.
            abiFilters.clear()
            abiFilters.add(labAbi ?: "arm64-v8a")
        }
    }

    // Phase 33: Split APK by ABI for users who want smaller installers.
    // (Doesn't run when ndk.abiFilters limits to one — left here for reference.)
    splits {
        abi {
            isEnable = false
        }
    }

    // The "release" config is only CREATED when a usable keystore was found.
    // Creating it with a null storeFile would fail the build at packaging time
    // with an error that says nothing useful — the warning above says it once,
    // clearly, at the start of the log instead.
    signingConfigs {
        if (releaseKeystoreFile != null) {
            create("release") {
                storeFile = releaseKeystoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                // Almost always the same as the store password. Falling back
                // saves a build from the single most common typo in this file.
                keyPassword = keystoreProperties.getProperty("keyPassword")
                    ?: keystoreProperties.getProperty("storePassword")
            }
        }
    }

    // Phase 33: Cut R8/proguard out of release so the build doesn't spend
    // huge memory shrinking media_kit's reflection-heavy code. The APK is
    // slightly larger but built reliably on a 4 GB CI container.
    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            // v1.63.3: assign ONLY when we have a real keystore. Assigning
            // `debug` here (the old behaviour) also OVERRODE any signing the
            // host tried to inject, which is why FlutLab's "Generate Signed
            // APK" still produced a debug-signed APK. Leaving it unset lets
            // that injection through, and otherwise yields an unsigned APK —
            // a loud failure instead of a silent wrong-key success.
            if (labAbi != null) {
                signingConfig = signingConfigs.getByName("debug")
            } else if (releaseKeystoreFile != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    // Phase 33: Skip lint during release — saves ~30s and ~200MB.
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    // v0.99 Downloader — CRITICAL: this was `false`.
    //
    // youtubedl-android does not LOAD its native libs with System.loadLibrary;
    // it EXECS them as real command-line binaries (python, yt-dlp, ffmpeg,
    // aria2c are shipped as lib*.so / lib*.zip.so purely so the installer will
    // carry them). A process can only be exec'd from a real file on disk, so
    // those .so files must be extracted out of the APK at install time.
    //
    // `useLegacyPackaging = false` compiles extractNativeLibs="false" into the
    // merged manifest, which leaves the libs INSIDE the APK — the app installs
    // and starts fine, then every engine call dies at runtime with
    // "python: not found" / UnsatisfiedLink-style failures. That is a silent
    // trap: nothing fails at build time.
    //
    // Setting it to `true` (which also emits extractNativeLibs="true") is a
    // hard requirement of the library, documented in its README. Cost: the
    // install footprint grows because the libs are unpacked; the APK itself
    // gets slightly SMALLER because legacy packaging compresses them.
    // libmpv is unaffected either way (it is loaded, not exec'd, and works
    // from an extracted copy just the same).
    packaging {
        jniLibs {
            useLegacyPackaging = true

            // STOP STRIPPING THE PAYLOADS THAT ARE NOT CODE.
            //
            // libpython.zip.so, libffmpeg.zip.so and libaria2c.zip.so are ZIP
            // archives wearing a .so name so the installer will carry them —
            // the same trick that makes useLegacyPackaging mandatory above.
            // llvm-strip is an ELF tool, so it opens each one, fails to
            // recognise it and logs an error, once per file per ABI. Harmless
            // and pure waste. Naming them here skips the attempt.
            //
            // Matched on the .zip.so suffix only: the REAL binaries next to
            // them (libpython.so, libffmpeg.so, libqjs.so, libaria2c.so) are
            // genuine ELF and should still be stripped.
            keepDebugSymbols.add("**/*.zip.so")

            // x86 and x86_64 are emulator-only for this audience and nothing
            // ships on them. Excluded here as well as in abiFilters because
            // this rule applies at packaging time and cannot be undone by a
            // plugin that reconfigures the ABI set later.
            //
            // armeabi-v7a is deliberately NOT excluded here. The comment in
            // defaultConfig documents building it separately with
            // `--target-platform android-arm`, and an exclude at this level
            // would silently produce an APK with no native libraries at all —
            // exactly the kind of trap that block already warns about.
            if (labAbi != "x86") excludes.add("lib/x86/**")
            if (labAbi != "x86_64") excludes.add("lib/x86_64/**")
        }
        // The Local Network jars (smbj, sshj, jcifs-ng, Commons Net/IO) each
        // carry their own licence files and Java-9 module descriptors under
        // the same names; none of it is read at run time.
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/INDEX.LIST",
                "**/module-info.class",
                "META-INF/versions/9/OSGI-INF/MANIFEST.MF",
            )
        }
    }
}

flutter {
    source = "../.."
}

// Phase 64 / Milestone 0: embedded wireless-ADB client library (no binary
// needed — pure-Java ADB protocol incl. Android 11+ pairing/TLS). This step
// adds the dependency WITHOUT any code that uses it yet: if the release build
// succeeds, FlutLab could fetch it from JitPack and it's compatible with our
// Kotlin 2.1.0 / minSdk 24 setup, so the real cascade can be built on top.
dependencies {
    // The ONE API that can point a WebView at a proxy. There is no platform
    // equivalent — every other route is a reflection hack that stopped working
    // years ago — and without it the in-app browser cannot use the bypass that
    // makes the blocked sites reachable with no VPN. Small, stable, and from
    // AndroidX rather than a third party, which is the bar this build holds
    // dependencies to after what heavier ones have cost it.
    implementation("androidx.webkit:webkit:1.12.1")

    implementation("com.github.MuntashirAkon:libadb-android:3.1.1")
    // libadb-android already bundles bcprov (jdk15to18:1.81) transitively; we
    // only add bcpkix (the X509 cert-builder classes) in the SAME variant and
    // version so the two share one bcprov and don't collide.
    implementation("org.bouncycastle:bcpkix-jdk15to18:1.81")
    // Lifts Android 9+ hidden-API restrictions so libadb's TLS handshake can
    // reach the platform Conscrypt provider (see InnocentApplication).
    implementation("org.lsposed.hiddenapibypass:hiddenapibypass:4.3")

    // ── Local Network (Me → Local Network; net/, tested in tool/netlab) ──
    // The set Android's open-source file managers settled on (Material
    // Files): smbj for SMB 2/3, jcifs-ng for share lists and SMB1-only
    // boxes, Apache Commons Net for FTP/FTPS, sshj for SFTP. All share the
    // ONE BouncyCastle above (bcprov via libadb-android, bcpkix here), so
    // their own BC pins are excluded.
    // smbj stays at 0.11.5: 0.12.0 broke anonymous / guest sign-in
    // (hierynomus/smbj#792), and "Connect Anonymously" is MX's default.
    implementation("com.hierynomus:smbj:0.11.5") {
        exclude(group = "org.bouncycastle")
    }
    implementation("eu.agno3.jcifs:jcifs-ng:2.1.10") {
        exclude(group = "org.bouncycastle")
    }
    implementation("com.hierynomus:sshj:0.40.0") {
        exclude(group = "org.bouncycastle")
    }
    implementation("commons-net:commons-net:3.13.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // v0.99 Downloader engine. youtubedl-android bundles the yt-dlp binary plus
    // a Python 3.8 runtime; `ffmpeg` supplies the muxer that joins DASH
    // video-only + audio-only streams into one mp4 (and does MP3 extraction);
    // `aria2c` is the multi-connection external downloader.
    //
    // All three come from Maven Central (no JitPack needed) and are pure
    // Java/Kotlin + prebuilt .so — nothing to compile, no build_runner, so the
    // FlutLab copy-paste workflow is unaffected.
    //
    // BUILD-MEMORY NOTE: this module packs arm64-v8a ONLY because two ABIs of
    // libmpv already peaked FlutLab's ~4 GB container during native packaging.
    // These three add roughly 55-60 MB of arm64 binaries on top. If the build
    // now dies with "the daemon has disappeared" / OOM, remove them in this
    // order and rebuild: (1) aria2c — downloads fall back to yt-dlp's own
    // downloader, only speed is lost; (2) ffmpeg — then also drop the
    // --merge-output-format option and cap the quality list to progressive
    // (audio+video) formats, since without a muxer 720p+ cannot be joined.
    // The library module itself is not optional.
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:aria2c:0.18.1")
}
