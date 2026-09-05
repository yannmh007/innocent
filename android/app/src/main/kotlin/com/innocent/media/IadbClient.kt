package com.innocent.media

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import java.util.concurrent.atomic.AtomicReference

/**
 * Backend 2: talk to the SEPARATELY-INSTALLED iADB app as a Shizuku-style
 * client. iADB owns the privileged server (started once via Wireless debugging);
 * Innocent binds to it and runs our [UserService] inside that server (shell uid
 * 2000) to read Android/data + Android/obb.
 *
 * Why this is more robust than the built-in socket engine: iADB's server is a
 * persistent process, and we reach it over a BINDER (kernel IPC), not a TCP
 * socket. So once iADB is set up, Innocent reconnects instantly, the link
 * survives Wi-Fi changes, and Wireless debugging doesn't have to stay on.
 *
 * ANDROID-VERSION SAFETY (critical): the iADB .aar libraries require Android 11
 * (API 30) — Innocent itself supports API 24. The app stays installable on
 * older phones (built-in backend only) and NEVER touches any `com.iadb.*` class
 * below API 30. All com.iadb.* access is isolated in [IadbBridge]; this class
 * only calls into IadbBridge AFTER an API-30 check, and IadbBridge's own methods
 * re-check too. So on older devices the iADB classes are never loaded/verified.
 * The manifest merge is allowed via `tools:overrideLibrary` for the four iADB
 * packages; that override is only safe BECAUSE of these runtime guards.
 *
 * Everything here is defensive: iADB may be missing, not running, permission may
 * be denied, or the binder may die at any time. No call throws to the caller;
 * failures return null/false/"" and the UI reports "not connected".
 */
object IadbClient {

    private const val PERMISSION_CODE = 4021

    private fun supported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R

    // The live IUserService (null when not connected). IUserService is OUR AIDL
    // (package com.innocent.media), safe to reference on any API level.
    private val userService = AtomicReference<IUserService?>(null)

    @Volatile
    private var appContext: Context? = null

    @Volatile
    private var listenersRegistered = false

    @Volatile
    private var permissionGranted = false

    // Optional: notified when the binder connects/dies so the UI can refresh.
    @Volatile
    var onStateChanged: (() -> Unit)? = null

    // ServiceConnection references no com.iadb.* type (IUserService.Stub is our
    // own AIDL), so it's safe to hold as a field on any API level.
    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
            val svc = if (binder != null && binder.pingBinder()) {
                try {
                    IUserService.Stub.asInterface(binder)
                } catch (_: Throwable) {
                    null
                }
            } else {
                null
            }
            userService.set(svc)
            notifyState()
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            userService.set(null)
            notifyState()
        }
    }

    private fun notifyState() {
        try {
            onStateChanged?.invoke()
        } catch (_: Throwable) {
        }
    }

    /** True on Android 11+ AND the iADB app is installed with a live server. */
    fun installedAndRunning(): Boolean {
        if (!supported()) return false
        return try {
            IadbBridge.pingBinder()
        } catch (_: Throwable) {
            false
        }
    }

    /** True when our UserService binder is live in the iADB server. */
    fun connected(): Boolean {
        if (!supported()) return false
        val svc = userService.get() ?: return false
        return try {
            svc.asBinder().pingBinder()
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Begin the connect flow. Safe to call more than once; listeners register
     * only once. Call from the main thread (iADB posts callbacks there). No-op
     * below API 30.
     */
    fun connect(context: Context) {
        if (!supported()) return
        appContext = context.applicationContext
        if (!listenersRegistered) {
            try {
                IadbBridge.registerListeners(
                    onBinderReceived = {
                        try {
                            if (checkOrRequestPermission()) bindUserService()
                        } catch (_: Throwable) {
                        }
                    },
                    onBinderDead = {
                        userService.set(null)
                        notifyState()
                    },
                    onPermissionResult = { granted ->
                        permissionGranted = granted
                        if (granted) {
                            try {
                                bindUserService()
                            } catch (_: Throwable) {
                            }
                        }
                    },
                )
                listenersRegistered = true
            } catch (_: Throwable) {
            }
        }
        try {
            if (checkOrRequestPermission()) bindUserService()
        } catch (_: Throwable) {
        }
    }

    /** Tear down the binding (e.g. user switches away from the iADB backend). */
    fun disconnect() {
        if (!supported()) return
        try {
            val ctx = appContext ?: return
            IadbBridge.unbindUserService(
                ctx.packageName,
                UserService::class.java.name,
                serviceConnection,
            )
        } catch (_: Throwable) {
        } finally {
            userService.set(null)
            notifyState()
        }
    }

    private fun checkOrRequestPermission(): Boolean {
        return try {
            when (IadbBridge.permissionState()) {
                IadbBridge.PERM_GRANTED -> {
                    permissionGranted = true
                    true
                }
                IadbBridge.PERM_SHOULD_EXPLAIN -> false
                else -> {
                    // Shows the iADB "Allow Innocent to access iAdb?" dialog.
                    // Result arrives on the permission listener, which then
                    // binds — so we return false now and let that drive it.
                    IadbBridge.requestPermission(PERMISSION_CODE)
                    false
                }
            }
        } catch (_: Throwable) {
            false
        }
    }

    private fun bindUserService() {
        if (userService.get() != null) return
        val ctx = appContext ?: return
        try {
            IadbBridge.bindUserService(
                ctx.packageName,
                UserService::class.java.name,
                serviceConnection,
            )
        } catch (_: Throwable) {
            userService.set(null)
        }
    }

    /** Ready = installed + running + permission + a live UserService binder. */
    private fun ready(): Boolean {
        if (!installedAndRunning()) return false
        val svc = userService.get() ?: return false
        return try {
            svc.asBinder().pingBinder()
        } catch (_: Throwable) {
            false
        }
    }

    // ---- Operations Innocent actually uses ----

    /** Human-readable status for the ADB screen. Never throws. */
    fun status(): String {
        if (!supported()) {
            return "iADB backend needs Android 11 or newer."
        }
        if (!installedAndRunning()) {
            return "iADB app not found or not running. Install iADB and start " +
                "it (turn on its server), then tap Connect."
        }
        val svc = userService.get()
            ?: return "iADB found. Tap Connect and allow access when asked."
        return try {
            "OK \u2014 connected to iADB (${svc.ping()})."
        } catch (_: Throwable) {
            "iADB found but the connection isn't ready yet. Tap Connect."
        }
    }

    /** Run a shell command in the privileged process. "" on failure. */
    fun exec(command: String): String {
        if (!supported()) return ""
        val svc = userService.get()
        if (!ready() || svc == null) return ""
        return try {
            svc.exec(command) ?: ""
        } catch (_: Throwable) {
            // Binder may have died between the check and the call.
            userService.set(null)
            notifyState()
            ""
        }
    }

    /** Open a file as shell uid; caller owns the returned fd. null on failure. */
    fun openFd(path: String, mode: Int): ParcelFileDescriptor? {
        if (!supported()) return null
        val svc = userService.get()
        if (!ready() || svc == null) return null
        return try {
            svc.getFD(path, mode)
        } catch (_: Throwable) {
            userService.set(null)
            notifyState()
            null
        }
    }

    /**
     * Copy a file that only the shell user can read (Android/data) into
     * Innocent's own cache and return the local path, so media_kit can play it
     * on every device (fd:// playback support varies by player/ROM, a real file
     * never does). Returns an "ERROR:" string on failure. Runs on a worker
     * thread from the caller.
     */
    fun pullToCache(context: Context, srcPath: String): String {
        if (!supported()) {
            return "ERROR: the iADB backend needs Android 11 or newer."
        }
        val svc = userService.get()
        if (!ready() || svc == null) {
            return "ERROR: iADB not connected. Open ADB connection and tap " +
                "Connect."
        }

        val cacheDir = context.externalCacheDir ?: context.cacheDir
        val playDir = java.io.File(cacheDir, "iadb_play").apply { mkdirs() }
        // Stable name per source so re-playing the same file reuses the copy.
        val safeName = srcPath.hashCode().toString() + "_" +
            srcPath.substringAfterLast('/').take(80)
        val outFile = java.io.File(playDir, safeName)
        // Cache hit → reuse the existing copy WITHOUT opening a new fd (opening
        // then discarding it would leak the descriptor). Bump its mtime so the
        // LRU pruning below treats it as recently used.
        if (outFile.exists() && outFile.length() > 0) {
            outFile.setLastModified(System.currentTimeMillis())
            return outFile.absolutePath
        }
        // Cap the pulled-copy cache so replaying many large Android/data files
        // (videos, and now Private-Folder / Transfer pulls) can't fill the
        // device. Oldest copies are evicted first, down to a 2 GB budget —
        // mirrors the built-in backend's AdbManager.pruneCache.
        pruneCache(playDir, 2L * 1024 * 1024 * 1024)

        val pfd = try {
            svc.getFD(srcPath, ParcelFileDescriptor.MODE_READ_ONLY)
        } catch (_: Throwable) {
            userService.set(null)
            notifyState()
            null
        } ?: return "ERROR: iADB couldn't open the file (it may have moved or " +
            "the connection dropped)."

        return try {
            ParcelFileDescriptor.AutoCloseInputStream(pfd).use { input ->
                java.io.FileOutputStream(outFile).use { output ->
                    val buf = ByteArray(256 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                    }
                    output.flush()
                }
            }
            outFile.absolutePath
        } catch (e: Throwable) {
            try {
                outFile.delete()
            } catch (_: Throwable) {
            }
            "ERROR: iADB copy failed (${e.javaClass.simpleName})."
        }
    }

    /**
     * Evict oldest files in [dir] until the total is at or under [maxBytes].
     * Local copy of AdbManager.pruneCache so the iADB backend caps its own
     * playback cache too.
     */
    private fun pruneCache(dir: java.io.File, maxBytes: Long) {
        val files = dir.listFiles()?.filter { it.isFile }
            ?.sortedBy { it.lastModified() } ?: return
        var total = files.sumOf { it.length() }
        for (f in files) {
            if (total <= maxBytes) break
            val len = f.length()
            if (f.delete()) total -= len
        }
    }
}
