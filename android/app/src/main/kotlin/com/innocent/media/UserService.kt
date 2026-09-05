package com.innocent.media

import android.content.Context
import android.os.ParcelFileDescriptor
import androidx.annotation.Keep
import java.io.BufferedReader
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStreamReader
import kotlin.system.exitProcess

/**
 * Runs INSIDE the iADB privileged server process (shell user, uid 2000), NOT in
 * Innocent's normal app process. iADB instantiates this via the @Keep
 * constructor when Innocent binds. Because it runs as the shell user, it can
 * read Android/data + Android/obb, which a normal app cannot on Android 11+.
 *
 * Keep this class SELF-CONTAINED: it must not touch Innocent's app singletons,
 * Flutter, or anything from the normal process — it lives in a different process
 * with a different classloader. Only the AIDL surface crosses the boundary.
 */
@Keep
class UserService : IUserService.Stub {

    @Suppress("unused")
    constructor() : super()

    // iADB calls this constructor (context flavour) — required, must be @Keep.
    @Keep
    @Suppress("UNUSED_PARAMETER")
    constructor(context: Context) : super()

    override fun destroy() {
        // iAdb server tears us down.
        exitProcess(0)
    }

    override fun exit() {
        destroy()
    }

    /**
     * Open a file as the shell user and hand back its descriptor. For playback
     * Innocent asks for MODE_READ_ONLY and streams straight from the fd — no
     * copy into app cache needed.
     */
    override fun getFD(path: String?, mode: Int): ParcelFileDescriptor? {
        if (path.isNullOrEmpty()) return null
        return try {
            ParcelFileDescriptor.open(File(path), mode)
        } catch (e: FileNotFoundException) {
            null
        } catch (e: Throwable) {
            null
        }
    }

    /**
     * Run a shell command in this privileged process and return combined
     * stdout+stderr, capped so a huge `find` can't blow the binder's 1 MB
     * transaction limit. The client sends `find … -type f` over Android/data.
     */
    override fun exec(command: String?): String {
        if (command.isNullOrEmpty()) return ""
        return try {
            val proc = ProcessBuilder("sh", "-c", command)
                .redirectErrorStream(true)
                .start()
            val out = StringBuilder()
            BufferedReader(InputStreamReader(proc.inputStream)).use { reader ->
                var line: String?
                while (true) {
                    line = reader.readLine() ?: break
                    out.append(line).append('\n')
                    // Binder transactions are capped ~1 MB; stop well short so a
                    // giant tree can't crash the call. The client can page with
                    // narrower find roots if it ever hits this.
                    if (out.length > 700_000) {
                        out.append("\n[truncated]\n")
                        break
                    }
                }
            }
            try {
                proc.waitFor()
            } catch (_: Throwable) {
            }
            out.toString()
        } catch (e: Throwable) {
            ""
        }
    }

    override fun ping(): String {
        return try {
            "shell:" + android.os.Process.myUid()
        } catch (e: Throwable) {
            "shell:?"
        }
    }
}
