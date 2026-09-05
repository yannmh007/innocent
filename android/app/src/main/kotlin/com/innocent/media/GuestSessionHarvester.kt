package com.innocent.media

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * Gets an ordinary anonymous session from a site, with nothing on screen.
 *
 * WHY THIS REPLACES THE THING IT REPLACES:
 *
 * The device's own report made the pattern plain — the first YouTube link came
 * back with the full quality ladder, and every one after it came back with a
 * single 360p entry, while cookies read "none". That is not a broken extractor
 * or a stale engine, both of which the same report showed were fine. It is a
 * site handing a short leash to a caller it has no session for: a couple of
 * complete answers, then progressively less.
 *
 * A session fixes it, and — this is the part that matters — a session does NOT
 * require an account. Loading a site's front page in a real web view earns the
 * visitor cookies every first-time visitor receives. The earlier version made
 * that a button the user had to find after something had already failed. This
 * version does it before anything fails, and does it with no window, because
 * cookies are set by the network layer while the page loads, whether or not
 * anyone is looking at it.
 *
 * The result: nothing to maintain, nothing to configure, nothing to tap. Which
 * is the only shape of solution that survives contact with people who have
 * better things to do than administer a downloader.
 */
internal object GuestSessionHarvester {

    private val main = Handler(Looper.getMainLooper())

    /** Guards against two harvests running at once. */
    @Volatile
    private var running = false

    /** Give up rather than leave a web view alive forever on a dead network. */
    private const val TIMEOUT_MS = 20_000L

    /**
     * Some session cookies are written by a script that runs shortly after the
     * page reports itself finished. Leaving at that moment collects half of
     * them, which is worse than useless: a partial session still looks like a
     * stranger.
     */
    private const val SETTLE_MS = 2_500L

    private const val USER_AGENT =
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36"

    /**
     * Loads [url] off-screen and merges whatever cookies it yields for
     * [origins] into the shared jar. [onDone] receives true when something was
     * captured, and is always called exactly once.
     */
    @SuppressLint("SetJavaScriptEnabled")
    fun harvest(
        context: Context,
        url: String,
        origins: List<String>,
        onDone: (Boolean) -> Unit
    ) {
        if (running) {
            onDone(false)
            return
        }
        running = true

        main.post {
            var web: WebView? = null
            var settled = false

            fun finish(ok: Boolean) {
                if (settled) return
                settled = true
                val captured = if (ok) {
                    CookieJar.harvest(context, origins)
                } else {
                    false
                }
                try {
                    web?.apply {
                        stopLoading()
                        destroy()
                    }
                } catch (_: Throwable) {
                }
                web = null
                running = false
                onDone(captured)
            }

            try {
                // Built but never added to a view hierarchy. It still runs the
                // network stack and JavaScript, which is all that is needed —
                // cookies arrive in response headers, not in pixels.
                val view = WebView(context)
                web = view

                val cookies = CookieManager.getInstance()
                cookies.setAcceptCookie(true)
                try {
                    cookies.setAcceptThirdPartyCookies(view, true)
                } catch (_: Throwable) {
                }

                view.settings.apply {
                    javaScriptEnabled = true
                    domStorageEnabled = true
                    databaseEnabled = true
                    userAgentString = USER_AGENT
                    mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
                    // Nothing is displayed, so nothing needs to be fetched for
                    // display. This is a session, not a page view.
                    loadsImagesAutomatically = false
                    blockNetworkImage = true
                }
                view.webViewClient = object : WebViewClient() {
                    override fun onPageFinished(v: WebView?, finishedUrl: String?) {
                        super.onPageFinished(v, finishedUrl)
                        main.postDelayed({ finish(true) }, SETTLE_MS)
                    }
                }

                main.postDelayed({ finish(false) }, TIMEOUT_MS)
                view.loadUrl(url)
            } catch (_: Throwable) {
                // WebView can be unavailable while the system updates it.
                finish(false)
            }
        }
    }
}
