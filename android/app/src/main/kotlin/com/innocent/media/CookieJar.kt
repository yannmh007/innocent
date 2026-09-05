package com.innocent.media

import android.content.Context
import android.net.Uri
import android.webkit.CookieManager
import java.io.File

/**
 * The Netscape cookie file the download engine reads.
 *
 * Shared because two very different things write it: the sign-in screen, where
 * someone deliberately logs in, and the silent harvester, which asks a site
 * for the ordinary anonymous session any first-time visitor is given. Both
 * produce the same artefact and must merge rather than overwrite, so the logic
 * lives in one place.
 */
internal object CookieJar {

    fun file(context: Context): File {
        val dir = File(context.filesDir, "downloader")
        if (!dir.exists()) dir.mkdirs()
        return File(dir, "cookies.txt")
    }

    fun exists(context: Context): Boolean = try {
        val f = file(context)
        f.isFile && f.length() > 0
    } catch (_: Throwable) {
        false
    }

    /**
     * Reads what the WebView holds for [origins] and merges it into the jar.
     * Returns true when at least one cookie was captured.
     *
     * CookieManager only hands back `name=value` pairs, with no domain, path
     * or expiry attached, so those are reconstructed: the origin's host with a
     * leading dot, root path, secure, and a year out. That is what every
     * cookie exporter does and what the engine expects to read. Entries are
     * keyed by domain+name so signing into a second site — or refreshing the
     * first — replaces rather than duplicates.
     */
    fun harvest(context: Context, origins: List<String>): Boolean {
        return try {
            val manager = CookieManager.getInstance()
            try {
                manager.flush()
            } catch (_: Throwable) {
            }

            val jar = LinkedHashMap<String, String>()
            val target = file(context)
            if (target.exists()) {
                target.forEachLine { line ->
                    if (line.startsWith("#") || line.isBlank()) return@forEachLine
                    val parts = line.split("\t")
                    if (parts.size >= 7) jar["${parts[0]}\t${parts[5]}"] = line
                }
            }

            var captured = false
            val expiry = (System.currentTimeMillis() / 1000L) + 365L * 24 * 60 * 60
            for (origin in origins) {
                val raw = manager.getCookie(origin) ?: continue
                val host = try {
                    Uri.parse(origin).host ?: continue
                } catch (_: Throwable) {
                    continue
                }
                val domain = if (host.startsWith(".")) host else ".$host"
                for (pair in raw.split(";")) {
                    val trimmed = pair.trim()
                    val eq = trimmed.indexOf('=')
                    if (eq <= 0) continue
                    val name = trimmed.substring(0, eq).trim()
                    val value = trimmed.substring(eq + 1).trim()
                    if (name.isEmpty()) continue
                    jar["$domain\t$name"] =
                        listOf(domain, "TRUE", "/", "TRUE", "$expiry", name, value)
                            .joinToString("\t")
                    captured = true
                }
            }

            if (!captured && jar.isEmpty()) return false
            val body = StringBuilder("# Netscape HTTP Cookie File\n")
            for (line in jar.values) body.append(line).append('\n')
            target.writeText(body.toString(), Charsets.UTF_8)
            captured
        } catch (_: Throwable) {
            false
        }
    }

    fun clear(context: Context): Boolean {
        var ok = false
        try {
            val f = file(context)
            ok = if (f.exists()) f.delete() else true
        } catch (_: Throwable) {
        }
        try {
            CookieManager.getInstance().removeAllCookies(null)
        } catch (_: Throwable) {
        }
        return ok
    }
}
