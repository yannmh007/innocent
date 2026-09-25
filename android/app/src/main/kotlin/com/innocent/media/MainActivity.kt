package com.innocent.media

import android.app.PictureInPictureParams
import android.app.PendingIntent
import android.app.RemoteAction
import android.app.AppOpsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.net.wifi.WifiManager
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.graphics.Rect
import android.graphics.drawable.Icon
import android.media.MediaScannerConnection
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import android.view.WindowManager
import java.io.File
import java.io.FileOutputStream
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.audiofx.Equalizer
import android.media.audiofx.BassBoost
import android.media.audiofx.Virtualizer
import android.media.audiofx.PresetReverb
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.DocumentsContract
import android.provider.Settings
import android.database.Cursor
import android.util.Rational
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import kotlin.concurrent.thread

/// The base class carries two requirements at once.
///
/// FRAGMENT ACTIVITY (older fix): the local_auth plugin presents a
/// BiometricPrompt, and that API needs a FragmentActivity — a plain
/// FlutterActivity is not one.
///
/// AUDIO SERVICE (v1.61): audio_service requires the activity to hand back
/// ITS cached FlutterEngine rather than creating a private one, and the
/// documented way to inherit that behaviour is to extend
/// AudioServiceActivity — or, for a FragmentActivity, this class. Without it
/// `AudioService.init()` fails with "The Activity class declared in your
/// AndroidManifest.xml is wrong or has not provided the correct FlutterEngine",
/// main.dart swallows the exception, and the whole music side loses its
/// notification, its lock-screen controls, its Bluetooth buttons and its own
/// foreground service — which is exactly what was happening.
///
/// AudioServiceFragmentActivity extends FlutterFragmentActivity, so the
/// biometric requirement above is still satisfied.
///
/// ONE REAL CONSEQUENCE, worth knowing before blaming it for something else:
/// the Flutter engine is now CACHED and shared with the audio service, so the
/// Dart isolate survives the Activity being destroyed instead of dying with
/// it. That is the point — it is what lets music keep playing — but it means
/// state now persists across a close-and-reopen where it used to reset.
/// To revert, change this one line back to `FlutterFragmentActivity()` and
/// re-add its import.
class MainActivity : AudioServiceFragmentActivity() {

    companion object {
        private const val PIP_CHANNEL = "mx_clone/pip"
        // v1.61: read-only crash / environment reporting. See Diagnostics.kt.
        private const val DIAGNOSTICS_CHANNEL = "mx_clone/diagnostics"
        // PiP window custom controls (play/pause). The action clicks come
        // back as broadcasts we translate into method-channel calls so the
        // Flutter player can toggle playback while the video floats over
        // other apps.
        private const val ACTION_PIP_CONTROL = "com.innocent.media.PIP_CONTROL"
        // v1.51: transport-control clicks coming back from the background
        // playback notification. Same-app broadcast, never exported.
        const val ACTION_PLAYBACK_CONTROL = "com.innocent.media.PLAYBACK_CONTROL"
        const val EXTRA_PLAYBACK_CONTROL = "playback_control"
        const val PLAYBACK_CONTROL_PLAY_PAUSE = "play_pause"
        const val PLAYBACK_CONTROL_STOP = "stop"
        // v1.55: a MediaSession sends distinct play/pause, never a toggle —
        // the system knows which state it is asking for, and collapsing the
        // two into one toggle inverts playback whenever the two disagree.
        const val PLAYBACK_CONTROL_PLAY = "play"
        const val PLAYBACK_CONTROL_PAUSE = "pause"
        const val PLAYBACK_CONTROL_NEXT = "next"
        const val PLAYBACK_CONTROL_PREVIOUS = "previous"
        const val PLAYBACK_CONTROL_SEEK = "seek"
        const val EXTRA_PLAYBACK_POSITION = "positionMs"
        private const val EXTRA_PIP_CONTROL = "control"
        private const val CONTROL_PLAY_PAUSE = "play_pause"
        private const val ACTION_PIP_PLAY_PAUSE_CODE = 1001
        private const val EQ_CHANNEL = "mx_clone/equalizer"
        private const val KEYS_CHANNEL = "mx_clone/keys"
        private const val THUMB_CHANNEL = "mx_clone/thumbnail"
        private const val INTENT_CHANNEL = "mx_clone/intent"
        // Phase 63: Storage Access Framework — lets the user grant per-folder
        // access (e.g. Android/data) that neither MediaStore nor All-Files
        // reaches on Android 11+, then enumerate/play video files inside via
        // persisted content:// tree URIs.
        private const val SAF_CHANNEL = "mx_clone/saf"
        private const val SAF_TREE_REQUEST = 0x5AF1
        // Phase 45: lets Flutter start/stop the background playback
        // foreground service that keeps audio alive when the app is in
        // background or the screen is off.
        private const val PLAYBACK_CHANNEL = "mx_clone/playback"
        // Phase 45: audio focus management — when the user gets a phone
        // call or another app starts playing, we get a callback so the
        // player can pause cleanly. When the interruption ends we can
        // resume if appropriate.
        private const val AUDIO_FOCUS_CHANNEL = "mx_clone/audio_focus"
        // Music home-screen widget: Flutter pushes now-playing text + play
        // state here; we persist it and force the widget to re-render.
        private const val MUSIC_WIDGET_CHANNEL = "mx_clone/music_widget"
        // Foreground service that keeps a Wi-Fi file transfer alive when the
        // app is backgrounded, and shows transfer progress in the shade.
        private const val TRANSFER_SERVICE_CHANNEL = "mx_clone/transfer_service"
        private const val OFFLINE_SERVICE_CHANNEL = "mx_clone/offline_service"
        private const val NET_INFO_CHANNEL = "mx_clone/net_info"
        // The cipher a downloaded film is kept under. See MediaCrypto for why
        // CTR and why the key is wrapped rather than used directly.
        private const val MEDIA_CRYPTO_CHANNEL = "mx_clone/media_crypto"
        // v0.50 (Zapya-style app sharing): the file picker's Apps tab asks
        // for the installed user apps so their APKs can be sent over the
        // LAN transfer just like any other file.
        private const val APPS_CHANNEL = "mx_clone/apps"
        // v0.51 privacy: after we move a file into the vault (and delete
        // the original with dart:io), the Android MediaStore can still
        // hold a stale row — so the video's title/thumbnail stays visible
        // in Gallery, Google Photos, other players, etc. until a rescan.
        // This channel triggers MediaScannerConnection on the exact paths
        // so the index is purged immediately.
        private const val MEDIA_SCAN_CHANNEL = "mx_clone/media_scan"
        private const val INTRUDER_CAM_CHANNEL = "mx_clone/intruder_cam"
        // v1.49 Private Folder: FLAG_SECURE control. A PIN on the door means
        // nothing if the OS screenshots the room — Android puts a live
        // snapshot of the top activity in the recents switcher, screen
        // recorders capture it, and on some OEM builds a triple-tap
        // "smart capture" fires without any app involvement. FLAG_SECURE is
        // the only switch that blocks all three at once, and it must be set
        // on the Window, which only native code can reach.
        private const val SECURE_SCREEN_CHANNEL = "mx_clone/secure_screen"
        // v1.46: direct phone-to-phone Wi-Fi link for the Transfer tab.
        private const val TURBO_CHANNEL = "mx_clone/turbo"
    }

    private var pipChannel: MethodChannel? = null
    // Receiver for the PiP window's play/pause action clicks. Registered
    // only while actually in PiP, unregistered on exit, so we never leak it.
    private var pipControlReceiver: BroadcastReceiver? = null
    private var eqChannel: MethodChannel? = null
    private var equalizer: Equalizer? = null
    // Phase 45 (audit): additional Android AudioFx instances for MX
    // Player parity. Each is lazily constructed in initEqualizer().
    private var bassBoost: BassBoost? = null
    private var virtualizer: Virtualizer? = null
    private var presetReverb: PresetReverb? = null
    private var keysChannel: MethodChannel? = null
    private var thumbChannel: MethodChannel? = null
    private var intentChannel: MethodChannel? = null

    /** Link shared into a cold start, held for the first getInitialSharedLink. */
    private var pendingSharedLink: String? = null

    /**
     * Set when the Activity was started by tapping the update notification on
     * a COLD start, held for the first getInitialOpenAppUpdate. Same one-shot
     * contract as [pendingSharedLink]: read once, cleared, so a later restart
     * cannot replay it and drop the user on the update screen out of nowhere.
     */
    private var pendingOpenAppUpdate: Boolean = false
    private var safChannel: MethodChannel? = null
    // Holds the Flutter result across the ACTION_OPEN_DOCUMENT_TREE round-trip
    // (onActivityResult replies to it). Nullable because there's only ever one
    // in flight and it's cleared as soon as the picker returns.
    private var pendingSafResult: MethodChannel.Result? = null
    private var playbackChannel: MethodChannel? = null

    /**
     * v1.51 — THE screen-off fix.
     *
     * `AppLifecycleState.inactive` is ambiguous on Android: it covers a real
     * screen-off, but equally a pulled notification shade or a permission
     * dialog. Flutter gives us no way to tell them apart, so the player used
     * to guess with a 1.2 s timer — and 1.2 s is far too late. The instant the
     * display goes off, Flutter stops rastering, nothing consumes the video
     * SurfaceTexture any more, and libmpv blocks inside dequeueBuffer with a
     * full buffer queue. A core that is already blocked cannot process the
     * property write that would have released it, so the audio buffer drains
     * and the sound dies a couple of seconds later.
     *
     * ACTION_SCREEN_OFF is broadcast by the system the moment the display goes
     * off — earlier than onStop, and unambiguous: it is never sent for a shade
     * or a dialog. Forwarding it to Dart lets the player detach the video
     * track BEFORE the queue can fill, which is the whole difference between
     * background audio working and not working.
     */
    private var screenStateReceiver: BroadcastReceiver? = null

    /** Play/pause + stop clicks from the background-playback notification. */
    private var playbackControlReceiver: BroadcastReceiver? = null
    private var audioFocusChannel: MethodChannel? = null
    private var musicWidgetChannel: MethodChannel? = null
    private var transferServiceChannel: MethodChannel? = null
    private var offlineServiceChannel: MethodChannel? = null
    private var netInfoChannel: MethodChannel? = null
    private var mediaCryptoChannel: MethodChannel? = null
    // Held only while the Transfer tab is scanning for nearby devices.
    // Without it Android filters out the UDP broadcast frames discovery
    // depends on. Released in onDestroy so it can never leak.
    private var multicastLock: WifiManager.MulticastLock? = null
    private var turboChannel: MethodChannel? = null
    private var appsChannel: MethodChannel? = null
    private var mediaScanChannel: MethodChannel? = null
    private var intruderCamChannel: MethodChannel? = null
    private var secureScreenChannel: MethodChannel? = null
    // Mirrors the current FLAG_SECURE state so we only touch the Window when
    // it actually changes. Re-applying the flag forces a surface update on
    // some devices, which shows up as a visible flicker mid-scroll.
    private var secureScreenOn: Boolean = false
    // Phase 45: audio focus state. The request is kept so we can
    // abandon it cleanly when the user pauses or leaves the player.
    @Suppress("DEPRECATION")
    private var audioFocusRequest: AudioFocusRequest? = null
    private var legacyAudioFocusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var captureVolumeKeys: Boolean = false
    private var pendingIntentUri: String? = null
    private var pendingIntentTitle: String? = null
    // Phase 45: AudioManager broadcasts ACTION_AUDIO_BECOMING_NOISY when
    // the user unplugs headphones / disconnects a Bluetooth headset.
    // Best-practice in Android media apps is to pause playback then —
    // otherwise the audio suddenly blasts through the speaker, which is
    // both jarring and (on phones) wakes everyone else up. We forward
    // the event to Flutter so the player can decide whether to pause.
    private var becomingNoisyReceiver: BroadcastReceiver? = null
    // v0.89: stored so both the method handler and the pairing-result receiver
    // can reach the ADB channel (the pairing service broadcasts its result back
    // and we forward it to Flutter as `onPairResult`).
    private var adbChannel: MethodChannel? = null
    private var adbPairResultReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // v1.61 — the diagnostics channel. Read-only: it hands Dart the
        // process-exit history the system keeps for us plus the device
        // environment, so a crash can be looked at from the phone instead of
        // guessed at. Registered first so it is available even if a later
        // channel setup throws.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DIAGNOSTICS_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceInfo" -> result.success(
                    Diagnostics.deviceInfo(applicationContext)
                )
                "exitReasons" -> result.success(
                    Diagnostics.exitReasons(
                        applicationContext,
                        call.argument<Int>("max") ?: 10
                    )
                )
                else -> result.notImplemented()
            }
        }

        pipChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PIP_CHANNEL
        )
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPip" -> {
                    val w = call.argument<Int>("width") ?: 16
                    val h = call.argument<Int>("height") ?: 9
                    // Optional on-screen video bounds for a smooth morph
                    // animation into the PiP window.
                    val l = call.argument<Int>("left")
                    val t = call.argument<Int>("top")
                    val r = call.argument<Int>("right")
                    val b = call.argument<Int>("bottom")
                    val rect = if (l != null && t != null && r != null && b != null) {
                        Rect(l, t, r, b)
                    } else null
                    pipIsPlaying = call.argument<Boolean>("isPlaying") ?: true
                    val ok = enterPip(w, h, rect)
                    result.success(ok)
                }
                "setPipPlaying" -> {
                    // Keep the PiP play/pause icon in sync with real state.
                    updatePipParams(call.argument<Boolean>("isPlaying") ?: true)
                    result.success(true)
                }
                "isPipSupported" -> result.success(isPipSupported())
                "isPipAllowed" -> result.success(isPipAllowed())
                "openPipSettings" -> {
                    openPipSettings()
                    result.success(true)
                }
                "setAutoEnterPip" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    val w = call.argument<Int>("width") ?: 16
                    val h = call.argument<Int>("height") ?: 9
                    setAutoEnterPip(enable, w, h)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // v0.50: list installed user apps (name / package / apk path /
        // size / launcher icon as PNG bytes). PackageManager iteration and
        // icon rasterising can take a moment on app-heavy phones, so the
        // work runs off the main thread and posts the result back.
        appsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APPS_CHANNEL
        )
        appsChannel?.setMethodCallHandler { call, result ->
            if (call.method == "listApps") {
                thread {
                    try {
                        val pm = packageManager
                        val out = ArrayList<Map<String, Any?>>()
                        @Suppress("DEPRECATION")
                        val installed = pm.getInstalledApplications(0)
                        for (ai in installed) {
                            if (ai.flags and ApplicationInfo.FLAG_SYSTEM != 0) continue
                            val src = ai.sourceDir ?: continue
                            val f = java.io.File(src)
                            if (!f.exists()) continue
                            var iconBytes: ByteArray? = null
                            try {
                                val d = pm.getApplicationIcon(ai)
                                val bmp = Bitmap.createBitmap(
                                    96, 96, Bitmap.Config.ARGB_8888)
                                val c = Canvas(bmp)
                                d.setBounds(0, 0, 96, 96)
                                d.draw(c)
                                val bos = ByteArrayOutputStream()
                                bmp.compress(Bitmap.CompressFormat.PNG, 90, bos)
                                iconBytes = bos.toByteArray()
                                bmp.recycle()
                            } catch (_: Throwable) {
                                // Icon is cosmetic — never fail the list.
                            }
                            out.add(
                                mapOf(
                                    "name" to pm.getApplicationLabel(ai).toString(),
                                    "package" to ai.packageName,
                                    "apkPath" to src,
                                    "size" to f.length(),
                                    "icon" to iconBytes
                                )
                            )
                        }
                        out.sortBy { (it["name"] as String).lowercase() }
                        runOnUiThread { result.success(out) }
                    } catch (t: Throwable) {
                        runOnUiThread {
                            result.error("APPS", t.message, null)
                        }
                    }
                }
            } else {
                result.notImplemented()
            }
        }

        // Rescan given absolute paths so the MediaStore drops rows for
        // files we've moved into the vault (or adds rows for files we've
        // restored back out). Fire-and-forget; the scan is async.
        mediaScanChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_SCAN_CHANNEL
        )
        mediaScanChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "scan" -> {
                    val paths = call.argument<List<String>>("paths")
                    if (paths != null && paths.isNotEmpty()) {
                        MediaScannerConnection.scanFile(
                            applicationContext,
                            paths.toTypedArray(),
                            null,
                            null
                        )
                    }
                    result.success(true)
                }
                // Free space on the volume that holds [dir]. dart:io has no
                // API for this, and a Wi-Fi transfer that fills the disk on
                // the last file of a 200-file batch is far worse than one
                // that refuses up front. Returns -1 when it can't be read.
                "freeBytes" -> {
                    var free = -1L
                    try {
                        val dir = call.argument<String>("dir")
                        // The folder may not exist yet, so measure the nearest
                        // parent that does — same filesystem, same answer.
                        var probe: java.io.File? =
                            if (dir.isNullOrBlank()) null else java.io.File(dir)
                        while (probe != null && !probe.exists()) {
                            probe = probe.parentFile
                        }
                        if (probe != null) {
                            free = android.os.StatFs(probe.absolutePath).availableBytes
                        }
                    } catch (_: Throwable) {
                    }
                    result.success(free)
                }
                else -> result.notImplemented()
            }
        }

        // Silent front-camera capture for the anti-theft "intruder selfie".
        // Given a target file path, snaps ONE frame from the front camera
        // with no preview/shutter sound and writes a JPEG there. Returns
        // the path on success or null on ANY failure (no camera, no
        // permission, hardware busy) so the Dart side degrades gracefully
        // and still records the failed-unlock timestamp.
        intruderCamChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INTRUDER_CAM_CHANNEL
        )
        intruderCamChannel?.setMethodCallHandler { call, result ->
            if (call.method == "capture") {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.success(null)
                } else {
                    captureIntruderSelfie(path, result)
                }
            } else {
                result.notImplemented()
            }
        }

        secureScreenChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SECURE_SCREEN_CHANNEL
        )
        secureScreenChannel?.setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
                val on = call.argument<Boolean>("secure") ?: false
                // Window flags are UI-thread-only. The Dart side calls this
                // from initState/dispose, which arrive on the platform thread
                // already, but posting is free and removes the whole class of
                // "worked on my phone" threading bugs.
                runOnUiThread {
                    try {
                        if (on != secureScreenOn) {
                            if (on) {
                                window.setFlags(
                                    WindowManager.LayoutParams.FLAG_SECURE,
                                    WindowManager.LayoutParams.FLAG_SECURE
                                )
                            } else {
                                window.clearFlags(
                                    WindowManager.LayoutParams.FLAG_SECURE
                                )
                            }
                            secureScreenOn = on
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        // Never let a window-flag failure break the vault UI.
                        result.success(false)
                    }
                }
            } else {
                result.notImplemented()
            }
        }

        musicWidgetChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MUSIC_WIDGET_CHANNEL
        )
        musicWidgetChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    try {
                        val editor = getSharedPreferences(
                            MusicWidgetProvider.PREFS, Context.MODE_PRIVATE
                        ).edit()
                        if (call.hasArgument("title")) {
                            editor.putString("music_title", call.argument<String>("title"))
                        }
                        if (call.hasArgument("artist")) {
                            editor.putString("music_artist", call.argument<String>("artist"))
                        }
                        if (call.hasArgument("playing")) {
                            editor.putBoolean(
                                "music_playing",
                                call.argument<Boolean>("playing") ?: false
                            )
                        }
                        editor.commit()
                        MusicWidgetProvider.render(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        eqChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EQ_CHANNEL
        )
        eqChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "generateAudioSessionId" -> {
                    // Create a fresh audio session id that libmpv's AudioTrack
                    // output can be bound to (via the mpv audiotrack-session-id
                    // option). Attaching the Equalizer to THIS id — instead of
                    // the global mix (session 0), which modern Android no longer
                    // routes app playback through — is what makes the EQ
                    // actually affect the video's sound.
                    try {
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val id = am.generateAudioSessionId()
                        result.success(if (id == AudioManager.ERROR) 0 else id)
                    } catch (e: Exception) {
                        result.success(0)
                    }
                }
                "initialize" -> {
                    val sessionId = call.argument<Int>("sessionId") ?: 0
                    result.success(initEqualizer(sessionId))
                }
                "release" -> {
                    releaseEqualizer()
                    result.success(true)
                }
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        equalizer?.enabled = enabled
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "setBandLevel" -> {
                    val band = call.argument<Int>("band") ?: 0
                    val level = call.argument<Int>("level") ?: 0
                    try {
                        equalizer?.setBandLevel(band.toShort(), level.toShort())
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "getBandLevelRange" -> {
                    val range = equalizer?.bandLevelRange
                    if (range != null) {
                        result.success(listOf(range[0].toInt(), range[1].toInt()))
                    } else {
                        result.success(listOf(-1500, 1500))
                    }
                }
                "getNumberOfBands" -> {
                    result.success(equalizer?.numberOfBands?.toInt() ?: 5)
                }
                "getCenterFreq" -> {
                    val band = call.argument<Int>("band") ?: 0
                    val freq = equalizer?.getCenterFreq(band.toShort()) ?: 0
                    result.success(freq)
                }
                "usePreset" -> {
                    val preset = call.argument<Int>("preset") ?: 0
                    try {
                        equalizer?.usePreset(preset.toShort())
                        val bands = equalizer?.numberOfBands?.toInt() ?: 5
                        val levels = mutableListOf<Int>()
                        for (i in 0 until bands) {
                            levels.add(equalizer?.getBandLevel(i.toShort())?.toInt() ?: 0)
                        }
                        result.success(levels)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "getPresets" -> {
                    val count = equalizer?.numberOfPresets?.toInt() ?: 0
                    val names = mutableListOf<String>()
                    for (i in 0 until count) {
                        names.add(equalizer?.getPresetName(i.toShort()) ?: "Preset $i")
                    }
                    result.success(names)
                }
                // Phase 45 (audit): Bass Boost / Virtualizer / Reverb
                // handlers. Each effect is created lazily on first
                // use (constructed in initEqualizer) and toggled here.
                "setBassBoostEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        bassBoost?.enabled = enabled
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "setBassBoostStrength" -> {
                    val strength = call.argument<Int>("strength") ?: 0
                    try {
                        bassBoost?.setStrength(strength.toShort())
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "setVirtualizerEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    try {
                        virtualizer?.enabled = enabled
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "setVirtualizerStrength" -> {
                    val strength = call.argument<Int>("strength") ?: 0
                    try {
                        virtualizer?.setStrength(strength.toShort())
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "setReverbPreset" -> {
                    val preset = call.argument<Int>("preset") ?: 0
                    try {
                        presetReverb?.preset = preset.toShort()
                        presetReverb?.enabled = preset > 0
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // === Hardware keys channel ===
        keysChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            KEYS_CHANNEL
        )
        keysChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "setCaptureVolumeKeys" -> {
                    captureVolumeKeys = call.argument<Boolean>("capture") ?: false
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // === Thumbnail channel (replaces video_thumbnail plugin) ===
        thumbChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            THUMB_CHANNEL
        )
        thumbChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "generate" -> {
                    val path = call.argument<String>("path") ?: ""
                    val maxWidth = call.argument<Int>("maxWidth") ?: 256
                    val quality = call.argument<Int>("quality") ?: 60
                    val timeMs = call.argument<Int>("timeMs") ?: 2000
                    if (path.isEmpty()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    // Generate on background thread; reply on Flutter main thread.
                    thread(start = true, isDaemon = true, name = "thumb-gen") {
                        val bytes = generateThumbnail(path, maxWidth, quality, timeMs)
                        runOnUiThread { result.success(bytes) }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // === External Intent channel (Phase 29: open from file manager) ===
        intentChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            INTENT_CHANNEL
        )
        intentChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialVideo" -> {
                    if (pendingIntentUri != null) {
                        val map = mapOf(
                            "uri" to pendingIntentUri,
                            "title" to pendingIntentTitle
                        )
                        pendingIntentUri = null
                        pendingIntentTitle = null
                        result.success(map)
                    } else {
                        result.success(null)
                    }
                }
                "getInitialSharedLink" -> {
                    // One-shot, same contract as getInitialVideo: consumed on
                    // the first read so a later restart can't replay it.
                    val link = pendingSharedLink
                    pendingSharedLink = null
                    result.success(link)
                }
                // docs/updater_plan.md step 6: the user tapped the "an update
                // is available" notification while the app was not running.
                "getInitialOpenAppUpdate" -> {
                    val open = pendingOpenAppUpdate
                    pendingOpenAppUpdate = false
                    result.success(open)
                }
                else -> result.notImplemented()
            }
        }

        // Phase 45: background playback foreground service. Flutter calls
        // 'start' when the user enables "Background Play" (the headphone
        // icon) and 'stop' when they disable it or leave the player.
        playbackChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PLAYBACK_CHANNEL
        )
        playbackChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val title = call.argument<String>("title") ?: "Innocent"
                    try {
                        PlaybackService.start(
                            applicationContext,
                            title,
                            (call.argument<Number>("positionMs"))?.toLong()
                                ?: -1L,
                            (call.argument<Number>("durationMs"))?.toLong()
                                ?: -1L
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "stop" -> {
                    try {
                        PlaybackService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "update" -> {
                    // Refresh the ongoing notification (title + play/pause
                    // icon) without restarting the service.
                    try {
                        PlaybackService.update(
                            applicationContext,
                            call.argument<String>("title") ?: "Innocent",
                            call.argument<Boolean>("isPlaying") ?: true,
                            // Long from Dart arrives as Int or Long depending
                            // on magnitude, so read it as Number and widen.
                            (call.argument<Number>("positionMs"))?.toLong()
                                ?: -1L,
                            (call.argument<Number>("durationMs"))?.toLong()
                                ?: -1L
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "isInteractive" -> {
                    // Lets Dart resolve the ambiguity of
                    // AppLifecycleState.inactive: screen genuinely off, or
                    // just a shade / dialog over a still-lit display?
                    result.success(isScreenInteractive())
                }
                else -> result.notImplemented()
            }
        }
        registerScreenStateReceiver()
        registerPlaybackControlReceiver()

        // Foreground service for Wi-Fi file transfers: Flutter calls
        // start/update/stop to keep the transfer alive while backgrounded
        // and to drive the progress notification.
        // What kind of connection this is, and whether it costs money by the
        // megabyte. See NetInfo for why the question is "metered" and not
        // "Wi-Fi": a tethered phone and a paid hotspot are both Wi-Fi and both
        // cost the user, and Android already knows the difference.
        netInfoChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NET_INFO_CHANNEL
        )
        netInfoChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> {
                    result.success(
                        mapOf(
                            "transport" to NetInfo.transport(applicationContext),
                            "metered" to NetInfo.metered(applicationContext)
                        )
                    )
                }
                else -> result.notImplemented()
            }
        }

        // The cipher that keeps a downloaded film from being copied off the
        // phone. Three verbs: ask whether this phone can do it at all, mint an
        // IV for a new film, and cipher a run of bytes that belong at a given
        // offset. The file handling stays in Dart, which already owns the part
        // file, its resume point and its sink.
        //
        // ON THE MAIN THREAD, and that is measured rather than assumed: the
        // platform's AES is the CPU's own AES instruction on every ARMv8 phone,
        // so a quarter-megabyte is a fraction of a millisecond, and the player
        // asks about twelve times a second. Moving it to a background thread
        // would add a hop and a copy to buy nothing.
        mediaCryptoChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_CRYPTO_CHANNEL
        )
        mediaCryptoChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "selfTest" -> result.success(MediaCrypto.selfTest(applicationContext))
                "newIv" -> {
                    try {
                        result.success(MediaCrypto.newIv())
                    } catch (e: Throwable) {
                        result.success(null)
                    }
                }
                "transform" -> {
                    // NULL AND NOT AN ERROR on failure. Every caller has a
                    // plaintext path to fall back to, and a PlatformException
                    // crossing into the download loop would be caught there and
                    // counted as a network failure — which is the one diagnosis
                    // that would send somebody to check their signal.
                    try {
                        val iv = call.argument<String>("iv")
                        val bytes = call.argument<ByteArray>("bytes")
                        val offset = (call.argument<Number>("offset"))?.toLong()
                        if (iv == null || bytes == null || offset == null) {
                            result.success(null)
                        } else {
                            result.success(
                                MediaCrypto.transform(applicationContext, iv, offset, bytes)
                            )
                        }
                    } catch (e: Throwable) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Keeps a catalogue "watch offline" download alive across Home, a
        // screen-off and a swipe from recents. Three verbs and nothing else:
        // the downloading itself is Dart's, and this only tells Android the
        // work is happening. See OfflineService for why that declaration is
        // the difference between the feature working and not.
        offlineServiceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OFFLINE_SERVICE_CHANNEL
        )
        offlineServiceChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        OfflineService.start(
                            applicationContext,
                            call.argument<String>("title") ?: "Downloading",
                            call.argument<String>("text") ?: "",
                            call.argument<Int>("progress") ?: -1
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "update" -> {
                    try {
                        OfflineService.update(
                            applicationContext,
                            call.argument<String>("title") ?: "Downloading",
                            call.argument<String>("text") ?: "",
                            call.argument<Int>("progress") ?: -1
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "done" -> {
                    try {
                        OfflineService.stop(applicationContext)
                        OfflineService.notifyDone(
                            applicationContext,
                            call.argument<String>("title") ?: "Downloaded",
                            call.argument<String>("text") ?: ""
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "stop" -> {
                    try {
                        OfflineService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                // Has the Pause button in the shade been pressed? Read and
                // cleared in one call, so one press pauses one download. The
                // downloader asks while it refreshes the notification, which is
                // the only moment it is certainly running.
                "takePauseRequest" -> {
                    try {
                        result.success(OfflineService.takePauseRequest())
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }

        transferServiceChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TRANSFER_SERVICE_CHANNEL
        )
        transferServiceChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    try {
                        TransferService.start(
                            applicationContext,
                            call.argument<String>("title") ?: "Transferring",
                            call.argument<String>("text") ?: "",
                            call.argument<Int>("progress") ?: -1
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "update" -> {
                    try {
                        TransferService.update(
                            applicationContext,
                            call.argument<String>("title") ?: "Transferring",
                            call.argument<String>("text") ?: "",
                            call.argument<Int>("progress") ?: -1
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "stop" -> {
                    try {
                        TransferService.stop(applicationContext)
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                // Open a received file with whichever app owns it. For an
                // .apk that is the package installer, which is the whole
                // point: a friend hands you the app over Wi-Fi and you can
                // actually install it, instead of being told a folder path
                // and left to go hunting in a file manager.
                "openFile" -> {
                    var ok = false
                    try {
                        val path = call.argument<String>("path")
                        val f = if (path.isNullOrBlank()) null else java.io.File(path)
                        if (f != null && f.exists()) {
                            val uri = androidx.core.content.FileProvider.getUriForFile(
                                applicationContext,
                                "$packageName.fileprovider",
                                f
                            )
                            val ext = f.extension.lowercase()
                            val mime = when (ext) {
                                "apk" -> "application/vnd.android.package-archive"
                                else -> android.webkit.MimeTypeMap.getSingleton()
                                    .getMimeTypeFromExtension(ext)
                                    ?: "*/*"
                            }
                            val view = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, mime)
                                addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK
                                )
                            }
                            // resolveActivity first: startActivity on a type
                            // nothing handles throws ActivityNotFoundException,
                            // and "no app can open this" is a sentence the
                            // Dart side should get to say properly.
                            if (view.resolveActivity(packageManager) != null) {
                                startActivity(view)
                                ok = true
                            }
                        }
                    } catch (t: Throwable) {
                        ok = false
                    }
                    result.success(ok)
                }
                // Android 8+ gates sideloading behind a per-app switch. Asking
                // the user to install without checking would drop them on a
                // system screen with no explanation.
                "canInstallApks" -> {
                    val allowed = try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                    } catch (t: Throwable) {
                        false
                    }
                    result.success(allowed)
                }
                // THE SIGNING-KEY-DRIFT EMERGENCY, docs/updater_plan.md §6.
                //
                // Android refuses to update an installed app with an APK
                // signed by a different key. There is no override and no
                // recovery: a single wrong-key release strands every existing
                // install permanently, and the only way back is uninstall,
                // which takes the user's data with it.
                //
                // The installer's own refusal is a generic "App not
                // installed", which tells the user nothing and tells us
                // nothing either — ACTION_VIEW returns no result. So the
                // comparison happens HERE, before the intent is ever fired,
                // and the Dart side gets to say the one honest sentence the
                // plan fixes for this case.
                //
                // Returns true when the certificates match, false when they
                // provably differ, and null when the question could not be
                // answered. Null means PROCEED: refusing on an unknown would
                // block every legitimate update on any device whose answer we
                // cannot read.
                "apkCertMatchesInstalled" -> {
                    result.success(apkCertMatchesInstalled(call.argument<String>("path")))
                }
                "openInstallPermission" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(
                                Intent(
                                    android.provider.Settings
                                        .ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName")
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        }
                        result.success(true)
                    } catch (t: Throwable) {
                        result.success(false)
                    }
                }
                "notifyDone" -> {
                    try {
                        TransferService.notifyDone(
                            applicationContext,
                            call.argument<String>("title") ?: "Transfer complete",
                            call.argument<String>("text") ?: ""
                        )
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                // docs/updater_plan.md step 6, §4A. On this channel rather
                // than a new one for the same reason step 4's
                // apkCertMatchesInstalled is: the notification-posting code
                // the updater reuses lives on the transfer side, and a second
                // MethodChannel for two methods would be a second seam to keep
                // in step. The NOTIFICATION CHANNEL is separate — see
                // UpdateNotification — which is the separation the user can
                // actually see and control.
                "showUpdateNotification" -> {
                    result.success(
                        UpdateNotification.show(
                            applicationContext,
                            call.argument<String>("title") ?: "An update is available",
                            call.argument<String>("text") ?: ""
                        )
                    )
                }
                "cancelUpdateNotification" -> {
                    UpdateNotification.cancel(applicationContext)
                    result.success(true)
                }
                // Nearby-device discovery sends UDP broadcasts. Android's
                // Wi-Fi stack DROPS frames that aren't addressed to this
                // device unless a MulticastLock is held, which is exactly why
                // this class of feature "works on my phone" and silently
                // finds nothing on someone else's. Held only while the
                // Transfer tab is looking, released as soon as it stops —
                // the lock costs battery because it wakes the radio for
                // traffic we'd otherwise never see.
                "acquireMulticastLock" -> {
                    try {
                        if (multicastLock == null) {
                            val wm = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wm.createMulticastLock("mx_clone:discovery").apply {
                                setReferenceCounted(false)
                                acquire()
                            }
                        }
                        result.success(true)
                    } catch (e: Throwable) {
                        result.success(false)
                    }
                }
                "releaseMulticastLock" -> {
                    try {
                        multicastLock?.let { if (it.isHeld) it.release() }
                        multicastLock = null
                        result.success(true)
                    } catch (e: Throwable) {
                        multicastLock = null
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // falling back to a local-only hotspot). See TurboLink.kt for why the
        // order matters. Every call answers with a plain map so the Dart side
        // can turn a failure reason into a real sentence for the user.
        turboChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TURBO_CHANNEL
        )
        turboChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "hostStart" -> TurboLink.hostStart(applicationContext) {
                    result.success(it)
                }
                "hostStop" -> {
                    TurboLink.hostStop(applicationContext)
                    result.success(true)
                }
                "hostState" -> result.success(TurboLink.hostState())
                "joinStart" -> TurboLink.joinStart(
                    applicationContext,
                    call.argument<String>("ssid") ?: "",
                    call.argument<String>("pass") ?: ""
                ) { result.success(it) }
                "joinStop" -> {
                    TurboLink.joinStop(applicationContext)
                    result.success(true)
                }
                "joinState" -> result.success(TurboLink.joinState())
                "preconditions" -> result.success(
                    mapOf(
                        "wifi" to TurboLink.isWifiEnabled(applicationContext),
                        "location" to TurboLink.isLocationEnabled(applicationContext),
                        "sdk" to Build.VERSION.SDK_INT
                    )
                )
                "openSettings" -> {
                    TurboLink.openSettings(
                        applicationContext,
                        call.argument<String>("which") ?: "wifi"
                    )
                    result.success(true)
                }
                // Path to Innocent's own APK. Handing the app itself to a
                // friend with no data is the single most-used feature of every
                // share app in this market, and the Apps picker already lists
                // installed packages — this just saves hunting for our own.
                "selfApk" -> {
                    try {
                        val src = applicationInfo.sourceDir
                        val f = java.io.File(src)
                        result.success(
                            mapOf(
                                "path" to src,
                                "size" to f.length(),
                                "name" to "Innocent.apk"
                            )
                        )
                    } catch (t: Throwable) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Phase 45: audio focus management. When a phone call arrives or
        // another media app starts playing, Android sends us a
        // FOCUS_LOSS_TRANSIENT (or FOCUS_LOSS) callback. We forward it
        // to Flutter via the same channel so the player can pause
        // cleanly. When the interruption ends (FOCUS_GAIN) Flutter
        // decides whether to auto-resume.
        audioFocusChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUDIO_FOCUS_CHANNEL
        )
        audioFocusChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> {
                    val granted = requestAudioFocus()
                    result.success(granted)
                }
                "abandon" -> {
                    abandonAudioFocus()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Phase 63: Storage Access Framework channel. `pickTree` launches the
        // system folder picker (optionally seeded at Android/data), persists
        // the grant, and replies via onActivityResult. `listVideos` walks
        // every persisted tree for video files. `grantedTrees`/`releaseTree`
        // manage the persisted set.
        safChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SAF_CHANNEL
        )
        safChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickTree" -> {
                    if (pendingSafResult != null) {
                        result.error("busy", "A folder picker is already open", null)
                        return@setMethodCallHandler
                    }
                    pendingSafResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    intent.addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    )
                    val initial = call.argument<String>("initialUri")
                    if (initial != null &&
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                    ) {
                        try {
                            intent.putExtra(
                                DocumentsContract.EXTRA_INITIAL_URI,
                                Uri.parse(initial)
                            )
                        } catch (_: Throwable) {}
                    }
                    try {
                        startActivityForResult(intent, SAF_TREE_REQUEST)
                    } catch (e: Throwable) {
                        pendingSafResult = null
                        result.error("no_picker", e.message, null)
                    }
                }
                "grantedTrees" -> {
                    val out = ArrayList<String>()
                    try {
                        for (perm in contentResolver.persistedUriPermissions) {
                            if (perm.isReadPermission) out.add(perm.uri.toString())
                        }
                    } catch (_: Throwable) {}
                    result.success(out)
                }
                "releaseTree" -> {
                    val uri = call.argument<String>("uri")
                    if (uri != null) {
                        try {
                            contentResolver.releasePersistableUriPermission(
                                Uri.parse(uri),
                                Intent.FLAG_GRANT_READ_URI_PERMISSION
                            )
                        } catch (_: Throwable) {}
                    }
                    result.success(true)
                }
                "listVideos" -> {
                    thread(start = true, isDaemon = true, name = "saf-scan") {
                        val out = ArrayList<HashMap<String, Any?>>()
                        try {
                            for (perm in contentResolver.persistedUriPermissions) {
                                if (!perm.isReadPermission) continue
                                try {
                                    enumerateSafTree(perm.uri, out)
                                } catch (_: Throwable) {}
                            }
                        } catch (_: Throwable) {}
                        runOnUiThread { result.success(out) }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // v0.99 Downloader: yt-dlp engine channels (method + progress events).
        // Registered from its own file so MainActivity doesn't grow another
        // ~250 lines; DownloadEngine holds no Activity reference (it keeps only
        // the application context) so this cannot leak the Activity.
        DownloadEngine.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // Lets our own screens open INSIDE this task instead of starting one
        // of their own — see DownloadEngine.activityRef. Released in onDestroy
        // so a finished Activity is never held.
        DownloadEngine.attachActivity(this)

        // Phase 64 / M1a: ADB engine channel. `init` builds/loads the client
        // key + certificate off the main thread and reports status — no
        // network yet. pair/connect/shell arrive in M1b.
        adbChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "mx_clone/adb"
        )
        adbChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> {
                    thread(start = true, isDaemon = true, name = "adb-init") {
                        val status = AdbManager.selfTest(this@MainActivity)
                        runOnUiThread { result.success(status) }
                    }
                }
                "pair" -> {
                    val host = call.argument<String>("host") ?: "127.0.0.1"
                    val port = call.argument<Int>("port") ?: 0
                    val code = call.argument<String>("code") ?: ""
                    thread(start = true, isDaemon = true, name = "adb-pair") {
                        val status = AdbManager.pairDevice(this@MainActivity, host, port, code)
                        runOnUiThread { result.success(status) }
                    }
                }
                "connectAndRun" -> {
                    val host = call.argument<String>("host") ?: "127.0.0.1"
                    val port = call.argument<Int>("port") ?: 0
                    val command = call.argument<String>("command") ?: "id"
                    thread(start = true, isDaemon = true, name = "adb-conn") {
                        val status =
                            AdbManager.connectAndRun(this@MainActivity, host, port, command)
                        runOnUiThread { result.success(status) }
                    }
                }
                "lastConnect" -> {
                    result.success(AdbManager.lastConnect(this@MainActivity))
                }
                "shell" -> {
                    val command = call.argument<String>("command") ?: ""
                    val timeoutMs =
                        (call.argument<Number>("timeoutMs"))?.toLong() ?: 12000L
                    thread(start = true, isDaemon = true, name = "adb-shell") {
                        val out = AdbManager.runShell(
                            this@MainActivity, command, timeoutMs,
                        )
                        runOnUiThread { result.success(out) }
                    }
                }
                "openDevOptions" -> {
                    val enabled = try {
                        Settings.Global.getInt(
                            contentResolver,
                            Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
                            0,
                        ) == 1
                    } catch (e: Throwable) {
                        true
                    }
                    if (!enabled) {
                        result.success("dev_options_off")
                    } else {
                        val opened = tryStartWirelessDebugging() || startDevOptions()
                        result.success(if (opened) "opened" else "failed")
                    }
                }
                "openAboutPhone" -> {
                    result.success(
                        if (startActivitySafely(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS))) {
                            "opened"
                        } else {
                            "failed"
                        },
                    )
                }
                "pullForPlayback" -> {
                    val src = call.argument<String>("src") ?: ""
                    thread(start = true, isDaemon = true, name = "adb-pull") {
                        val out = AdbManager.pullForPlayback(this@MainActivity, src)
                        runOnUiThread { result.success(out) }
                    }
                }
                "streamUrl" -> {
                    val src = call.argument<String>("src") ?: ""
                    thread(start = true, isDaemon = true, name = "adb-stream") {
                        val out = AdbManager.streamUrl(this@MainActivity, src)
                        runOnUiThread { result.success(out) }
                    }
                }
                "saveScanned" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    AdbManager.saveScannedVideos(this@MainActivity, paths)
                    result.success(true)
                }
                "scannedVideos" -> {
                    result.success(AdbManager.scannedVideos(this@MainActivity))
                }
                "setupAutoEnable" -> {
                    thread(start = true, isDaemon = true, name = "adb-autoenable") {
                        val status = AdbManager.setupAutoEnable(this@MainActivity)
                        runOnUiThread { result.success(status) }
                    }
                }
                "autoEnableStatus" -> {
                    val map = HashMap<String, Any>()
                    map["granted"] = AdbManager.hasSecureSettings(this@MainActivity)
                    map["on"] = AdbManager.autoEnableOn(this@MainActivity)
                    // audit_adb.md A5: what the last post-boot restore did.
                    // "It silently did not happen" was the actual complaint,
                    // so the screen has to be able to say what happened.
                    map["lastBoot"] = AdbBootJobService.lastResult(this@MainActivity)
                    map["lastBootAt"] = AdbBootJobService.lastResultAt(this@MainActivity)
                    result.success(map)
                }
                // audit_adb.md A9: the exit the feature never had.
                "revokeSecureSettings" -> {
                    thread(start = true, isDaemon = true, name = "adb-revoke") {
                        val status = AdbManager.revokeSecureSettings(this@MainActivity)
                        runOnUiThread { result.success(status) }
                    }
                }
                "setAutoEnable" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    AdbManager.setAutoEnable(this@MainActivity, on)
                    result.success(true)
                }
                "pairMdns" -> {
                    val code = call.argument<String>("code") ?: ""
                    thread(start = true, isDaemon = true, name = "adb-pair-mdns") {
                        val status =
                            AdbManager.pairWithMdns(this@MainActivity, code, 25000L)
                        runOnUiThread { result.success(status) }
                    }
                }
                "autoConnectAndRun" -> {
                    val command = call.argument<String>("command") ?: "id"
                    thread(start = true, isDaemon = true, name = "adb-autoconn") {
                        val status =
                            AdbManager.autoConnectAndRun(this@MainActivity, command, 20000L)
                        runOnUiThread { result.success(status) }
                    }
                }
                "reconnectAndRun" -> {
                    val command = call.argument<String>("command") ?: "id"
                    thread(start = true, isDaemon = true, name = "adb-reconn") {
                        val status =
                            AdbManager.reconnectAndRun(this@MainActivity, command)
                        runOnUiThread { result.success(status) }
                    }
                }
                // v0.89: which backend reads Android/data ("builtin" | "iadb").
                "getBackend" -> {
                    result.success(AdbManager.adbBackend(this@MainActivity))
                }
                "setBackend" -> {
                    val backend = call.argument<String>("backend") ?: "builtin"
                    AdbManager.setAdbBackend(this@MainActivity, backend)
                    result.success(true)
                }
                // v0.89: iADB-style notification pairing (no split-screen). The
                // foreground service discovers the pairing service in the
                // background and posts a RemoteInput notification; the user
                // types the code into the shade. Result comes back via the
                // ADB_PAIR_RESULT broadcast → forwarded to Flutter as
                // `onPairResult`.
                "startPairingService" -> {
                    AdbPairingService.start(this@MainActivity)
                    result.success(true)
                }
                "stopPairingService" -> {
                    AdbPairingService.stop(this@MainActivity)
                    result.success(true)
                }
                // v0.93 Backend 2: iADB app client. status()/connected() make
                // binder IPC calls (ping), so run them off the main thread to
                // avoid any chance of an ANR if the iADB server is slow.
                "iadbStatus" -> {
                    thread(start = true, isDaemon = true, name = "iadb-status") {
                        val s = IadbClient.status()
                        runOnUiThread { result.success(s) }
                    }
                }
                "iadbInstalledAndRunning" -> {
                    thread(start = true, isDaemon = true, name = "iadb-inst") {
                        val b = IadbClient.installedAndRunning()
                        runOnUiThread { result.success(b) }
                    }
                }
                "iadbConnected" -> {
                    thread(start = true, isDaemon = true, name = "iadb-conn") {
                        val b = IadbClient.connected()
                        runOnUiThread { result.success(b) }
                    }
                }
                "iadbConnect" -> {
                    // Must run on the main thread (Iadb posts callbacks there);
                    // MethodCallHandler is already on main.
                    IadbClient.onStateChanged = {
                        // Just signal "something changed"; the Dart side then
                        // re-queries iadbConnected/iadbStatus on a worker thread.
                        // (Avoids doing a binder ping on whatever thread this
                        // callback happens to run on.)
                        runOnUiThread {
                            adbChannel?.invokeMethod("onIadbState", null)
                        }
                    }
                    IadbClient.connect(this@MainActivity)
                    result.success(true)
                }
                "iadbDisconnect" -> {
                    IadbClient.disconnect()
                    result.success(true)
                }
                "iadbOpenInStore" -> {
                    AdbManager.openIadbInStore(this@MainActivity)
                    result.success(true)
                }
                "iadbExec" -> {
                    val cmd = call.argument<String>("command") ?: ""
                    thread(start = true, isDaemon = true, name = "iadb-exec") {
                        val out = IadbClient.exec(cmd)
                        runOnUiThread { result.success(out) }
                    }
                }
                "iadbPullForPlayback" -> {
                    val path = call.argument<String>("path") ?: ""
                    thread(start = true, isDaemon = true, name = "iadb-pull") {
                        val out = IadbClient.pullToCache(this@MainActivity, path)
                        runOnUiThread { result.success(out) }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Process the initial intent that started this Activity (e.g. VIEW)
        handleVideoIntent(intent, fromNewIntent = false)
        handleSharedLink(intent, fromNewIntent = false)
        handleUpdateIntent(intent, fromNewIntent = false)

        // v0.89: forward the ADB pairing service's result back to Flutter so the
        // ADB screen can react (it broadcasts ADB_PAIR_RESULT after each pair
        // attempt from the notification).
        adbPairResultReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == AdbPairingService.ACTION_RESULT) {
                    val res = intent.getStringExtra(AdbPairingService.EXTRA_RESULT)
                        ?: ""
                    adbChannel?.invokeMethod("onPairResult", mapOf("result" to res))
                }
            }
        }
        try {
            val filter = IntentFilter(AdbPairingService.ACTION_RESULT)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(
                    adbPairResultReceiver, filter, Context.RECEIVER_NOT_EXPORTED,
                )
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(adbPairResultReceiver, filter)
            }
        } catch (_: Throwable) {
        }

        // Phase 45: register the headphone-disconnect listener. We send
        // the event to the keys channel (already established above) so
        // the Flutter side can pause playback to match MX Player.
        becomingNoisyReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    keysChannel?.invokeMethod(
                        "onMediaKey",
                        mapOf("action" to "headphonesDisconnected")
                    )
                }
            }
        }
        try {
            registerReceiver(
                becomingNoisyReceiver,
                IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            )
        } catch (_: Throwable) {
            // Some OEMs throw if registration happens too early; safe to ignore.
        }
    }

    // Intercept hardware volume keys when player is active +
    // headset / Bluetooth media keys (always when keysChannel is set).
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        // Volume keys are intentionally NOT intercepted — they should always
        // control system volume, never seek. This is more predictable for users.

        // Media keys (headset / Bluetooth) - active when player is foregrounded
        if (captureVolumeKeys) {
            when (keyCode) {
                android.view.KeyEvent.KEYCODE_HEADSETHOOK,
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                    keysChannel?.invokeMethod("onMediaKey", mapOf("action" to "playPause"))
                    return true
                }
                android.view.KeyEvent.KEYCODE_MEDIA_PLAY -> {
                    keysChannel?.invokeMethod("onMediaKey", mapOf("action" to "play"))
                    return true
                }
                android.view.KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                    keysChannel?.invokeMethod("onMediaKey", mapOf("action" to "pause"))
                    return true
                }
                android.view.KeyEvent.KEYCODE_MEDIA_NEXT -> {
                    keysChannel?.invokeMethod("onMediaKey", mapOf("action" to "next"))
                    return true
                }
                android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                    keysChannel?.invokeMethod("onMediaKey", mapOf("action" to "previous"))
                    return true
                }
                android.view.KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                    keysChannel?.invokeMethod("onMediaKey", mapOf("action" to "forward"))
                    return true
                }
                android.view.KeyEvent.KEYCODE_MEDIA_REWIND -> {
                    keysChannel?.invokeMethod("onMediaKey", mapOf("action" to "rewind"))
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun initEqualizer(sessionId: Int): Boolean {
        return try {
            releaseEqualizer()
            equalizer = Equalizer(0, sessionId).apply { enabled = true }
            // Phase 45 (audit): construct each AudioFx side-effect that
            // MX Player V3 exposes. Wrapping each in its own try block
            // means a device that doesn't support, say, BassBoost still
            // gets the Equalizer working.
            try {
                bassBoost = BassBoost(0, sessionId)
            } catch (_: Exception) { bassBoost = null }
            try {
                virtualizer = Virtualizer(0, sessionId)
            } catch (_: Exception) { virtualizer = null }
            try {
                presetReverb = PresetReverb(0, sessionId)
            } catch (_: Exception) { presetReverb = null }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun releaseEqualizer() {
        try { equalizer?.release() } catch (_: Exception) {}
        equalizer = null
        try { bassBoost?.release() } catch (_: Exception) {}
        bassBoost = null
        try { virtualizer?.release() } catch (_: Exception) {}
        virtualizer = null
        try { presetReverb?.release() } catch (_: Exception) {}
        presetReverb = null
    }

    private fun isPipSupported(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(
                android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE
            )
    }

    // Track the last playing state so a PiP-params refresh (icon swap) can
    // show the correct play vs pause action without Flutter passing it every
    // time.
    private var pipIsPlaying: Boolean = true

    /**
     * Clamp an arbitrary video aspect into Android's legal PiP range
     * (roughly 1:2.39 … 2.39:1). Passing a ratio outside this band makes
     * enterPictureInPictureMode() throw IllegalArgumentException and crash
     * the activity — a very real risk with ultra-wide clips or vertical
     * phone videos, so we never hand the system an illegal Rational.
     */
    private fun clampedAspect(width: Int, height: Int): Rational {
        val w = width.coerceIn(1, 9999)
        val h = height.coerceIn(1, 9999)
        val ratio = w.toDouble() / h.toDouble()
        val maxRatio = 2.39
        val minRatio = 1.0 / 2.39
        return when {
            ratio > maxRatio -> Rational(239, 100)
            ratio < minRatio -> Rational(100, 239)
            else -> Rational(w, h)
        }
    }

    /**
     * Build the RemoteActions shown inside the PiP window (play/pause + the
     * standard system close is separate). The play/pause action swaps its
     * icon + label based on [pipIsPlaying] so the little control always
     * reflects the real state.
     */
    private fun buildPipActions(): List<RemoteAction> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return emptyList()
        val actions = ArrayList<RemoteAction>()
        try {
            val playPauseIcon = Icon.createWithResource(
                this,
                if (pipIsPlaying) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play
            )
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val intent = PendingIntent.getBroadcast(
                this,
                ACTION_PIP_PLAY_PAUSE_CODE,
                Intent(ACTION_PIP_CONTROL).setPackage(packageName)
                    .putExtra(EXTRA_PIP_CONTROL, CONTROL_PLAY_PAUSE),
                flags
            )
            actions.add(
                RemoteAction(
                    playPauseIcon,
                    if (pipIsPlaying) "Pause" else "Play",
                    if (pipIsPlaying) "Pause" else "Play",
                    intent
                )
            )
        } catch (_: Exception) {
            // If action assembly fails for any reason, PiP still works
            // without custom controls — never let this crash the entry.
        }
        return actions
    }

    private fun buildPipParams(
        width: Int,
        height: Int,
        srcRect: Rect?,
        autoEnter: Boolean = false
    ): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(clampedAspect(width, height))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setActions(buildPipActions())
        }
        if (srcRect != null) {
            // Smooth "morph from the on-screen video into the PiP window"
            // animation instead of a hard cut.
            builder.setSourceRectHint(srcRect)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Android 12+: video keeps its frame during the resize animation
            // (no letterbox flash) — the recommended setting for players.
            builder.setSeamlessResizeEnabled(true)
            // Android 12+: let the SYSTEM auto-enter PiP when the user leaves
            // the app. This is far more reliable than manually calling
            // enterPictureInPictureMode() from onUserLeaveHint (which can be
            // rejected if the activity has already begun pausing) — it's the
            // recommended path for the "keep playing over other apps" flow.
            builder.setAutoEnterEnabled(autoEnter)
        }
        return builder.build()
    }

    /**
     * Arm/disarm system auto-enter PiP. Called when the in-app floating
     * window opens (arm, with the video's real aspect ratio) and closes
     * (disarm) so the app only auto-PiPs while a floating video is live.
     * No-op below Android 12, where we fall back to the manual
     * onUserLeaveHint → enterPip path.
     */
    private fun setAutoEnterPip(enable: Boolean, width: Int, height: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        autoEnterArmed = enable
        try {
            if (enable) {
                lastPipW = width
                lastPipH = height
            }
            setPictureInPictureParams(
                buildPipParams(
                    if (enable) width else lastPipW,
                    if (enable) height else lastPipH,
                    null,
                    enable
                )
            )
        } catch (_: Exception) {}
    }

    /**
     * Whether the user has granted this app the special "Picture-in-picture"
     * permission (AppOps OP_PICTURE_IN_PICTURE). It's ON by default on stock
     * Android but some OEMs ship it OFF, and the user can revoke it — in which
     * case enterPictureInPictureMode silently does nothing. We expose this so
     * Flutter can guide the user to Settings instead of failing quietly.
     */
    private fun isPipAllowed(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val uid = Process.myUid()
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(
                    AppOpsManager.OPSTR_PICTURE_IN_PICTURE, uid, packageName
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    AppOpsManager.OPSTR_PICTURE_IN_PICTURE, uid, packageName
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (_: Exception) {
            // If the op can't be resolved on this device, don't block the
            // feature — assume it's allowed and let the system decide.
            true
        }
    }

    /** Open the app's Picture-in-picture settings (falls back to app info). */
    private fun openPipSettings() {
        val uri = Uri.fromParts("package", packageName, null)
        val candidates = listOf(
            Intent("android.settings.PICTURE_IN_PICTURE_SETTINGS", uri),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, uri)
        )
        for (intent in candidates) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return
            } catch (_: Exception) {}
        }
    }

    private fun startActivitySafely(intent: Intent): Boolean = try {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        true
    } catch (_: Throwable) {
        false
    }

    private fun startDevOptions(): Boolean =
        startActivitySafely(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))

    /**
     * Best-effort jump straight to the Wireless debugging screen. There is no
     * public intent for it, so we try known Settings components and quietly
     * fall back to the Developer options screen if none resolve.
     */
    private fun tryStartWirelessDebugging(): Boolean {
        val components = listOf(
            "com.android.settings.Settings\$WirelessDebuggingActivity",
            "com.android.settings.development.WirelessDebuggingActivity",
        )
        for (cls in components) {
            try {
                val i = Intent().setClassName("com.android.settings", cls)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (i.resolveActivity(packageManager) != null) {
                    startActivity(i)
                    return true
                }
            } catch (_: Throwable) {
            }
        }
        return false
    }

    /**
     * Refresh the PiP params while already in PiP — used to swap the
     * play/pause icon when playback toggles. No-op if not supported.
     */
    private fun updatePipParams(isPlaying: Boolean) {
        pipIsPlaying = isPlaying
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            setPictureInPictureParams(buildPipParams(lastPipW, lastPipH, null))
        } catch (_: Exception) {}
    }

    private var lastPipW: Int = 16
    private var lastPipH: Int = 9
    // True while Android 12+ system auto-enter PiP is armed (floating window
    // live). When set, manual enterPip() defers to the system so the captured
    // frame is the fullscreen video, not the small floating window.
    private var autoEnterArmed: Boolean = false
    // Set when we leave a PiP window; resolved in onStop (dismiss) / onResume
    // (expand) to detect the user tapping × on the system PiP.
    private var justLeftPip: Boolean = false

    private fun enterPip(width: Int, height: Int, srcRect: Rect?): Boolean {
        if (!isPipSupported()) return false
        // Android 12+ with auto-enter armed (floating window live): let the
        // SYSTEM enter PiP on leave instead of forcing it here. Manually
        // entering now would race the "expand to fullscreen" rebuild and
        // snapshot the small floating window; the system auto-enter fires a
        // beat later, after the fullscreen frame has rendered.
        if (autoEnterArmed && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return true
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                lastPipW = width
                lastPipH = height
                enterPictureInPictureMode(buildPipParams(width, height, srcRect))
            } else {
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            registerPipControlReceiver()
            justLeftPip = false
        } else {
            unregisterPipControlReceiver()
            // We just left a PiP window. Whether that was the user tapping ×
            // (dismiss) or tapping the window to expand back into the app is
            // decided by what happens next: a dismiss stops the activity
            // (onStop) without resuming, an expand resumes it (onResume). We
            // set the flag here and resolve it in those callbacks.
            justLeftPip = true
        }
        pipChannel?.invokeMethod(
            "onPipModeChanged",
            mapOf("inPip" to isInPictureInPictureMode)
        )
    }

    override fun onResume() {
        super.onResume()
        // Expanded back into the app (or normal resume) — not a PiP dismiss.
        justLeftPip = false
    }

    // Phase 63: SAF folder-picker result. Persist the grant so it survives
    // restarts, then hand the tree URI back to Flutter (or null if cancelled).
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != SAF_TREE_REQUEST) return
        val res = pendingSafResult
        pendingSafResult = null
        val treeUri = data?.data
        if (resultCode == RESULT_OK && treeUri != null) {
            try {
                contentResolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Throwable) {}
            res?.success(treeUri.toString())
        } else {
            res?.success(null)
        }
    }

    /// Recursively walk one persisted tree URI for video files, appending
    /// {uri, name, size, path} maps to [out]. `path` is the decoded document
    /// id (e.g. "primary:Android/data/com.x/files/a.mp4") so Flutter can group
    /// hidden entries into folders just like a real filesystem path.
    private fun enumerateSafTree(treeUri: Uri, out: ArrayList<HashMap<String, Any?>>) {
        val rootId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (_: Throwable) {
            return
        }
        enumerateSafDoc(treeUri, rootId, out, 0)
    }

    private fun enumerateSafDoc(
        treeUri: Uri,
        docId: String,
        out: ArrayList<HashMap<String, Any?>>,
        depth: Int
    ) {
        if (depth > 24) return
        val childrenUri = try {
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
        } catch (_: Throwable) {
            return
        }
        var cursor: Cursor? = null
        try {
            cursor = contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE
                ),
                null, null, null
            )
        } catch (_: Throwable) {
            return
        }
        cursor?.use { c ->
            val idCol = 0
            val nameCol = 1
            val mimeCol = 2
            val sizeCol = 3
            while (c.moveToNext()) {
                val childId = c.getString(idCol) ?: continue
                val name = c.getString(nameCol) ?: ""
                val mime = c.getString(mimeCol) ?: ""
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    enumerateSafDoc(treeUri, childId, out, depth + 1)
                } else if (mime.startsWith("video/") || isVideoFileName(name)) {
                    val size = try { c.getLong(sizeCol) } catch (_: Throwable) { 0L }
                    val docUri = try {
                        DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
                    } catch (_: Throwable) {
                        continue
                    }
                    val m = HashMap<String, Any?>()
                    m["uri"] = docUri.toString()
                    m["name"] = name
                    m["size"] = size
                    m["path"] = childId
                    out.add(m)
                }
            }
        }
    }

    private fun isVideoFileName(name: String): Boolean {
        val dot = name.lastIndexOf('.')
        if (dot < 0) return false
        val ext = name.substring(dot + 1).lowercase()
        return when (ext) {
            "mp4", "mkv", "webm", "avi", "mov", "m4v", "3gp", "3g2", "flv",
            "wmv", "ts", "m2ts", "mts", "mpg", "mpeg", "vob", "ogv", "rm",
            "rmvb", "divx", "f4v", "asf", "m2v", "mxf" -> true
            else -> false
        }
    }

    override fun onStop() {
        super.onStop()
        // If we stopped right after leaving a PiP window (and didn't resume in
        // between), the user dismissed the PiP with ×. libmpv would otherwise
        // keep the audio thread alive in the background and the floating window
        // would still be showing when they reopen the app — so tell Flutter to
        // fully stop playback and tear the floating window down.
        if (justLeftPip) {
            justLeftPip = false
            pipChannel?.invokeMethod("onPipClosed", null)
        }
    }

    private fun registerPipControlReceiver() {
        if (pipControlReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != ACTION_PIP_CONTROL) return
                when (intent.getStringExtra(EXTRA_PIP_CONTROL)) {
                    CONTROL_PLAY_PAUSE ->
                        pipChannel?.invokeMethod("onPipPlayPause", null)
                }
            }
        }
        pipControlReceiver = receiver
        val filter = IntentFilter(ACTION_PIP_CONTROL)
        // Android 13+ (API 33) requires an explicit export flag on runtime
        // receivers. This is an internal, same-app broadcast, so NOT_EXPORTED.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
    }

    /**
     * Is the display actually on right now? PowerManager.isInteractive() is
     * the platform's own answer and costs nothing to ask.
     */
    private fun isScreenInteractive(): Boolean {
        return try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
                pm.isInteractive
            } else {
                @Suppress("DEPRECATION")
                pm.isScreenOn
            }
        } catch (_: Throwable) {
            // Unknown → assume the screen is on, which keeps the old
            // (conservative) behaviour rather than detaching the picture
            // out from under someone who is still watching.
            true
        }
    }

    /**
     * ACTION_SCREEN_OFF / ACTION_SCREEN_ON can only be registered at runtime —
     * the manifest form has been ignored since Android 3.1 — so this is
     * registered once when the engine is configured and dropped in onDestroy.
     * onReceive runs on the main thread, which is where MethodChannel calls
     * must be made from, so the forward is safe as written.
     */
    private fun registerScreenStateReceiver() {
        if (screenStateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_OFF ->
                        playbackChannel?.invokeMethod("onScreenOff", null)
                    Intent.ACTION_SCREEN_ON,
                    Intent.ACTION_USER_PRESENT ->
                        playbackChannel?.invokeMethod("onScreenOn", null)
                }
            }
        }
        screenStateReceiver = receiver
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        try {
            // These are SYSTEM broadcasts, so unlike our own internal ones the
            // receiver has to be exported on Android 13+ or it never fires.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, filter)
            }
        } catch (_: Throwable) {
            screenStateReceiver = null
        }
    }

    private fun unregisterScreenStateReceiver() {
        screenStateReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        screenStateReceiver = null
    }

    /** Transport-control clicks from the background-playback notification. */
    private fun registerPlaybackControlReceiver() {
        if (playbackControlReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != ACTION_PLAYBACK_CONTROL) return
                val which = intent.getStringExtra(EXTRA_PLAYBACK_CONTROL)
                    ?: return
                playbackChannel?.invokeMethod(
                    "onPlaybackAction",
                    mapOf(
                        "action" to which,
                        "positionMs" to
                            intent.getLongExtra(EXTRA_PLAYBACK_POSITION, -1L)
                    )
                )
            }
        }
        playbackControlReceiver = receiver
        val filter = IntentFilter(ACTION_PLAYBACK_CONTROL)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, filter)
            }
        } catch (_: Throwable) {
            playbackControlReceiver = null
        }
    }

    private fun unregisterPlaybackControlReceiver() {
        playbackControlReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        playbackControlReceiver = null
    }

    private fun unregisterPipControlReceiver() {
        pipControlReceiver?.let {
            try { unregisterReceiver(it) } catch (_: Exception) {}
        }
        pipControlReceiver = null
    }

    /**
     * Phase 45: when the user presses Home (or swipes up), Android calls
     * this hook BEFORE the activity pauses. We forward it to Flutter so
     * the player can decide whether to enter PiP automatically — which
     * is what MX Player's "Background/PIP mode" does. The Flutter side
     * checks the user's setting + whether a video is actually playing,
     * then calls back into `enterPip` if appropriate.
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        pipChannel?.invokeMethod("onUserLeaveHint", null)
    }

    /**
     * Native thumbnail generator (replaces deprecated video_thumbnail plugin).
     * Uses MediaMetadataRetriever + JPEG compression.
     */
    private fun generateThumbnail(
        videoPath: String,
        maxWidth: Int,
        quality: Int,
        timeMs: Int
    ): ByteArray? {
        val retriever = MediaMetadataRetriever()
        return try {
            // Strip file:// scheme if present
            val cleanPath = if (videoPath.startsWith("file://")) {
                android.net.Uri.parse(videoPath).path ?: videoPath
            } else {
                videoPath
            }
            retriever.setDataSource(cleanPath)
            val timeUs = (timeMs.coerceAtLeast(0)).toLong() * 1000L

            // OPTION_CLOSEST_SYNC = fast, good enough for thumbnails.
            val raw: Bitmap? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                // API 27+: getScaledFrameAtTime avoids extra scaling
                retriever.getScaledFrameAtTime(
                    timeUs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                    maxWidth.coerceAtLeast(1),
                    -1
                )
            } else {
                retriever.getFrameAtTime(
                    timeUs,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                )
            }
            val initial: Bitmap = raw ?: return null

            // If still oversized (pre-API27 path), scale down.
            // `bmp` stays non-null throughout this block.
            var bmp: Bitmap = initial
            if (bmp.width > maxWidth && maxWidth > 0) {
                val ratio = bmp.height.toFloat() / bmp.width.toFloat()
                val newW = maxWidth
                val newH = (newW * ratio).toInt().coerceAtLeast(1)
                val scaled: Bitmap = Bitmap.createScaledBitmap(bmp, newW, newH, true)
                if (scaled !== bmp) bmp.recycle()
                bmp = scaled
            }

            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), out)
            bmp.recycle()
            out.toByteArray()
        } catch (_: Throwable) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * Phase 29: Handle Activity intent — extract URI when launched via VIEW action
     * (e.g. user taps a video in file manager / gallery / browser).
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleVideoIntent(intent, fromNewIntent = true)
        handleSharedLink(intent, fromNewIntent = true)
        handleUpdateIntent(intent, fromNewIntent = true)
    }

    /**
     * docs/updater_plan.md step 6: the update notification was tapped.
     *
     * Mirrors [handleSharedLink] exactly, including the cold/warm split: when
     * the app is already running the Dart side is told immediately, and when
     * it is not, the fact is parked for the first getInitialOpenAppUpdate.
     * Flutter is not attached during a cold start, so invoking the channel
     * there would go nowhere and the tap would silently do nothing.
     *
     * The extra is REMOVED once read. The Activity is singleTop and the launch
     * intent is sticky (setIntent in onNewIntent), so leaving it in place
     * would re-open the update screen on every later resume from recents.
     */
    private fun handleUpdateIntent(intent: Intent?, fromNewIntent: Boolean) {
        if (intent == null) return
        if (!intent.getBooleanExtra(UpdateNotification.EXTRA_OPEN_APP_UPDATE, false)) return
        intent.removeExtra(UpdateNotification.EXTRA_OPEN_APP_UPDATE)
        if (fromNewIntent) {
            intentChannel?.invokeMethod("onOpenAppUpdate", null)
        } else {
            pendingOpenAppUpdate = true
        }
    }

    /**
     * v0.99.5: a link shared into Innocent from another app.
     *
     * Share sheets rarely hand over a bare URL — the text is usually a caption
     * with the link somewhere inside it, so anything that isn't an http(s)
     * token is dropped and the first real one is kept. Anything that fails
     * that test is ignored entirely rather than passed on, so sharing ordinary
     * text into Innocent does nothing visible instead of opening an error.
     */
    private fun handleSharedLink(intent: Intent?, fromNewIntent: Boolean) {
        if (intent == null) return
        if (intent.action != Intent.ACTION_SEND) return
        if (intent.type?.startsWith("text/") != true) return
        val raw = intent.getStringExtra(Intent.EXTRA_TEXT)
            ?: intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: return
        val link = raw.split(Regex("\\s+"))
            .firstOrNull { it.startsWith("http://") || it.startsWith("https://") }
            ?.trim()
            ?: return
        if (fromNewIntent) {
            intentChannel?.invokeMethod("onSharedLink", mapOf("url" to link))
        } else {
            pendingSharedLink = link
        }
    }

    private fun handleVideoIntent(intent: Intent?, fromNewIntent: Boolean) {
        if (intent == null) return
        if (intent.action != Intent.ACTION_VIEW) return
        val data: Uri = intent.data ?: return
        val uriStr = data.toString()
        val title = run {
            val seg = data.lastPathSegment ?: uriStr
            // Drop everything before the last '/' just in case
            val basename = seg.substringAfterLast('/')
            // Remove URL-encoded chars by decoding (best-effort)
            try {
                Uri.decode(basename)
            } catch (_: Throwable) {
                basename
            }
        }
        if (fromNewIntent) {
            // Send straight to Flutter side — app is already running
            intentChannel?.invokeMethod(
                "onNewVideo",
                mapOf("uri" to uriStr, "title" to title)
            )
        } else {
            // Save for the FIRST query of getInitialVideo
            pendingIntentUri = uriStr
            pendingIntentTitle = title
        }
    }

    /**
     * Phase 45: request audio focus with appropriate attributes for
     * media playback. The system uses this to know who's "the music
     * app" right now, route audio appropriately, and tell other apps
     * to lower their volume / pause.
     *
     * Listener forwards focus-change events to Flutter where the
     * player decides whether to pause, lower volume (ducking), or
     * resume playback.
     */
    private fun requestAudioFocus(): Boolean {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val listener = AudioManager.OnAudioFocusChangeListener { focusChange ->
            val action = when (focusChange) {
                AudioManager.AUDIOFOCUS_GAIN -> "gain"
                AudioManager.AUDIOFOCUS_LOSS -> "loss"
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "lossTransient"
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "lossTransientCanDuck"
                else -> return@OnAudioFocusChangeListener
            }
            audioFocusChannel?.invokeMethod("onFocusChange", mapOf("action" to action))
        }
        legacyAudioFocusListener = listener

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener(listener)
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .build()
            audioFocusRequest = request
            am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            val r = am.requestAudioFocus(
                listener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
            r == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
    }

    private fun abandonAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            audioFocusRequest = null
        } else {
            @Suppress("DEPRECATION")
            legacyAudioFocusListener?.let { am.abandonAudioFocus(it) }
        }
        legacyAudioFocusListener = null
    }

    // True / false / null — see the "apkCertMatchesInstalled" channel case.
    @Suppress("DEPRECATION")
    private fun apkCertMatchesInstalled(path: String?): Boolean? {
        return try {
            if (path.isNullOrBlank()) return null
            if (!File(path).exists()) return null
            val pm = packageManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val flags = android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES
                val archive = pm.getPackageArchiveInfo(path, flags) ?: return null
                // An APK for some other package is a different question, and
                // not one this method answers. It is also never something the
                // updater should install over Innocent.
                if (archive.packageName != packageName) return false
                val installed = pm.getPackageInfo(packageName, flags)
                val a = archive.signingInfo?.apkContentsSigners ?: return null
                val b = installed.signingInfo?.apkContentsSigners ?: return null
                sameCertificates(a, b)
            } else {
                val flags = android.content.pm.PackageManager.GET_SIGNATURES
                val archive = pm.getPackageArchiveInfo(path, flags) ?: return null
                if (archive.packageName != packageName) return false
                val installed = pm.getPackageInfo(packageName, flags)
                val a = archive.signatures ?: return null
                val b = installed.signatures ?: return null
                sameCertificates(a, b)
            }
        } catch (t: Throwable) {
            // Unanswerable, not "mismatched". The caller proceeds.
            null
        }
    }

    // Set comparison, not index-by-index: an APK may legitimately carry its
    // signers in a different order from the installed package.
    private fun sameCertificates(
        a: Array<android.content.pm.Signature>,
        b: Array<android.content.pm.Signature>
    ): Boolean {
        if (a.isEmpty() || b.isEmpty()) return false
        return a.map { it.toCharsString() }.toHashSet() ==
            b.map { it.toCharsString() }.toHashSet()
    }

    override fun onDestroy() {
        // Never hold a finished Activity — see DownloadEngine.activityRef.
        DownloadEngine.detachActivity()
        releaseEqualizer()
        // Phase 45: unregister the headphone-disconnect listener.
        try {
            becomingNoisyReceiver?.let { unregisterReceiver(it) }
        } catch (_: Throwable) {
        }
        becomingNoisyReceiver = null
        // v0.89: drop the ADB pairing-result receiver too.
        try {
            adbPairResultReceiver?.let { unregisterReceiver(it) }
        } catch (_: Throwable) {
        }
        adbPairResultReceiver = null
        // Discovery's MulticastLock keeps the Wi-Fi radio accepting broadcast
        // frames; leaking it past the Activity would drain battery for a scan
        // nobody is watching.
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {
        }
        multicastLock = null
        // A Wi-Fi Direct group or local-only hotspot left running would keep
        // the radio in AP mode and the user's normal Wi-Fi down, with no UI
        // anywhere to turn it off. The transfer itself survives a swipe-away
        // via TransferService, so this only fires on a real teardown.
        try {
            if (!TransferService.isRunning) TurboLink.shutdown(applicationContext)
        } catch (_: Throwable) {
        }
        // Belt-and-suspenders: drop the PiP control receiver if we were torn
        // down while still in PiP.
        unregisterPipControlReceiver()
        // v1.51: the screen-state and notification-control receivers live for
        // the whole Activity, so they are dropped here rather than per-use.
        unregisterScreenStateReceiver()
        unregisterPlaybackControlReceiver()
        // Phase 45: drop any audio focus we still own.
        try {
            abandonAudioFocus()
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }

    // ── Anti-theft: silent front-camera capture (Camera2) ───────────────
    // Best-effort and fully self-contained: opens the front camera, grabs a
    // single still into an ImageReader, writes it to [path], and tears
    // everything down. Any exception → result(null). Runs on a dedicated
    // background thread so it never blocks the UI.
    private fun captureIntruderSelfie(path: String, result: MethodChannel.Result) {
        // Camera permission is required; bail cleanly if missing.
        if (checkSelfPermission(android.Manifest.permission.CAMERA)
            != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            result.success(null)
            return
        }
        val camThread = HandlerThread("intruderCam").apply { start() }
        val camHandler = Handler(camThread.looper)
        var settled = false

        // HELD HERE SO finish() CAN RELEASE THEM FROM ANY EXIT.
        //
        // This is the fix for docs/audit_private_folder.md V1/V2, and the
        // shape of the bug is worth keeping written down because the code
        // looked complete: device.close() appeared in FIVE places and every
        // one of them was a failure branch. The successful path ends inside
        // the ImageReader listener, which cannot see the CameraDevice at all
        // — it was scoped to onOpened — so a selfie that WORKED left the front
        // camera open for the life of the process. The ImageReader was never
        // closed on any path.
        //
        // On Android 12+ that means the camera-in-use indicator stays lit and
        // the phone's own Camera app cannot open the selfie camera until
        // Innocent is killed. On a vault app, a camera dot that never goes out
        // is the worst possible signal: the one thing this feature exists to
        // reassure people about is the one thing it then contradicts.
        //
        // One owner, not six: every callback assigns into these and nothing
        // else closes them.
        var camera: CameraDevice? = null
        var session: CameraCaptureSession? = null
        var reader: ImageReader? = null

        fun finish(value: String?) {
            if (settled) return
            settled = true
            // Session, then device, then reader. Closing the reader first
            // would pull its surface out from under a session still holding
            // it. CameraDevice.close() is idempotent, so a callback that has
            // already been through here costs nothing.
            try {
                session?.close()
            } catch (_: Throwable) {
            }
            try {
                camera?.close()
            } catch (_: Throwable) {
            }
            try {
                reader?.close()
            } catch (_: Throwable) {
            }
            session = null
            camera = null
            reader = null
            runOnUiThread { result.success(value) }
            camHandler.postDelayed({ camThread.quitSafely() }, 200)
        }
        try {
            val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            // Find a front-facing camera.
            var frontId: String? = null
            for (id in manager.cameraIdList) {
                val chars = manager.getCameraCharacteristics(id)
                if (chars.get(CameraCharacteristics.LENS_FACING)
                    == CameraCharacteristics.LENS_FACING_FRONT
                ) {
                    frontId = id
                    break
                }
            }
            if (frontId == null) {
                finish(null)
                return
            }
            val imageReader = ImageReader.newInstance(
                640, 480, android.graphics.ImageFormat.JPEG, 1
            )
            reader = imageReader
            imageReader.setOnImageAvailableListener({ r ->
                var ok = false
                try {
                    val image = r.acquireLatestImage()
                    if (image != null) {
                        val buffer = image.planes[0].buffer
                        val bytes = ByteArray(buffer.remaining())
                        buffer.get(bytes)
                        image.close()
                        FileOutputStream(File(path)).use { it.write(bytes) }
                        ok = true
                    }
                } catch (e: Exception) {
                    ok = false
                }
                // Safe to close the reader from inside its own callback: the
                // one image it was configured for has just been acquired and
                // closed above, so nothing is outstanding.
                finish(if (ok) path else null)
            }, camHandler)

            manager.openCamera(frontId, object : CameraDevice.StateCallback() {
                override fun onOpened(device: CameraDevice) {
                    camera = device
                    try {
                        val surface = imageReader.surface
                        val req = device.createCaptureRequest(
                            CameraDevice.TEMPLATE_STILL_CAPTURE
                        )
                        req.addTarget(surface)
                        req.set(
                            CaptureRequest.CONTROL_MODE,
                            CaptureRequest.CONTROL_MODE_AUTO
                        )
                        device.createCaptureSession(
                            listOf(surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(
                                    configured: CameraCaptureSession
                                ) {
                                    session = configured
                                    try {
                                        configured.capture(
                                            req.build(), null, camHandler
                                        )
                                    } catch (e: Exception) {
                                        finish(null)
                                    }
                                }

                                override fun onConfigureFailed(
                                    configured: CameraCaptureSession
                                ) {
                                    session = configured
                                    finish(null)
                                }
                            },
                            camHandler
                        )
                    } catch (e: Exception) {
                        finish(null)
                    }
                }

                override fun onDisconnected(device: CameraDevice) {
                    // Assigned here too: onOpened may never have run, and the
                    // device handed to this callback is still ours to close.
                    camera = device
                    finish(null)
                }

                override fun onError(device: CameraDevice, error: Int) {
                    camera = device
                    finish(null)
                }
            }, camHandler)

            // Safety timeout: if the camera never delivers, give up — and
            // release it, which this used to skip. A front camera claimed by
            // a face-unlock service opens and then never delivers a frame,
            // which is precisely the case that reached here and leaked.
            camHandler.postDelayed({ finish(null) }, 4000)
        } catch (e: Exception) {
            finish(null)
        }
    }
}
