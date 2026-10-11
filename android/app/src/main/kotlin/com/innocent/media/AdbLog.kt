package com.innocent.media

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * WHAT THE ADB ENGINE DID, STEP BY STEP — for the report a person sends when
 * it will not connect.
 *
 * "It doesn't connect" came back from a real phone with nothing to go on:
 * the screen keeps only the last answer, and the reason a connect failed
 * (the port it tried, what Settings said, what the sweep found, the
 * exception the handshake threw) was swallowed. Each step now leaves one
 * line here: kept in memory, appended to a small file so it survives the
 * app being closed, and read by the ADB screen's "Copy report" and "Send
 * report".
 *
 * What it never holds: file names or paths from Android/data (commands are
 * logged by their kind, not their text), the phone's own name, codes typed
 * for pairing. Ports, outcomes and exception names are what a diagnosis
 * needs.
 */
object AdbLog {
    private const val MAX_LINES = 500
    private const val MAX_FILE_BYTES = 160_000L

    private val lines = ArrayDeque<String>()
    private var lastMessage: String? = null
    private var repeats = 0
    private var file: File? = null
    private var loaded = false
    private val clock = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US)

    /** Where the log lives; called with any context before the first line. */
    @Synchronized
    fun attach(context: Context) {
        if (loaded) return
        loaded = true
        val f = File(context.applicationContext.filesDir, "adb_log.txt")
        file = f
        try {
            if (f.exists()) {
                val old = f.readLines()
                for (l in old.takeLast(MAX_LINES)) lines.addLast(l)
                // Trimmed on open rather than on every write: appending a line
                // is cheap, rewriting the file each time is not.
                if (f.length() > MAX_FILE_BYTES) f.writeText(lines.joinToString("\n", postfix = "\n"))
            }
        } catch (_: Throwable) {
        }
    }

    /**
     * One step. The same message twice in a row is counted, not repeated:
     * the "connection lost" card asks every few seconds, and a log of 300
     * identical "not connected" lines tells nothing the first one did not.
     */
    @Synchronized
    fun add(message: String) {
        val msg = message.replace('\n', ' ').take(400)
        android.util.Log.i("InnocentAdb", msg)
        val stamp = try {
            clock.format(Date())
        } catch (_: Throwable) {
            ""
        }
        if (msg == lastMessage && lines.isNotEmpty()) {
            repeats++
            lines.removeLast()
            lines.addLast("$stamp $msg  (×${repeats + 1})")
            return
        }
        lastMessage = msg
        repeats = 0
        val line = "$stamp $msg"
        lines.addLast(line)
        while (lines.size > MAX_LINES) lines.removeFirst()
        try {
            file?.appendText(line + "\n")
        } catch (_: Throwable) {
        }
    }

    @Synchronized
    fun text(): String = lines.joinToString("\n")

    @Synchronized
    fun clear() {
        lines.clear()
        lastMessage = null
        repeats = 0
        try {
            file?.writeText("")
        } catch (_: Throwable) {
        }
    }

    /**
     * A shell command by its kind, never its text: the text names files in
     * other apps' folders.
     */
    fun kindOf(service: String): String {
        val cmd = service.removePrefix("shell:").trim()
        return when {
            cmd == "id" -> "id"
            cmd.startsWith("echo ok") -> "probe"
            cmd == "true" -> "liveness"
            cmd.contains("find ") && cmd.contains("-maxdepth 1") -> "list folder"
            cmd.contains("find ") && cmd.contains("Android/data") -> "scan"
            cmd.startsWith("stat ") -> "stat"
            cmd.startsWith("pm ") -> "pm"
            cmd.startsWith("settings ") -> "settings"
            else -> cmd.substringBefore(' ').take(16)
        }
    }

    /** An exception as "Name: message", short. */
    fun why(e: Throwable?): String {
        if (e == null) return "unknown"
        val m = e.message?.replace('\n', ' ')?.take(160)
        return if (m.isNullOrBlank()) e.javaClass.simpleName else "${e.javaClass.simpleName}: $m"
    }
}
