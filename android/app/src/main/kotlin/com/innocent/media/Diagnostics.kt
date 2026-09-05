package com.innocent.media

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * v1.61 — WHY THIS FILE EXISTS.
 *
 * The app has been dying outright during playback: not a Dart exception (that
 * would render the player's error card) but the whole process going away. From
 * a phone, with no terminal and no `adb logcat`, there has been no way to see
 * why, so every discussion about it has been guesswork.
 *
 * Android 11 (API 30) added `ActivityManager.getHistoricalProcessExitReasons`,
 * which lets an app read the reason its OWN previous processes ended — crash,
 * native crash, ANR, low memory, killed by the user, killed by the system. On
 * API 31+ a native crash also carries the tombstone.
 *
 * So the app can answer the question itself. This object turns those records
 * into plain text; the Dart side (Settings → Diagnostics) shows it and copies
 * it to the clipboard.
 *
 * Everything here is best-effort and read-only. It must never be able to
 * affect playback, so every branch is wrapped and failure returns a line of
 * text rather than throwing.
 */
object Diagnostics {

    private fun stamp(ms: Long): String = try {
        SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.US).format(Date(ms))
    } catch (_: Throwable) {
        ms.toString()
    }

    // ── Device / app environment ────────────────────────────────────────────

    fun deviceInfo(context: Context): String {
        val sb = StringBuilder()
        try {
            sb.append("device      : ")
                .append(Build.MANUFACTURER).append(' ').append(Build.MODEL)
                .append(" (").append(Build.DEVICE).append(")\n")
            sb.append("android     : ").append(Build.VERSION.RELEASE)
                .append(" (API ").append(Build.VERSION.SDK_INT).append(")\n")
            sb.append("build       : ").append(Build.DISPLAY).append('\n')
            sb.append("abis        : ")
                .append(Build.SUPPORTED_ABIS.joinToString(", ")).append('\n')

            val am = context.getSystemService(Context.ACTIVITY_SERVICE)
                as? ActivityManager
            if (am != null) {
                sb.append("heap limit  : ").append(am.memoryClass)
                    .append(" MB (large ").append(am.largeMemoryClass)
                    .append(" MB)\n")
                sb.append("low-ram dev : ").append(am.isLowRamDevice).append('\n')
                try {
                    val mi = ActivityManager.MemoryInfo()
                    am.getMemoryInfo(mi)
                    sb.append("memory now  : avail ")
                        .append(mi.availMem / (1024 * 1024)).append(" MB of ")
                        .append(mi.totalMem / (1024 * 1024)).append(" MB")
                        .append(if (mi.lowMemory) "  [LOW]" else "").append('\n')
                } catch (_: Throwable) {
                }
                // A background-restricted app is stopped the moment it leaves
                // the foreground, which is exactly what "music stops when I
                // leave the app" looks like from the outside. Worth knowing
                // before blaming any of our own code for it.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    try {
                        sb.append("bg restricted: ")
                            .append(am.isBackgroundRestricted).append('\n')
                    } catch (_: Throwable) {
                    }
                }
            }
            sb.append("package     : ").append(context.packageName).append('\n')
        } catch (t: Throwable) {
            sb.append("deviceInfo failed: ").append(t).append('\n')
        }
        return sb.toString()
    }

    // ── Why did the previous process die? ───────────────────────────────────

    fun exitReasons(context: Context, max: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return "Process exit history needs Android 11 or newer.\n" +
                "This device is Android ${Build.VERSION.RELEASE} " +
                "(API ${Build.VERSION.SDK_INT}), so the system does not keep " +
                "it.\nThe breadcrumb trail below still shows what the app was " +
                "doing before it died.\n"
        }
        return try {
            readExitReasons(context, max)
        } catch (t: Throwable) {
            "Could not read process exit history: $t\n"
        }
    }

    /**
     * Isolated in its own method on purpose: the ART verifier resolves the
     * classes a method touches when that method is first executed, so keeping
     * every API-30 type (`ApplicationExitInfo`) out of the caller means older
     * devices never load it at all.
     */
    private fun readExitReasons(context: Context, max: Int): String {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE)
            as? ActivityManager
            ?: return "No ActivityManager.\n"

        val list = am.getHistoricalProcessExitReasons(context.packageName, 0, max)
        if (list.isEmpty()) {
            return "No process exits recorded yet. (A clean exit is also " +
                "recorded, so an empty list usually means the app has only " +
                "just been installed.)\n"
        }

        val sb = StringBuilder()
        sb.append("Most recent first. ")
            .append(list.size)
            .append(" record(s).\n")

        for ((i, info) in list.withIndex()) {
            sb.append("\n--- exit #").append(i + 1).append(" ---\n")
            try {
                sb.append("when        : ").append(stamp(info.timestamp)).append('\n')
                sb.append("reason      : ").append(reasonName(info.reason))
                    .append(" (").append(info.reason).append(")\n")
                sb.append("description : ").append(info.description ?: "-").append('\n')
                sb.append("status      : ").append(info.status).append('\n')
                sb.append("importance  : ").append(importanceName(info.importance))
                    .append('\n')
                sb.append("memory      : pss ").append(info.pss / 1024)
                    .append(" MB, rss ").append(info.rss / 1024).append(" MB\n")

                // The two reasons that carry evidence. ANR gives a text thread
                // dump; a native crash on API 31+ gives the tombstone as a
                // protobuf, so the readable parts are pulled out of it rather
                // than printed raw.
                if (info.reason == ApplicationExitInfo.REASON_ANR ||
                    info.reason == ApplicationExitInfo.REASON_CRASH_NATIVE
                ) {
                    val bytes = readTrace(info)
                    if (bytes == null || bytes.isEmpty()) {
                        sb.append("trace       : none kept by the system " +
                            "(the buffer is global and gets overwritten)\n")
                    } else if (info.reason == ApplicationExitInfo.REASON_ANR) {
                        sb.append("trace       :\n")
                            .append(head(String(bytes, Charsets.UTF_8), 6000))
                            .append('\n')
                    } else {
                        sb.append("tombstone   :\n")
                            .append(printableStrings(bytes, 6, 6000))
                            .append('\n')
                    }
                }
            } catch (t: Throwable) {
                sb.append("(record unreadable: ").append(t).append(")\n")
            }
        }
        return sb.toString()
    }

    private fun readTrace(info: ApplicationExitInfo): ByteArray? = try {
        info.traceInputStream?.use { input ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(8 * 1024)
            var total = 0
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                out.write(buf, 0, n)
                total += n
                // A tombstone is small; anything past this is not going to be
                // read on a phone screen anyway.
                if (total > 512 * 1024) break
            }
            out.toByteArray()
        }
    } catch (_: Throwable) {
        null
    }

    /**
     * A native tombstone arrives as a protocol buffer. Decoding it properly
     * would mean shipping the schema; but the parts worth reading — the abort
     * message, the signal name, the .so file names in the backtrace — are
     * plain strings inside it. Pulling every printable run out is the same
     * trick as the `strings` command, and it is enough to name the library
     * that crashed.
     *
     * v1.62: the raw dump alone was ~200 lines of every thread's backtrace
     * around the three lines that mattered, read on a phone. So the strings
     * are now sorted into a HIGHLIGHTS block first — the abort message, the
     * signal, and any frame naming a library this app actually ships — with
     * the rest kept below it and capped harder. Nothing is discarded that was
     * not duplicated; the ordering is the whole change.
     */
    private fun printableStrings(bytes: ByteArray, minLen: Int, limit: Int): String {
        val all = ArrayList<String>()
        val cur = StringBuilder()
        for (b in bytes) {
            val c = b.toInt() and 0xFF
            if (c in 0x20..0x7E) {
                cur.append(c.toChar())
            } else {
                if (cur.length >= minLen) all.add(cur.toString())
                cur.setLength(0)
            }
        }
        if (cur.length >= minLen) all.add(cur.toString())

        val seen = HashSet<String>()
        val key = ArrayList<String>()
        val ours = ArrayList<String>()
        val rest = ArrayList<String>()
        for (line in all) {
            if (!seen.add(line)) continue          // the same frame repeats per thread
            when {
                KEY_MARKERS.any { line.contains(it) } -> key.add(line)
                OUR_LIBS.any { line.contains(it) } -> ours.add(line)
                else -> rest.add(line)
            }
        }

        val out = StringBuilder()
        if (key.isNotEmpty()) {
            out.append("  ** what went wrong **\n")
            for (l in key.take(12)) out.append("  ").append(l).append('\n')
        }
        if (ours.isNotEmpty()) {
            out.append("  ** our own libraries in the trace **\n")
            for (l in ours.take(14)) out.append("  ").append(l).append('\n')
        }
        out.append("  ** rest **\n")
        for (l in rest) {
            out.append("  ").append(l).append('\n')
            if (out.length > limit) break
        }
        return head(out.toString(), limit)
    }

    /** Lines that name the failure itself. */
    private val KEY_MARKERS = listOf(
        "JNI DETECTED", "Abort message", "abort_message",
        "SIGABRT", "SIGSEGV", "SIGBUS", "SIGILL", "SIGFPE", "SIGTRAP",
        "Fatal", "CHECK failed", "check failed", "OutOfMemory",
        "terminating", "std::bad_alloc", "assert",
    )

    /** Frames naming something this app ships, rather than the platform. */
    private val OUR_LIBS = listOf(
        "libmpv", "libflutter", "media_kit", "libavcodec", "libavformat",
        "libavutil", "libswscale", "libplacebo", "com.innocent",
    )

    private fun head(s: String, limit: Int): String =
        if (s.length <= limit) s else s.substring(0, limit) + "\n…(truncated)"

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "ANR — the app stopped responding"
        ApplicationExitInfo.REASON_CRASH -> "CRASH — unhandled Java/Kotlin exception"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE — native (C/C++) crash"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY — the system needed the RAM"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED — killed by a signal"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED — swiped away"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED — force-stopped"
        ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
        else -> "reason code $reason"
    }

    private fun importanceName(importance: Int): String = when (importance) {
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ->
            "FOREGROUND (the app was on screen)"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE ->
            "FOREGROUND_SERVICE (background play was holding it up)"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE -> "VISIBLE"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE -> "SERVICE"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_CACHED -> "CACHED (backgrounded)"
        ActivityManager.RunningAppProcessInfo.IMPORTANCE_GONE -> "GONE"
        else -> "importance $importance"
    }
}
