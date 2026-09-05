package com.innocent.media

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import java.io.File

/**
 * v0.99.7: sign in to a site inside Innocent, so the downloader can act as
 * you rather than as an anonymous stranger.
 *
 * WHY THIS EXISTS, and why it is the whole answer to the YouTube problem:
 *
 * The device's own evidence made it unambiguous. The engine reported version
 * 2026.07.04 — current — with both the muxer and the accelerator initialised,
 * and YouTube still answered "prove you are not a bot" and handed over nothing.
 * There was no stale component left to blame. What an anonymous request lacks
 * is a session, and no amount of updating supplies one.
 *
 * The engine already accepts a cookies.txt; the obstacle was purely that
 * producing one meant exporting it from a desktop browser, which is not a
 * thing a phone user is going to do. So the browser comes to them: sign in
 * here once, and the cookies are written out in the format the engine reads.
 *
 * DELIBERATELY A PLAIN ANDROID WEBVIEW. The in-app browser was deferred for a
 * long time because it was assumed to need a large Flutter plugin, with all
 * the version risk that carries for a project that already fights its native
 * build. For THIS job none of that is needed: WebView and CookieManager are
 * part of Android, the layout is built in code, and the whole feature adds
 * nothing to the dependency list.
 *
 * The cookie file never leaves the app's private storage, and signing out of
 * everything is one button in Settings.
 */
class SignInWebViewActivity : Activity() {

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_LABEL = "label"

        /**
         * URLs whose cookies get harvested when this session ends. The page
         * you sign in on is rarely the only origin that matters — a Google
         * sign-in leaves its state on accounts.google.com as well as on
         * youtube.com — so the caller passes every origin worth reading.
         */
        const val EXTRA_COOKIE_URLS = "cookieUrls"

        /**
         * Close by itself once the page has loaded and cookies exist.
         *
         * This is the no-login path. Simply LOADING youtube.com in a real
         * browser earns an anonymous guest session — the visitor cookies every
         * first-time visitor gets — and that is often the whole difference
         * between being treated as a browser and being treated as a script.
         * No account, no typing, nothing to remember.
         */
        const val EXTRA_AUTO_CLOSE = "autoClose"

        /** Shared Netscape cookie jar, in the app's private storage. */
        fun cookiesFile(context: Context): File = CookieJar.file(context)
    }

    private var webView: WebView? = null
    private var cookieUrls: List<String> = emptyList()
    private var autoClose = false
    private var closed = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val startUrl = intent.getStringExtra(EXTRA_URL) ?: "https://www.google.com"
        val label = intent.getStringExtra(EXTRA_LABEL) ?: ""
        cookieUrls = intent.getStringArrayExtra(EXTRA_COOKIE_URLS)?.toList()
            ?: listOf(startUrl)
        autoClose = intent.getBooleanExtra(EXTRA_AUTO_CLOSE, false)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.parseColor("#101010"))
            setPadding(dp(12), dp(10), dp(8), dp(10))
        }
        val caption = TextView(this).apply {
            text = when {
                autoClose -> "Preparing…"
                label.isEmpty() -> "Sign in"
                else -> "Sign in to $label"
            }
            setTextColor(Color.WHITE)
            textSize = 15f
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        }
        val done = Button(this).apply {
            text = "Done"
            setTextColor(Color.parseColor("#3B82F6"))
            setBackgroundColor(Color.TRANSPARENT)
            setOnClickListener { finishAndSave() }
        }
        bar.addView(caption)
        bar.addView(done)

        val progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(3)
            )
        }

        val web = WebView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f
            )
        }
        webView = web

        val cookieManager = CookieManager.getInstance()
        cookieManager.setAcceptCookie(true)
        cookieManager.setAcceptThirdPartyCookies(web, true)

        web.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            loadWithOverviewMode = true
            useWideViewPort = true
            javaScriptCanOpenWindowsAutomatically = true
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            // Sign-in pages refuse anything that looks automated, and the
            // default WebView agent advertises itself as one.
            userAgentString =
                "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36"
        }
        web.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                // Persist as we go: if the process is killed on a low-memory
                // device mid-session, what was already granted survives.
                val captured = harvestCookies()
                if (autoClose && captured && !closed) {
                    closed = true
                    // A beat of grace: some of the session cookies are set by
                    // a script that runs just after the page reports finished,
                    // and leaving immediately catches only half of them.
                    view?.postDelayed({ finishAndSave() }, 1200L)
                }
            }
        }
        web.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress >= 100) View.GONE else View.VISIBLE
            }
        }

        root.addView(bar)
        root.addView(progress)
        root.addView(web)
        setContentView(root)

        web.loadUrl(startUrl)
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        val web = webView
        if (web != null && web.canGoBack()) {
            web.goBack()
            return
        }
        // Back is a normal way to leave, so it saves too — losing a sign-in
        // because the wrong exit was used would be its own bug.
        finishAndSave()
    }

    private fun finishAndSave() {
        harvestCookies()
        setResult(RESULT_OK)
        finish()
    }

    /**
     * Writes what the WebView holds into a Netscape cookie file, merging with
     * anything already saved so signing into a second site doesn't erase the
     * first.
     *
     * CookieManager only hands back `name=value` pairs, with no domain, path
     * or expiry attached, so those are reconstructed: the origin's host with a
     * leading dot, root path, secure, and a year out. That is what every
     * cookie exporter does, and it is what the engine expects to read.
     */
    /** Returns true when at least one cookie was captured. */
    private fun harvestCookies(): Boolean = CookieJar.harvest(this, cookieUrls)

    override fun onDestroy() {
        try {
            webView?.apply {
                stopLoading()
                (parent as? ViewGroup)?.removeView(this)
                destroy()
            }
        } catch (_: Throwable) {
        }
        webView = null
        super.onDestroy()
    }
}
