package com.innocent.media

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView

/**
 * The browser that keeps people inside Innocent.
 *
 * Tapping a site used to hand the person to Chrome, which is where the job
 * quietly stopped being ours: they find a video in someone else's app, then
 * have to remember to copy the address, come back, and paste it. Every one of
 * those steps is a place to give up, and none of them exist in the downloaders
 * people compare this one to. A site tile should open a page, and the page
 * should have a Download button on it.
 *
 * THIS ALSO FIXES SOMETHING THE READER COULD NOT FIX ALONE. Several sites —
 * PornHub and TikTok among them — sit behind a challenge that inspects how the
 * connection itself is made, not just what it asks for. The engine's answer to
 * that is a library which is unavailable on Android, so those sites answer
 * plain requests with 403 Forbidden no matter how good our headers are. A real
 * browser passes that challenge as a matter of course, because it IS a real
 * browser, and the cookies it is given afterwards are accepted from anything
 * that presents them. So visiting a page here and then pressing Download hands
 * the reader a session it could never have obtained by itself.
 *
 * Written against the platform WebView rather than a plugin, matching
 * SignInWebViewActivity next door: no new dependency, no build risk, and the
 * cookie store is shared with the rest of the app for free.
 *
 * ---------------------------------------------------------------------------
 * v1.27.0 — THE BUTTON NOW WATCHES THE PLAYER, NOT THE NETWORK.
 *
 * Everything above stayed true and the feature still felt wrong, for one
 * reason: the button appeared the instant ANY media address went past, and on
 * every site this screen exists for the first media address of a page is the
 * pre-roll advert. So the button arrived during the advert, and pressing it
 * downloaded the advert — which the device trail proved twice over, two
 * PornHub downloads that finished in ten seconds each.
 *
 * v1.26.0 answered that AFTER the fact, by reading two streams and keeping the
 * longer one. That works, and it is kept as a backstop, but it costs an extra
 * extraction and it cannot stop the button from appearing too early — which is
 * the part somebody actually sees.
 *
 * The honest place to ask "is the main video playing" is the player itself.
 * A tiny script rides along with every page and reports what the video element
 * is doing: whether it is playing, how long it is, and whether the page is
 * showing one of the advert markers a video player puts in the DOM while an
 * advert runs. From that the button can appear at the right moment and — just
 * as importantly — the addresses seen FROM that moment are the feature's
 * addresses, which removes the guessing from the download too.
 */
class BrowserActivity : Activity() {

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_TITLE = "title"

        /** Labels are passed in so this file holds no user-facing English. */
        const val EXTRA_LABEL_DOWNLOAD = "labelDownload"
        const val EXTRA_LABEL_HINT = "labelHint"
        const val EXTRA_LABEL_WORKING = "labelWorking"
        const val EXTRA_LABEL_PICK = "labelPick"
        const val EXTRA_LABEL_STARTED = "labelStarted"
        const val EXTRA_LABEL_NOSOUND = "labelNoSound"

        /** v1.27.0 labels: the always-available manual path and its failures. */
        const val EXTRA_LABEL_STREAMS = "labelStreams"
        const val EXTRA_LABEL_UNREADABLE = "labelUnreadable"
        const val EXTRA_LABEL_RETRY = "labelRetry"
        const val EXTRA_LABEL_SENDSCREEN = "labelSendScreen"

        /** The YouTube player clients the Dart side is configured with. */
        const val EXTRA_CLIENTS = "clients"

        /** Explanations for the two ways a network can be the real problem. */
        const val EXTRA_LABEL_BLOCKED = "labelBlocked"
        const val EXTRA_LABEL_VPNHINT = "labelVpnHint"
        const val EXTRA_LABEL_DNSHINT = "labelDnsHint"
        const val EXTRA_LABEL_OPENSETTINGS = "labelOpenSettings"
        const val EXTRA_LABEL_MORE = "labelMore"
        const val EXTRA_LABEL_DNSFOUND = "labelDnsFound"
        const val EXTRA_LABEL_DEEPER = "labelDeeper"
        const val EXTRA_LABEL_BYPASS = "labelBypass"
        const val EXTRA_LABEL_BYPASSHINT = "labelBypassHint"
        const val EXTRA_LABEL_VPNGONE = "labelVpnGone"
        const val EXTRA_LABEL_YTWALL = "labelYtWall"
        const val EXTRA_LABEL_YTEMBED = "labelYtEmbed"
        const val EXTRA_LABEL_YTSIGNIN = "labelYtSignIn"

        /** Selector that means "read this page properly", not a format. */
        private const val SELECTOR_MORE = "__more__"
    }

    private var web: WebView? = null

    /** Host of the page this browser was opened for; names the saved icon. */
    private var tileHost: String? = null

    /**
     * One media address, when it turned up, and what the page called it.
     *
     * [label] is only ever set for an address the PAGE DECLARED — read out of
     * the player's own configuration rather than caught going past on the
     * network. That distinction is the whole point of it: a declared address
     * comes with the site's own name for the quality, which is better than any
     * name we could infer and available before a single byte of video is
     * fetched.
     */
    private data class Hit(val url: String, val at: Long, val label: String = "")

    /**
     * Media addresses seen while the page loaded, newest last.
     *
     * THIS IS THE PART THAT MAKES THE HARD SITES WORK, and it is what the
     * downloaders this one is compared to have always done.
     *
     * PornHub answers the engine with 403 even when we hand it the session
     * cookies a real browser earned — the device trail proves it, because the
     * jar had pornhub cookies and the read still failed. The check is on how
     * the connection is made, and cookies cannot argue with that.
     *
     * But the page itself plays perfectly well in here, which means the video
     * address passed through this WebView. Every request a page makes goes
     * through shouldInterceptRequest, so we simply write down the ones that
     * look like media. Handing THAT address to the engine skips extraction
     * altogether: it is a plain file fetch, which the engine is very good at,
     * and it needs no impersonation because there is nothing left to
     * impersonate.
     *
     * EACH ONE NOW CARRIES THE TIME IT ARRIVED, which is what lets the advert
     * be separated from the feature without guessing: the moment the player
     * reports that the main video is running is a line drawn through this
     * list, and everything after that line belongs to the video somebody
     * chose.
     *
     * Bounded, because a long page can make hundreds of requests and none of
     * this is worth memory pressure.
     */
    private val sniffed = java.util.Collections.synchronizedList(
        mutableListOf<Hit>()
    )

    private var grabButton: TextView? = null
    private var streamsButton: ImageButton? = null
    private var labelDownloadText: String = "Download"
    private var labelWorkingText: String = "Reading…"
    private var labelHintText: String = "Open a video, then tap the button below."
    private var labelPickText: String = "Choose quality"
    private var labelStartedText: String = "Added to downloads"
    private var labelNoSoundText: String = "no sound"
    private var labelStreamsText: String = "Detected media"
    private var labelUnreadableText: String = "This page could not be read"
    private var labelRetryText: String = "Try again"
    private var labelSendScreenText: String = "Open in Downloads"
    private var labelBlockedText: String = "This site would not load"
    private var labelVpnHintText: String = "A VPN is on. Some sites refuse VPN addresses."
    private var labelDnsHintText: String = "Set Private DNS to unblock sites without a VPN"
    private var labelOpenSettingsText: String = "Open settings"
    private var labelMoreText: String = "Look for more qualities…"
    private var labelDnsFoundText: String =
        "This network blocks the site by name. Private DNS fixes that."
    private var labelDeeperText: String =
        "The block is not in the name lookup, so a VPN is the way in."

    private var labelYtWallText: String = "This video will not play on this network"
    private var labelYtEmbedText: String = "Play without signing in"
    private var labelYtSignInText: String = "Sign in to YouTube"

    private var labelBypassText: String = "Open it anyway, without a VPN"
    private var labelBypassHintText: String = "Innocent looks the address up itself"
    private var labelVpnNotNeededText: String =
        "The blocked sites open without a VPN now — turn it off and YouTube works too"

    /** The HOST the network sheet was last shown for, and when. */
    private var troubleShownFor: String = ""
    private var troubleShownAt: Long = 0L

    /** The address the playback-refused sheet was last shown for. */
    private var wallShownFor: String = ""

    /**
     * True when the page itself failed to load, not the read.
     *
     * A page that never arrived and a page that arrived but could not be read
     * are different problems with different repairs, and the failure sheet was
     * only ever equipped to talk about the second.
     */
    @Volatile
    private var pageLoadError: String = ""

    /**
     * The player clients to ask YouTube as, handed over at launch.
     *
     * NOT OPTIONAL, and its absence was the whole of the v1.27.0 YouTube
     * regression. A page read with no `player_client` is answered as
     * whatever yt-dlp defaults to, which needs a PO token, which is the bot
     * wall -- so the change that finally let the browser ASK about a
     * YouTube page is what stopped the answer ever being usable.
     */
    private var playerClients: String? = null

    /** Title of the page, filled in by the probe so the row reads properly. */
    private var pageTitle: String = ""

    /** How many formats the engine returned, for the trail. */
    private var rawFormatCount: Int = 0

    /** Adverts refused on this page, for the trail. */
    @Volatile
    private var adsBlocked: Int = 0

    /**
     * Why the last read produced nothing, in words — or null if it worked.
     *
     * The previous note could not tell "the reply had no qualities in it" from
     * "reading the reply threw", because both left the counter at nought and
     * both printed the same sentence. Two different faults wearing one message
     * is how a second round of testing gets spent learning nothing, which is
     * exactly what happened. They are separated now, and the reply's top-level
     * KEYS travel with the message so its shape can be seen rather than
     * guessed at — the shape was the whole answer last time.
     */
    private var lastParseError: String? = null

    /**
     * How long the video just read actually runs, in seconds.
     *
     * THIS IS THE ONLY HONEST WAY TO TELL AN ADVERT FROM THE FEATURE ONCE THE
     * ENGINE HAS SPOKEN. The device trail showed it plainly: two downloads
     * from PornHub finished in ten seconds each and offered a single nameless
     * quality, while the one from XVideos took thirty-three seconds and
     * offered three proper resolutions. Ten seconds is not a video somebody
     * wanted; it is the pre-roll.
     *
     * Kept as the BACKSTOP now rather than the first line of defence — the
     * player is asked first, because the player knows before any extraction
     * has happened and therefore before the button has had to decide whether
     * to appear.
     */
    private var lastDuration: Double = 0.0

    /**
     * Anything shorter than this is treated as an advert when a longer stream
     * is available. Well past any pre-roll, well short of any real video.
     */
    private val AD_SECONDS = 90.0

    // ---------------------------------------------------------------- watcher

    /** True when the player says the MAIN video — not an advert — is running. */
    @Volatile
    private var mainVideoLive: Boolean = false

    /**
     * When the main video was first seen running, in system-clock millis.
     *
     * This is the line drawn through [sniffed]. An advert's addresses arrive
     * before it; the feature's arrive after. A few seconds of slack are
     * allowed backwards because a player asks for the master playlist while it
     * is still deciding to play, so the very address we want can be a
     * heartbeat older than the first frame.
     */
    @Volatile
    private var mainVideoSince: Long = 0L

    /** Longest duration any video on this page has reported. */
    @Volatile
    private var maxSeenDuration: Double = 0.0

    /** What the player last said, for the diagnostics trail. */
    @Volatile
    private var lastWatchNote: String = ""

    /** A video is running — whether or not we believe it is the main one. */
    @Volatile
    private var videoPlaying: Boolean = false

    /**
     * True once the injected script has said ANYTHING about this page.
     *
     * THE DIFFERENCE BETWEEN "no video is playing" AND "we cannot see the
     * page", which from the outside look identical: no button, no explanation.
     * A page can refuse the script outright — a strict content policy will do
     * it — and when that happens every rule built on what the player reports is
     * quietly dead rather than wrong. Something has to notice.
     */
    @Volatile
    private var watcherHeard: Boolean = false

    /** Set when the script has stayed silent long enough to be presumed dead. */
    @Volatile
    private var watcherSilent: Boolean = false

    /** How many video elements the page has, for the trail. */
    @Volatile
    private var lastVideoCount: Int = 0

    /** Whether the page is showing an advert marker, for the trail. */
    @Volatile
    private var lastAdMarker: Boolean = false

    /** Seconds of the video currently loaded, for the trail. */
    @Volatile
    private var lastReportedDuration: Double = 0.0

    /**
     * How long the PAGE says its video is, from `og:duration` or JSON-LD.
     *
     * THE SIGNAL THAT WAS MISSING, and the device trail showed exactly what it
     * costs to lack it: on XNXX the button appeared over an eleven-second
     * pre-roll, because the rule only calls something short an advert once the
     * page has ALREADY shown something longer — and the advert plays first, so
     * on the first video of a visit there is nothing longer yet.
     *
     * The page knew all along. It publishes the real running time in its own
     * metadata before a frame of anything has played, so an eleven-second clip
     * on a page that says four hundred and ninety-three seconds is settled
     * without waiting to be shown the difference.
     */
    @Volatile
    private var pageDeclaredDuration: Double = 0.0

    /** The last line sent to the trail, so the same fact is not repeated. */
    @Volatile
    private var lastTrail: String = ""

    private val ui = android.os.Handler(android.os.Looper.getMainLooper())

    /**
     * Says why there is no button yet, once waiting has stopped being normal.
     *
     * THE WHOLE POINT OF THIS RELEASE. A report that reads "browser opened"
     * and then nothing is a report that cannot be acted on: the button not
     * appearing could be the script being refused, the advert rule being too
     * strict, the page having no video, or the sniffer catching nothing, and
     * those are four different repairs. Twelve seconds after a page settles,
     * the browser now writes down which one it is.
     */
    private val verdict = Runnable { reportWhyNoButton() }

    /** How much slack to allow behind the first frame of the main video. */
    private val MARK_SLACK_MS = 9000L

    /**
     * The address the collected list currently belongs to.
     *
     * A GUARD, NOT A CONVENIENCE. `doUpdateVisitedHistory` fires on ordinary
     * page loads as well as on single-page navigations, and on some sites it
     * arrives after the page has already started requesting its media. A reset
     * at that moment would throw away the stream we are here for, on a page
     * nobody had navigated away from -- an intermittent, unreproducible "the
     * button never appears". Comparing the address first makes the reset mean
     * "somewhere else", which is the only thing it was ever meant to mean.
     */
    @Volatile
    private var lastKnownUrl: String = ""

    /**
     * Sites the engine reads BETTER from the page address than from a sniffed
     * stream, so sniffing is not even consulted for them.
     *
     * YouTube is the reason this exists and it was a real hole: YouTube serves
     * its media from `/videoplayback` with no file extension at all, so the
     * sniffer collected nothing, so the button never appeared and the whole
     * in-page flow was unavailable on the one site Myanmar phones without
     * Google services depend on. It was never a YouTube problem — a page whose
     * address the extractor handles perfectly was being asked the hard way.
     *
     * For all of these the page URL is both more reliable and richer: it
     * carries every quality, the real title, and the subtitles.
     */
    private val pageFirstHosts = listOf(
        "youtube.com", "youtu.be", "m.youtube.com", "music.youtube.com",
        // The embed player lives here, and a video played through it must still
        // be readable by the same route as one played on the watch page.
        "youtube-nocookie.com",
        "tiktok.com", "instagram.com", "facebook.com", "fb.watch",
        "twitter.com", "x.com", "vimeo.com", "dailymotion.com",
        "reddit.com", "twitch.tv", "bilibili.com", "soundcloud.com"
    )

    /**
     * Writes one line to the diagnostics trail, never the same line twice.
     *
     * Deduplicated because the watcher speaks twice a second and a trail that
     * scrolls is a trail nobody reads.
     */
    private fun trail(message: String) {
        if (message == lastTrail) return
        lastTrail = message
        try {
            DownloadEngine.sendBrowserNote(message)
        } catch (_: Throwable) {
        }
    }

    /**
     * True for an address that is a single video rather than a listing.
     *
     * Used only to decide whether the relaxed page-first rule may apply, so it
     * is deliberately narrow: a feed, a channel or a search result must not
     * qualify, because on those the page address is not something the reader
     * could ever turn into a file.
     */
    private fun looksLikeWatchPage(url: String?): Boolean {
        val u = url?.lowercase() ?: return false
        return u.contains("/watch") || u.contains("/shorts/") ||
            // PornHub and its family: `view_video.php?viewkey=…`. The verdict
            // line called those "not a video page", which is both wrong and
            // the sort of wrong that sends the next investigation sideways.
            u.contains("viewkey=") || u.contains("view_video") ||
            // `/video-1234/title` on XNXX, `/videos/…` elsewhere. Matching the
            // bare word rather than a slashed path is why the trail called a
            // real XNXX video page "not a video page".
            u.contains("/video") ||
            u.contains("youtu.be/") || u.contains("/video/") ||
            u.contains("/photo/") || u.contains("/reel/") ||
            u.contains("/status/") || u.contains("/videos/") ||
            u.contains("/v/") || u.contains("/embed/")
    }

    /** True when the engine should be given the page rather than a stream. */
    private fun prefersPageUrl(url: String?): Boolean {
        val host = prettyHost(url)?.lowercase() ?: return false
        return pageFirstHosts.any { host == it || host.endsWith(".$it") }
    }

    /**
     * The script that rides along with every page.
     *
     * Deliberately small and deliberately dumb: it REPORTS, it does not
     * DECIDE. Everything that could be wrong about "is this an advert" is
     * decided in Kotlin, where it can be read, changed and reasoned about in
     * one place — a policy spread across two languages is a policy that
     * drifts, and this file has already paid for that lesson twice.
     *
     * No template literals and no dollar signs anywhere in here: this is a
     * Kotlin raw string, and a dollar sign in one is an interpolation.
     */
    private val watchJs = """
(function(){
  if (window.__innoWatch) { return; }
  window.__innoWatch = true;
  var lastSend = '';
  var lastHref = location.href;
  var beats = 0;

  function adMarker(){
    try {
      var mp = document.getElementById('movie_player');
      if (mp && mp.classList) {
        if (mp.classList.contains('ad-showing')) { return true; }
        if (mp.classList.contains('ad-interrupting')) { return true; }
      }
      if (document.querySelector('.ytp-ad-player-overlay')) { return true; }
      if (document.querySelector('.ytp-ad-skip-button')) { return true; }
      if (document.querySelector('.ytp-ad-preview-container')) { return true; }
      var mod = document.querySelector('.video-ads.ytp-ad-module');
      if (mod && mod.children && mod.children.length > 0 && mod.offsetHeight > 0) { return true; }
      var vast = document.querySelector('.vast-blocker, .ima-ad-container, .videoAdUiSkipButton, [id^=vast], [class*=preroll]');
      if (vast && vast.offsetHeight > 0) { return true; }
    } catch (e) {}
    return false;
  }

  function pick(){
    var best = null;
    var bestArea = -1;
    try {
      var vs = document.getElementsByTagName('video');
      for (var i = 0; i < vs.length; i++) {
        var v = vs[i];
        var area = (v.clientWidth || 0) * (v.clientHeight || 0);
        if (!v.paused && !v.ended && v.readyState > 1) { area = area + 5000000; }
        if (area > bestArea) { bestArea = area; best = v; }
      }
    } catch (e) {}
    return best;
  }

  function tick(){
    try {
      if (location.href !== lastHref) {
        lastHref = location.href;
        // THE DEDUPE MUST NOT OUTLIVE THE PAGE. Kotlin clears what it knows
        // on a navigation; if this side keeps saying "same as last time" the
        // two disagree, and the browser concludes the script was refused when
        // it is sitting right here reporting nothing.
        lastSend = '';
        InnocentWatch.navigated(lastHref);
      }
      // A HEARTBEAT, SO SILENCE MEANS SILENCE. Roughly every five seconds the
      // dedupe is dropped and the current state is sent again, whatever it is.
      // Without it, a page whose state never changes looks identical to a page
      // that refused the script — and those need opposite repairs.
      beats = beats + 1;
      if (beats % 10 === 0) { lastSend = ''; }
      var v = pick();
      if (!v) {
        if (lastSend !== 'none') { lastSend = 'none'; InnocentWatch.report(0, 0, 0, false, 0); }
        return;
      }
      var d = (isFinite(v.duration) && v.duration > 0) ? v.duration : 0;
      var t = (isFinite(v.currentTime) && v.currentTime > 0) ? v.currentTime : 0;
      var playing = (!v.paused && !v.ended && v.readyState > 1);
      var ad = adMarker();
      var n = document.getElementsByTagName('video').length;
      // THE PLAYER SAYING IT CANNOT PLAY, in whatever language the person
      // reads. The ytp-error element is the overlay YouTube puts up when
      // refused — including the bot check — and testing for the ELEMENT rather
      // than for English text is the only way this works for somebody using
      // YouTube in Burmese.
      try {
        var blocked = document.querySelector('.ytp-error') ||
          document.querySelector('ytd-enforcement-message-view-model') ||
          document.querySelector('yt-playability-error-supported-renderers');
        if (blocked && !window.__innoWalled) {
          window.__innoWalled = true;
          InnocentWatch.playbackBlocked(location.href);
        }
        if (!blocked) { window.__innoWalled = false; }
      } catch (e9) {}
      var key = (playing ? '1' : '0') + ':' + Math.round(d) + ':' + Math.round(t) + ':' + (ad ? '1' : '0');
      if (key === lastSend) { return; }
      lastSend = key;
      InnocentWatch.report(playing ? 1 : 0, d, t, ad, n);
    } catch (e) {}
  }

  setInterval(tick, 500);
  tick();
})();
"""

    /**
     * Reads the video addresses the page has WRITTEN DOWN, rather than waiting
     * to catch them going past.
     *
     * THIS IS HOW THE FAST DOWNLOADERS ARE FAST, and it is the difference
     * between a ten-second extraction and a sheet that is simply there. Every
     * one of these sites hands its player a list of qualities in plain sight:
     *
     *   • XVideos and XNXX (same player) write it inline —
     *     `html5player.setVideoUrlHigh('…mp4')`, `setVideoUrlLow`, `setVideoHLS`.
     *   • PornHub puts it in a `flashvars_<id>` global, as `mediaDefinitions`
     *     with a `quality` and a `videoUrl` for each rung.
     *   • xHamster keeps `initials.videoModel.sources.mp4` as quality → address.
     *   • Anything else, generically: the playing element, its `<source>`
     *     children, `og:video`, and a JSON-LD `contentUrl`.
     *
     * The site has already decided what the qualities are and named them. Our
     * job is to read, not to guess — a label of "1080p" from the player beats
     * anything inferred from a file name, and it costs nothing.
     *
     * Scanned three times: once on arrival and twice after, because a player
     * that has not started yet has not written its configuration and a page
     * scanned too early reports nothing. Deliberately not on a timer — this
     * is not something that keeps changing.
     *
     * No dollar signs and no backticks: Kotlin raw string.
     */
    private val harvestJs = """
(function(){
  if (window.__innoHarvest) { return; }
  window.__innoHarvest = true;
  function send(u, label){
    try {
      if (!u || typeof u !== 'string') { return; }
      if (u.indexOf('http') !== 0) { return; }
      InnocentWatch.found(u, label || '');
    } catch (e) {}
  }
  function pageDuration(){
    try {
      var m = document.querySelector('meta[property="og:duration"], meta[property="video:duration"], meta[itemprop=duration]');
      if (m) {
        var c = m.getAttribute('content') || '';
        if (/^[0-9]+(\.[0-9]+)?/.test(c)) { return parseFloat(c); }
        var iso = c.match(/PT(?:([0-9]+)H)?(?:([0-9]+)M)?(?:([0-9]+)S)?/);
        if (iso) {
          return (parseInt(iso[1] || 0, 10) * 3600) +
                 (parseInt(iso[2] || 0, 10) * 60) +
                 parseInt(iso[3] || 0, 10);
        }
      }
      var lds = document.querySelectorAll('script[type="application/ld+json"]');
      for (var i = 0; i < lds.length; i++) {
        try {
          var arr = [].concat(JSON.parse(lds[i].textContent));
          for (var j = 0; j < arr.length; j++) {
            var d = arr[j] && arr[j].duration;
            if (typeof d === 'string') {
              var q = d.match(/PT(?:([0-9]+)H)?(?:([0-9]+)M)?(?:([0-9]+)S)?/);
              if (q) {
                return (parseInt(q[1] || 0, 10) * 3600) +
                       (parseInt(q[2] || 0, 10) * 60) +
                       parseInt(q[3] || 0, 10);
              }
            }
          }
        } catch (e0) {}
      }
    } catch (e1) {}
    return 0;
  }

  function scan(){
    try {
      var pd = pageDuration();
      if (pd > 0) { try { InnocentWatch.pageLength(pd); } catch (e7) {} }
      var vs = document.getElementsByTagName('video');
      for (var i = 0; i < vs.length; i++) {
        var v = vs[i];
        if (v.currentSrc && v.currentSrc.indexOf('blob:') !== 0) { send(v.currentSrc, ''); }
        var ss = v.getElementsByTagName('source');
        for (var j = 0; j < ss.length; j++) {
          send(ss[j].src, ss[j].getAttribute('label') || ss[j].getAttribute('data-quality') || '');
        }
      }
      var metas = document.querySelectorAll('meta[property="og:video"], meta[property="og:video:secure_url"], meta[itemprop=contentURL]');
      for (var k = 0; k < metas.length; k++) { send(metas[k].content, ''); }
      var lds = document.querySelectorAll('script[type="application/ld+json"]');
      for (var m = 0; m < lds.length; m++) {
        try {
          var arr = [].concat(JSON.parse(lds[m].textContent));
          for (var n = 0; n < arr.length; n++) {
            if (arr[n] && arr[n].contentUrl) { send(arr[n].contentUrl, ''); }
          }
        } catch (e2) {}
      }
      for (var key in window) {
        if (key.indexOf('flashvars_') !== 0) { continue; }
        try {
          var defs = window[key] && window[key].mediaDefinitions;
          if (!defs || !defs.length) { continue; }
          for (var d = 0; d < defs.length; d++) {
            var q = defs[d].quality;
            if (q && typeof q !== 'string' && q.length) { q = q[q.length - 1]; }
            var u = defs[d].videoUrl;
            if (!u) { continue; }
            // THE LADDER IS BEHIND ONE MORE DOOR. PornHub gives the mp4 entry
            // an API address rather than a file, and the JSON it returns is
            // the actual list of qualities. The page is allowed to ask its own
            // site for that; we are not, from Kotlin, without the session. So
            // it is fetched here, where the cookies already are.
            if (u.indexOf('get_media') !== -1 || u.indexOf('/media?') !== -1) {
              (function(addr){
                try {
                  fetch(addr, { credentials: 'include' })
                    .then(function(r){ return r.json(); })
                    .then(function(list){
                      var items = [].concat(list || []);
                      for (var n = 0; n < items.length; n++) {
                        var it = items[n];
                        if (!it || !it.videoUrl) { continue; }
                        var qq = it.quality;
                        if (qq && typeof qq !== 'string' && qq.length) { qq = qq[qq.length - 1]; }
                        send(it.videoUrl, qq ? (qq + 'p') : '');
                      }
                    })
                    .catch(function(){});
                } catch (e8) {}
              })(u);
              continue;
            }
            send(u, q ? (q + 'p') : '');
          }
        } catch (e3) {}
      }
      try {
        // xHamster keeps its ladder under sources, and WHICH KEY it uses has
        // moved: mp4 on the old player, h264 and av1 on the new one, plus hls
        // for the playlist. The trail showed the cost of reading only the
        // first: a lone 720p.av1.mp4.m3u8 VARIANT reached the reader and came
        // back as one silent rendition. Every bucket is read now.
        var srcs = window.initials && window.initials.videoModel &&
          window.initials.videoModel.sources;
        if (!srcs && window.initials && window.initials.xplayerSettings) {
          srcs = window.initials.xplayerSettings.sources;
        }
        if (srcs) {
          var buckets = ['mp4', 'h264', 'av1', 'standard'];
          for (var b = 0; b < buckets.length; b++) {
            var bucket = srcs[buckets[b]];
            if (!bucket) { continue; }
            for (var q2 in bucket) {
              var entry = bucket[q2];
              if (typeof entry === 'string') { send(entry, q2); }
              else if (entry && entry.url) { send(entry.url, entry.quality || q2); }
            }
          }
          if (srcs.hls) {
            for (var q3 in srcs.hls) {
              if (typeof srcs.hls[q3] === 'string') { send(srcs.hls[q3], ''); }
            }
          }
        }
      } catch (e4) {}
      try {
        var html = document.documentElement.innerHTML;
        var re = /setVideoUrl(High|Low)\('([^']+)'\)/g;
        var mm;
        while ((mm = re.exec(html)) !== null) { send(mm[2], mm[1] === 'High' ? 'High' : 'Low'); }
        var re2 = /setVideoHLS\('([^']+)'\)/g;
        while ((mm = re2.exec(html)) !== null) { send(mm[1], ''); }
      } catch (e5) {}
    } catch (e6) {}
  }
  scan();
  setTimeout(scan, 2500);
  setTimeout(scan, 6000);
})();
"""

    /**
     * Ad and tracker hosts, blocked before they can load.
     *
     * A blocked advert is an advert whose address is never requested, so the
     * page loads faster and the phone stays quieter. That is worth doing on
     * its own merits.
     *
     * BUT IT IS NOT THE ANSWER TO "no button during adverts", and believing it
     * was cost a release. These sites serve the pre-roll from the SAME
     * delivery machines as the feature — `ht-cdn2.adtng.com`,
     * `video.sacdnssedge.com` — so no host list can separate them, and a list
     * eager enough to try would block the film. The player is asked instead;
     * see [mainVideoLive].
     *
     * Matched on host SUFFIX, deliberately narrow: these are advertising and
     * analytics networks, not content hosts.
     */
    private val adHosts = listOf(
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com",
        "adservice.google.com", "imasdk.googleapis.com",
        "adnxs.com", "adsrvr.org", "rubiconproject.com", "pubmatic.com",
        "openx.net", "criteo.com", "taboola.com", "outbrain.com",
        "scorecardresearch.com", "quantserve.com", "moatads.com",
        "amazon-adsystem.com", "casalemedia.com", "sharethrough.com",
        "smartadserver.com", "3lift.com", "bidswitch.net", "yieldmo.com",
        // The advertising networks these particular sites actually use — taken
        // from the hosts seen in the device trail, not guessed.
        "exoclick.com", "exosrv.com", "juicyads.com", "trafficjunky.net",
        "trafficjunky.com", "adsco.re", "popads.net", "poptm.com",
        "hilltopads.net", "tsyndicate.com", "realsrv.com", "creative-serving.com",
        "adtng.com/ads", "ads.contentabc.com"
    )

    /**
     * Advertising and telemetry paths on hosts that also serve real content.
     *
     * YouTube is the case that matters: `youtube.com` cannot go on a host list
     * without taking the site with it, but `/pagead/`, `/ptracking` and the ad
     * statistics endpoints are pure overhead on a phone that is only here to
     * watch. Dropping them is a visible speed difference on the cheap devices
     * this app is built for, and nothing on the page depends on a reply.
     */
    private val adPaths = listOf(
        "/pagead/", "/ptracking", "/api/stats/ads", "/youtubei/v1/log_event",
        "/csi_204", "/pcs/activeview",
        // MORE OF THE SAME, and on a cheap phone this is felt rather than
        // measured. None of these returns anything the page draws: they are
        // playback telemetry, attestation pings and interaction logging, and
        // every one is a connection the device sets up, encrypts and tears
        // down while somebody is waiting for a video to start.
        "/api/stats/atr", "/api/stats/qoe", "/api/stats/playback",
        "/api/stats/watchtime", "/api/stats/delayplay",
        "/youtubei/v1/att/get", "/youtubei/v1/att/log",
        "/gen_204", "/error_204", "/log_interaction", "/qoe?"
    )

    /** True when this request is advertising rather than the page's content. */
    private fun isAdRequest(url: String): Boolean {
        val lower = url.lowercase()
        val host = try {
            Uri.parse(url).host?.lowercase()
        } catch (_: Throwable) {
            null
        } ?: return false
        if (adHosts.any { host == it || host.endsWith(".$it") || lower.contains(it) }) {
            return true
        }
        return adPaths.any { lower.contains(it) }
    }

    /**
     * A file name that is one PIECE of a stream rather than the stream.
     *
     * `seg-5-v1-a1.ts`, `frag12`, `chunk_3`, `init.mp4`. The trailing separator
     * or digit is what keeps this from eating a real video called `chunky.mp4`
     * -- after "chunk" comes a letter there, and the rule requires punctuation
     * or a number.
     */
    private val segmentName = Regex("^(seg|frag|chunk|init)([-_.]|[0-9])")

    /**
     * Extensions that mean "this is the video", in rough order of preference.
     *
     * READ THE LAST PATH COMPONENT, NOT THE WHOLE PATH -- and the old rule not
     * doing so is the worst bug this browser has had.
     *
     * `path.contains(".mp4")` matched ANYWHERE, and PornHub and xHamster serve
     * their HLS pieces out of a folder NAMED after the file:
     *
     *     em-h.phncdn.com/hls/videos/…/1080P_4000K_57004305.mp4/seg-5-v1-a1.ts
     *
     * So a four-second SEGMENT scored as an mp4, and when no playlist happened
     * to be inside the advert window `bestSniffed()` handed the newest one over
     * as if it were the film. The device trail caught it four times in one
     * session -- `read started · stream · …//seg-5-v1-a1.ts`, then `browser
     * pick · mp2t`, then `download finished` seconds later. Those files are
     * clips, and nobody would know why.
     *
     * Two rules now, in this order: a piece is never a target, and an extension
     * only counts where a file name can actually end.
     */
    private fun mediaKind(url: String): Int {
        val path = url.lowercase().substringBefore('?').substringBefore('#')
        val name = path.substringAfterLast('/')
        // A PIECE IS NEVER A TARGET. Checked first, because several of these
        // sit inside folders whose names would otherwise qualify them.
        if (name.endsWith(".ts") || name.endsWith(".m4s") ||
            name.endsWith(".aac") || name.endsWith(".vtt") ||
            name.endsWith(".key") || name.endsWith(".m3u8.txt")
        ) {
            return 0
        }
        if (segmentName.containsMatchIn(name)) return 0
        return when {
            name.endsWith(".m3u8") -> 3
            name.endsWith(".mpd") -> 3
            name.endsWith(".mp4") || name.endsWith(".webm") || name.endsWith(".m4v") -> 2
            // NO EXTENSION AT ALL, and this is how YouTube was invisible. Its
            // media comes from `/videoplayback?...`, which every extension rule
            // above misses, so the page could be playing at full volume with an
            // empty list behind it. Matched on the PATH because there is no
            // file name to match on.
            path.contains("/videoplayback") -> 2
            name.endsWith(".mov") || name.endsWith(".mkv") -> 1
            else -> 0
        }
    }
    private var urlLabel: TextView? = null
    private var progress: ProgressBar? = null

    /**
     * The view a player asks us to show when somebody taps fullscreen.
     *
     * THIS WAS SIMPLY MISSING, and it is the loudest way the in-app browser
     * failed to feel like the app it replaces. `WebChromeClient` only enters
     * fullscreen if the host handles `onShowCustomView`; without it the button
     * is there, it is pressed, and nothing happens. On a phone with no Google
     * services this browser IS YouTube, and a YouTube you cannot watch
     * fullscreen is not a substitute for anything.
     */
    private var fullscreenView: View? = null
    private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null
    private var savedOrientation: Int =
        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    private var fullscreenHolder: FrameLayout? = null

    /**
     * The bridge the page's script talks to.
     *
     * Everything arriving here is untrusted by definition — it comes from a
     * web page — so it is used only to decide whether OUR OWN button is
     * visible and which of OUR OWN recorded addresses to prefer. No address,
     * no title and no instruction is taken from it. The worst a hostile page
     * can do is make the button appear at the wrong time on its own site,
     * which it could achieve anyway by playing a video.
     */
    inner class Watch {
        @JavascriptInterface
        fun report(
            playing: Int,
            duration: Double,
            currentTime: Double,
            adShowing: Boolean,
            videoCount: Int
        ) {
            onWatch(playing == 1, duration, currentTime, adShowing, videoCount)
        }

        @JavascriptInterface
        fun navigated(href: String) {
            runOnUiThread { onSpaNavigation(href) }
        }

        /**
         * An address the PAGE declared, with the site's own name for it.
         *
         * Treated as data and nothing else, like everything else crossing this
         * bridge: it can put a row in our own sheet, and that is the entire
         * extent of its power. A hostile page could offer its own file — which
         * it could equally do by playing one.
         */
        @JavascriptInterface
        fun found(url: String, label: String) {
            onPageDeclared(url, label)
        }

        /**
         * The player put up an error instead of playing.
         *
         * On this connection that is nearly always the bot check, which the
         * site shows to addresses it does not trust rather than to people it
         * does not trust. Reported so the browser can offer the two things
         * that actually clear it, instead of leaving somebody staring at a
         * player that will not start.
         */
        @JavascriptInterface
        fun playbackBlocked(href: String) {
            runOnUiThread { onPlaybackBlocked(href) }
        }

        /** How long the page SAYS the video is, from its own metadata. */
        @JavascriptInterface
        fun pageLength(seconds: Double) {
            if (seconds > 0) pageDeclaredDuration = seconds
        }
    }

    /**
     * The whole advert policy, in one place.
     *
     * Three facts, each of which is something the player KNOWS rather than
     * something we deduce:
     *
     *  • A MARKER. YouTube states it outright — the player carries
     *    `ad-showing` while an advert runs, which is what every ad-skipping
     *    extension has keyed on for years. When a marker is present there is
     *    nothing to work out.
     *
     *  • A LENGTH THAT LOOKS LIKE A PRE-ROLL. Under a minute and a half, on a
     *    page that has already offered something substantially longer, is a
     *    pre-roll. Note the ordering that makes this safe: a short video on a
     *    page that has shown nothing longer is treated as REAL, because that
     *    is what a genuinely short video looks like and refusing to download
     *    those would be a worse failure than the one being fixed.
     *
     *  • A MOMENT'S PATIENCE. A player reports a duration before it reports a
     *    steady one, and a button that flickers on and off during the first
     *    second is worse than one that waits. Two seconds of playback, and no
     *    button until then.
     */
    private fun onWatch(
        playing: Boolean,
        duration: Double,
        currentTime: Double,
        adShowing: Boolean,
        videoCount: Int
    ) {
        watcherHeard = true
        watcherSilent = false
        videoPlaying = playing
        lastVideoCount = videoCount
        lastAdMarker = adShowing
        lastReportedDuration = duration
        if (duration > maxSeenDuration) maxSeenDuration = duration
        val settled = currentTime >= 2.0
        // Outgrown: this page has shown something half again as long as what
        // is playing now, so what is playing now is the short thing.
        // TWO WAYS TO KNOW, and the page's own figure is the better one
        // because it is available BEFORE the advert has finished. The other
        // rule can only fire once something longer has been seen, which on the
        // first video of a visit is never — which is how an eleven-second
        // pre-roll got a Download button on XNXX.
        val shorterThanPage = duration > 0.0 &&
            pageDeclaredDuration > 0.0 &&
            duration < pageDeclaredDuration * 0.5
        val outgrown = (duration > 0.0 &&
            duration < AD_SECONDS &&
            maxSeenDuration > duration * 1.5) || shorterThanPage
        val nowMain = playing && settled && !adShowing && !outgrown

        lastWatchNote = "player: " +
            (if (playing) "playing" else "idle") +
            " · " + duration.toInt() + "s" +
            (if (adShowing) " · ad marker" else "") +
            (if (outgrown) " · short clip" else "") +
            (if (pageDeclaredDuration > 0) " · page says " + pageDeclaredDuration.toInt() + "s" else "") +
            (if (videoCount > 1) " · " + videoCount + " players" else "")

        if (nowMain && !mainVideoLive) {
            mainVideoLive = true
            mainVideoSince = System.currentTimeMillis()
            trail("main video started · " + lastWatchNote)
        } else if (!nowMain && mainVideoLive && (adShowing || outgrown)) {
            // A MID-ROLL PUTS THE BUTTON AWAY AGAIN. Downloading during one
            // would take the advert, which is exactly the fault being fixed.
            // Pausing does NOT — somebody who pauses to read the quality list
            // must not watch the button vanish under their finger.
            mainVideoLive = false
        }
        runOnUiThread { updateButtons() }
        // THE SCREEN MUST NOT SLEEP DURING A VIDEO. A web page cannot ask for
        // that itself — only the host activity can — which is why watching a
        // long video in an in-app browser goes dark after a minute while the
        // same video in the real app does not. We already know exactly when
        // something is playing, so the fix costs one flag.
        runOnUiThread { keepAwake(playing) }
    }

    /** Holds the screen on, and lets it go again. */
    private fun keepAwake(on: Boolean) {
        try {
            if (on) {
                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        } catch (_: Throwable) {
        }
    }

    /**
     * A single-page navigation — YouTube's, mostly — which fires no page load.
     *
     * THIS WAS A SILENT AND SERIOUS BUG. `onPageStarted` is what cleared the
     * collected addresses, and on YouTube it fires once, when the app opens
     * the site. Every video watched after that added its addresses to a list
     * that still held the previous video's, so pressing Download on the third
     * video of an evening could hand over the first one's stream — with the
     * right title on the row, because the title came from the page.
     */
    private fun onSpaNavigation(href: String) {
        if (href == lastKnownUrl) return
        lastKnownUrl = href
        resetPageState()
        urlLabel?.text = prettyHost(href) ?: href
        // THE HARVEST HAS TO RUN AGAIN, and forgetting that would have made
        // the fast path work exactly once per visit. Its guard is a flag on
        // `window`, and a single-page navigation replaces the page's CONTENT
        // without replacing `window` — so the flag survives, the scan does not
        // re-run, and the second video of an evening quietly falls back to a
        // ten-second extraction with no sign that anything is wrong.
        //
        // The watcher and the tidying do not need this: an interval keeps
        // ticking and an injected stylesheet keeps applying. Only the harvest
        // reads a page's contents once.
        rescanPage()
        updateButtons()
    }

    /** The eleven-character id out of any shape of YouTube address. */
    private fun youTubeId(url: String?): String? {
        val u = url ?: return null
        val patterns = listOf(
            Regex("[?&]v=([A-Za-z0-9_-]{11})"),
            Regex("/embed/([A-Za-z0-9_-]{11})"),
            Regex("/shorts/([A-Za-z0-9_-]{11})"),
            Regex("youtu[.]be/([A-Za-z0-9_-]{11})")
        )
        for (r in patterns) {
            val m = r.find(u)
            if (m != null) return m.groupValues[1]
        }
        return null
    }

    /**
     * The same video, played through the embed player instead of the site.
     *
     * THE ONE FIX THAT NEEDS NEITHER AN ACCOUNT NOR A DIFFERENT NETWORK.
     * YouTube checks an embedded player far less suspiciously than it checks
     * the site — an embed is meant to be watched from anywhere, by anyone,
     * without signing in — so a video the watch page refuses very often plays
     * here. On a phone where the VPN cannot be turned off because the rest of
     * the browsing needs it, this is the difference between a working YouTube
     * and none.
     *
     * The no-cookie host is used deliberately: it is the same player with the
     * least tracking attached, which is also the version least likely to care
     * who is asking.
     */
    private fun embedUrlFor(url: String?): String? {
        val id = youTubeId(url) ?: return null
        return "https://www.youtube-nocookie.com/embed/" + id +
            "?autoplay=1&playsinline=1&rel=0"
    }

    /**
     * The canonical watch address for whatever YouTube page we are on.
     *
     * The reader is handed THIS rather than the embed address. Both work, but
     * the watch form is what the cookies, the referer and the extractor are
     * all set up around, and quietly changing which one we ask about depending
     * on how somebody happened to start playing is the kind of difference that
     * shows up weeks later as "it only works sometimes".
     */
    private fun canonicalWatch(url: String?): String? {
        val id = youTubeId(url) ?: return null
        return "https://www.youtube.com/watch?v=" + id
    }

    /**
     * The player refused to start. Offer the two things that actually help.
     *
     * Deliberately not automatic. Reloading somebody into a different player
     * without asking is the sort of thing that feels like a malfunction, and
     * the embed player has no comments, no description and no related videos —
     * a fair trade when the alternative is nothing, and a poor one imposed
     * without consent.
     */
    private fun onPlaybackBlocked(href: String) {
        if (isFinishing || isDestroyed) return
        val here = web?.url ?: href
        if (here == wallShownFor) return
        wallShownFor = here
        // AN EMBED THAT IS ITSELF REFUSED HAS NOTHING LEFT TO OFFER. The
        // trail shows both, seconds apart: the watch page refused, then
        // youtube-nocookie refused as well. Offering the same escape a second
        // time from inside it is the app repeating itself at somebody.
        //
        // What IS true on this phone is that the VPN has stopped being needed
        // — the blocked sites open without it now — so that is what gets said.
        val alreadyEmbedded = here.contains("/embed/") ||
            (prettyHost(here)?.contains("nocookie") == true)
        val embed = if (alreadyEmbedded) null else embedUrlFor(here)
        trail(
            "playback refused · " + (prettyHost(here) ?: "") +
                (if (onVpn()) " · VPN on" else "") +
                (if (embed != null) " · embed offered" else "")
        )
        val shell = sheetShell(labelYtWallText)
        val sheet = shell.first
        val body = shell.second
        if (embed != null) {
            sheetRow(body, labelYtEmbedText, "") {
                sheet.dismiss()
                web?.loadUrl(embed)
            }
        }
        sheetRow(body, labelYtSignInText, "") {
            sheet.dismiss()
            // SIGNED IN IS NOT NETWORK-BOUND. A visitor session is judged by
            // where it came from; an account is judged by whose it is, and
            // travels. Done in THIS browser so the cookies land in the same
            // store everything else already uses.
            web?.loadUrl(
                "https://accounts.google.com/ServiceLogin" +
                    "?service=youtube&continue=https://m.youtube.com/"
            )
        }
        if (onVpn()) {
            sheetRow(body, labelVpnHintText, "")
            if (DnsBypassProxy.isRunning) sheetRow(body, labelVpnNotNeededText, "")
        }
        sheetRow(body, labelRetryText, "") {
            sheet.dismiss()
            wallShownFor = ""
            web?.reload()
        }
        sheet.show()
    }

    /**
     * Points every WebView in this app at our own proxy, or back at nothing.
     *
     * `ProxyController` is the only API that can do this. Every other route —
     * the reflection tricks that circulate — stopped working years ago, which
     * is why `androidx.webkit` is a dependency at all. Gated on the WebView
     * actually supporting it, because on an ancient WebView the call throws
     * and a browser that crashes on a blocked site is worse than one that
     * cannot open it.
     *
     * Loopback is bypassed so our own stream proxy is not routed through this
     * one, which would be a loop with a spare hop in it.
     */
    private fun applyProxy(port: Int) {
        try {
            if (!androidx.webkit.WebViewFeature.isFeatureSupported(
                    androidx.webkit.WebViewFeature.PROXY_OVERRIDE
                )
            ) {
                trail("this WebView cannot be pointed at a proxy")
                return
            }
            val controller = androidx.webkit.ProxyController.getInstance()
            if (port <= 0) {
                controller.clearProxyOverride({ it.run() }, {})
                return
            }
            val config = androidx.webkit.ProxyConfig.Builder()
                .addProxyRule("127.0.0.1:" + port)
                .addBypassRule("localhost")
                .addBypassRule("127.0.0.1")
                .build()
            controller.setProxyOverride(config, { it.run() }, {})
            trail("browsing through the app's own resolver on port " + port)
        } catch (_: Throwable) {
            // An unsupported WebView keeps browsing directly, which on an
            // unblocked network is exactly right anyway.
        }
    }

    /** Runs the page harvest again after the content underneath has changed. */
    private fun rescanPage() {
        try {
            web?.evaluateJavascript("window.__innoHarvest = false;", null)
            web?.evaluateJavascript(harvestJs, null)
        } catch (_: Throwable) {
        }
    }

    /**
     * Files an address the page declared, and the quality it called it.
     *
     * Replaces an entry the SNIFFER filed first, when one exists: the same
     * address caught on the network carries no label, and the label is the
     * whole reason this arrived. Anything the page names is worth more than
     * anything we can infer from a file name.
     */
    private fun onPageDeclared(url: String, label: String) {
        if (mediaKind(url) <= 0) return
        val clean = label.trim().take(12)
        synchronized(sniffed) {
            val at = sniffed.indexOfFirst { it.url == url }
            if (at >= 0) {
                // Only ever upgrades. A labelled entry must not lose its label
                // to a later unlabelled sighting of the same address.
                if (clean.isNotEmpty() && sniffed[at].label.isEmpty()) {
                    sniffed[at] = sniffed[at].copy(label = clean)
                }
                return
            }
            sniffed.add(Hit(url, System.currentTimeMillis(), clean))
            while (sniffed.size > 40) sniffed.removeAt(0)
        }
        runOnUiThread { updateButtons() }
    }

    private fun resetPageState() {
        synchronized(sniffed) { sniffed.clear() }
        adsBlocked = 0
        mainVideoLive = false
        mainVideoSince = 0L
        maxSeenDuration = 0.0
        lastWatchNote = ""
        // THE WATCHER'S FINDINGS BELONG TO A PAGE, not to the browser. Leaving
        // them behind is how the previous video's answer gets used for the
        // next one, which is the same class of bug as the addresses.
        watcherHeard = false
        watcherSilent = false
        videoPlaying = false
        lastVideoCount = 0
        lastAdMarker = false
        lastReportedDuration = 0.0
        pageDeclaredDuration = 0.0
        // RESET TOO. Without this, the same sentence about a second video is
        // silently dropped as a duplicate of the first — and the trail quietly
        // stops recording the page somebody is actually on.
        lastTrail = ""
        // NOT troubleShownFor — it is keyed by host with its own cooldown now,
        // and clearing it here is precisely what let three failed loads of one
        // site raise three sheets.
        wallShownFor = ""
        ui.removeCallbacks(verdict)
        ui.postDelayed(verdict, 12000)
    }

    /**
     * Writes down, in one line, why no Download button has appeared.
     *
     * Reached twelve seconds after a page settles, which is long past the
     * point where waiting is normal. Every fact here is one that changes what
     * the repair would be, and none of them were visible before: a report used
     * to end at "in-app browser opened" and leave the rest to guesswork.
     */
    private fun reportWhyNoButton() {
        val page = web?.url ?: return
        if (grabButton?.visibility == View.VISIBLE) return
        // AN ADVERT IS NOT A FAULT, IT IS THE RULE WORKING. Reporting "no
        // button" while a pre-roll is plainly running teaches whoever reads
        // the trail to distrust the line that matters. Wait and ask again.
        if (lastAdMarker) {
            ui.removeCallbacks(verdict)
            ui.postDelayed(verdict, 12000)
            return
        }
        val count = synchronized(sniffed) { sniffed.size }
        val why = ArrayList<String>()
        why.add(prettyHost(page) ?: page)
        why.add(if (prefersPageUrl(page)) "page-first" else "stream-first")
        if (!looksLikeWatchPage(page)) why.add("not a video page")
        if (!watcherHeard) {
            // The single most useful line this file can produce. A script that
            // never speaks means every rule downstream of it is dead, not
            // wrong, and no amount of tuning the advert rule would help.
            watcherSilent = true
            why.add("WATCHER SILENT (script refused or no video element)")
        } else {
            why.add("videos=" + lastVideoCount)
            why.add(if (videoPlaying) "playing" else "not playing")
            why.add(lastReportedDuration.toInt().toString() + "s")
            if (lastAdMarker) why.add("AD MARKER")
            if (!mainVideoLive) why.add("not judged main")
        }
        why.add("media seen=" + count)
        if (adsBlocked > 0) why.add(adsBlocked.toString() + " ads blocked")
        trail("no download button after 12s · " + why.joinToString(" · "))
        // A silent watcher may now qualify the page under the relaxed rule
        // below, so the buttons are asked again rather than left as they were.
        updateButtons()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val startUrl = intent.getStringExtra(EXTRA_URL) ?: "https://www.google.com"
        val siteTitle = intent.getStringExtra(EXTRA_TITLE) ?: ""
        val labelDownload = intent.getStringExtra(EXTRA_LABEL_DOWNLOAD) ?: "Download"
        val labelHint = intent.getStringExtra(EXTRA_LABEL_HINT) ?: ""
        if (labelHint.isNotEmpty()) labelHintText = labelHint

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0E0E0E"))
            // THE BUTTON WAS UNDER THE NAVIGATION BAR. The screenshots show
            // the hint line and a sliver of blue and nothing else — a Download
            // button you cannot press is the same as no button at all. Asking
            // for system-window fitting makes the layout stop above the bar
            // instead of behind it.
            fitsSystemWindows = true
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        // ---- top bar: close, back, address, streams, reload ------------------
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(2), dp(6), dp(2), dp(6))
            setBackgroundColor(Color.parseColor("#161616"))
        }

        val close = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            background = null
            setColorFilter(Color.parseColor("#B3FFFFFF"))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(38))
            setOnClickListener { finish() }
        }

        val back = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_media_previous)
            background = null
            setColorFilter(Color.parseColor("#B3FFFFFF"))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(38))
            setOnClickListener {
                val v = web
                if (v != null && v.canGoBack()) v.goBack()
            }
        }

        urlLabel = TextView(this).apply {
            text = siteTitle.ifEmpty { startUrl }
            setTextColor(Color.parseColor("#B3FFFFFF"))
            textSize = 12.5f
            maxLines = 1
            isSingleLine = true
            ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
            layoutParams = LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
            )
        }

        // THE MANUAL PATH, ALWAYS AVAILABLE.
        //
        // The floating button is deliberately conservative: it waits for the
        // main video and stays away during adverts, which means it will
        // occasionally stay away from something a person did want. That is the
        // right trade for the button somebody taps without thinking — but it
        // must never be the ONLY way, or a cautious rule becomes a feature
        // nobody can reach. This lists every address the page has offered and
        // lets the person choose, and it is there from the moment there is one
        // to show.
        streamsButton = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_sort_by_size)
            background = null
            setColorFilter(Color.parseColor("#B3FFFFFF"))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(38))
            visibility = View.GONE
            setOnClickListener { showStreamPicker() }
        }

        val reload = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_rotate)
            background = null
            setColorFilter(Color.parseColor("#B3FFFFFF"))
            layoutParams = LinearLayout.LayoutParams(dp(38), dp(38))
            setOnClickListener { web?.reload() }
        }

        bar.addView(close)
        bar.addView(back)
        bar.addView(urlLabel)
        bar.addView(streamsButton)
        bar.addView(reload)

        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(2)
            )
        }

        // ---- the page --------------------------------------------------------
        val holder = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f
            )
        }

        val view = WebView(this)
        web = view
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, true)
        view.addJavascriptInterface(Watch(), "InnocentWatch")

        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            loadWithOverviewMode = true
            useWideViewPort = true
            builtInZoomControls = true
            displayZoomControls = false
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            // MAKE IT FEEL LIKE THE APP IT IS REPLACING. On a phone with no
            // Google services the browser IS YouTube, so the difference
            // between a WebView left on its defaults and one set up properly
            // is the difference between somebody using this feature and not.
            cacheMode = WebSettings.LOAD_DEFAULT
            blockNetworkImage = false
            loadsImagesAutomatically = true
            // Renders slightly beyond the visible window so scrolling does not
            // have to wait for paint. Costs a little memory and is the single
            // biggest perceived-speed setting the WebView has. API 23; minSdk
            // here is 24, so no guard is needed.
            offscreenPreRaster = true
            // A popunder is the adult-site tax and this refuses to pay it: with
            // multiple windows off, a link that wanted its own window opens in
            // this one instead of spawning a tab nobody asked for.
            setSupportMultipleWindows(false)
            javaScriptCanOpenWindowsAutomatically = false
            // Left as the WebView's own. A browser that lies about what it is
            // will be caught by exactly the challenges this screen exists to
            // pass, and being an honest Android browser is the whole point.
            userAgentString = userAgentString
        }
        try {
            view.setLayerType(View.LAYER_TYPE_HARDWARE, null)
        } catch (_: Throwable) {
        }

        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                v: WebView?,
                request: WebResourceRequest?
            ): Boolean {
                // KEEP EVERY NAVIGATION INSIDE. Without this a link with a
                // target or an app scheme throws the person back out to Chrome,
                // which is the exact thing this screen was built to stop.
                val next = request?.url ?: return false
                val scheme = next.scheme?.lowercase()
                if (scheme == "http" || scheme == "https") {
                    v?.loadUrl(next.toString())
                    return true
                }
                // Anything else (intent:, market:, mailto:) is genuinely not
                // ours; swallow it rather than crashing or leaving.
                return true
            }

            /**
             * Every request the page makes passes through here.
             *
             * Returning null means "carry on as normal" — we are reading, not
             * interfering. Note this runs on a background thread, which is why
             * the list is synchronised and the buttons are touched via
             * runOnUiThread.
             */
            override fun shouldInterceptRequest(
                v: WebView?,
                request: WebResourceRequest?
            ): android.webkit.WebResourceResponse? {
                val u = request?.url?.toString()
                // BLOCKED BEFORE ANYTHING ELSE. An empty response is what an
                // adblocker returns: the page carries on and the advert does
                // not load, which makes the page faster and the phone quieter.
                if (u != null && isAdRequest(u)) {
                    adsBlocked++
                    return android.webkit.WebResourceResponse(
                        "text/plain", "utf-8", java.io.ByteArrayInputStream(ByteArray(0))
                    )
                }
                if (u != null && mediaKind(u) > 0) {
                    synchronized(sniffed) {
                        if (sniffed.none { it.url == u }) {
                            sniffed.add(Hit(u, System.currentTimeMillis()))
                            while (sniffed.size > 40) sniffed.removeAt(0)
                        }
                    }
                    runOnUiThread { updateButtons() }
                }
                return null
            }

            /**
             * A new page is a new video, so the old one's addresses go.
             *
             * Without this the advert or the clip from the PREVIOUS video stays
             * in the list and can still be handed over — which is how somebody
             * ends up with a file from a page they have already left.
             */
            override fun onPageStarted(
                v: WebView?,
                url: String?,
                favicon: android.graphics.Bitmap?
            ) {
                super.onPageStarted(v, url, favicon)
                lastKnownUrl = url ?: ""
                resetPageState()
                runOnUiThread { updateButtons() }
            }

            /**
             * Fires on `pushState` as well as a real load, which is the only
             * hook a single-page site gives us from the Java side. The script
             * reports it too; both exist because YouTube has been known to
             * skip one or the other on different Android versions, and a
             * missed navigation means downloading the previous video.
             */
            override fun doUpdateVisitedHistory(
                v: WebView?,
                url: String?,
                isReload: Boolean
            ) {
                super.doUpdateVisitedHistory(v, url, isReload)
                if (url != null && !isReload) onSpaNavigation(url)
            }

            /**
             * The page itself would not load.
             *
             * WORTH CATCHING SEPARATELY, because on this user's network it is
             * the COMMON failure and it looks nothing like the one the failure
             * sheet was built for. Their router blocks whole sites by name, so
             * the browser gets a DNS refusal rather than a page — and until now
             * that produced an empty white screen and no explanation at all.
             */
            override fun onReceivedError(
                v: WebView?,
                request: WebResourceRequest?,
                error: android.webkit.WebResourceError?
            ) {
                super.onReceivedError(v, request, error)
                // Only for the MAIN page. A tracker that fails to load is not
                // something to interrupt somebody about.
                if (request?.isForMainFrame != true) return
                // ONLY THE FAILURES THAT MEAN THE NETWORK. A cache miss, a
                // cancelled navigation or an unknown blip is not something to
                // interrupt somebody with a sheet about their DNS — and a
                // warning that fires when nothing is wrong is a warning nobody
                // will read when something is.
                val code = try {
                    error?.errorCode ?: 0
                } catch (_: Throwable) {
                    0
                }
                val networkish = code == WebViewClient.ERROR_HOST_LOOKUP ||
                    code == WebViewClient.ERROR_CONNECT ||
                    code == WebViewClient.ERROR_TIMEOUT ||
                    code == WebViewClient.ERROR_IO
                if (!networkish) return
                val text = try {
                    error?.description?.toString() ?: ""
                } catch (_: Throwable) {
                    ""
                }
                pageLoadError = text
                runOnUiThread { showNetworkTrouble(text) }
                trail("page would not load · " + (prettyHost(web?.url) ?: "") + " · " + text)
            }

            override fun onPageFinished(v: WebView?, url: String?) {
                super.onPageFinished(v, url)
                urlLabel?.text = prettyHost(url) ?: url ?: ""
                progress?.visibility = View.GONE
                injectWatcher(v)
                // RESTARTED FROM HERE, not only from a reset: a browser opened
                // directly onto a video never resets again, and the verdict
                // would have been scheduled before the page had loaded.
                ui.removeCallbacks(verdict)
                ui.postDelayed(verdict, 12000)
            }
        }

        view.webChromeClient = object : WebChromeClient() {
            /**
             * Somebody tapped fullscreen. Give the player the whole screen.
             *
             * The orientation is remembered and restored rather than forced
             * back to portrait: a phone held sideways with rotation locked
             * should not be spun round on the way out of a video it was
             * perfectly happy showing.
             */
            override fun onShowCustomView(
                view: View?,
                callback: WebChromeClient.CustomViewCallback?
            ) {
                if (view == null) {
                    callback?.onCustomViewHidden()
                    return
                }
                if (fullscreenView != null) {
                    callback?.onCustomViewHidden()
                    return
                }
                fullscreenView = view
                fullscreenCallback = callback
                savedOrientation = requestedOrientation
                val holder = FrameLayout(this@BrowserActivity).apply {
                    setBackgroundColor(Color.BLACK)
                }
                holder.addView(
                    view,
                    FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                )
                fullscreenHolder = holder
                addContentView(
                    holder,
                    ViewGroup.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                )
                hideSystemBars(true)
                // Landscape, because a fullscreen video is nearly always wider
                // than it is tall and nobody wants to rotate the phone twice.
                requestedOrientation =
                    android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            }

            override fun onHideCustomView() {
                val holder = fullscreenHolder ?: run {
                    fullscreenCallback?.onCustomViewHidden()
                    fullscreenView = null
                    fullscreenCallback = null
                    return
                }
                (holder.parent as? ViewGroup)?.removeView(holder)
                holder.removeAllViews()
                fullscreenHolder = null
                fullscreenView = null
                fullscreenCallback?.onCustomViewHidden()
                fullscreenCallback = null
                hideSystemBars(false)
                requestedOrientation = savedOrientation
            }

            override fun onProgressChanged(v: WebView?, newProgress: Int) {
                progress?.progress = newProgress
                progress?.visibility =
                    if (newProgress in 1..99) View.VISIBLE else View.GONE
                // The script is installed as soon as there is a document to
                // install it into rather than only at the end of the load: on a
                // heavy page the video can be playing long before the last
                // tracker has finished, and a watcher that arrives after the
                // advert has started has missed the thing it came to see.
                if (newProgress >= 55) injectWatcher(v)
            }

            /**
             * KEEP THE SITE'S OWN ICON — and note carefully where it came from.
             *
             * The tile grid has always used monograms rather than logos, for
             * two stated reasons: shipping other people's trademarks inside the
             * APK, and the fact that fetching icons at runtime would tell an
             * icon service which sites this person cares about. With adult
             * sites in the same grid that second one is a real leak, not a
             * theoretical one, and it is why favicons were refused.
             *
             * Neither objection applies here. Nothing is bundled — the file
             * only exists once somebody has chosen to visit that site — and no
             * request is made that they did not already make by opening the
             * page.
             */
            override fun onReceivedIcon(v: WebView?, icon: android.graphics.Bitmap?) {
                super.onReceivedIcon(v, icon)
                val bmp = icon ?: return
                val host = tileHost ?: return
                if (bmp.width < 16 || bmp.height < 16) return
                try {
                    val dir = java.io.File(filesDir, "site_icons")
                    if (!dir.exists()) dir.mkdirs()
                    val out = java.io.File(dir, host.lowercase() + ".png")
                    java.io.FileOutputStream(out).use { stream ->
                        bmp.compress(
                            android.graphics.Bitmap.CompressFormat.PNG, 100, stream
                        )
                    }
                } catch (_: Throwable) {
                    // A missing icon is a monogram, which is a fine outcome.
                }
            }
        }

        // ALREADY ON FROM AN EARLIER VISIT? Then this browser uses it too.
        // The override is per-app rather than per-WebView, but setting it here
        // is what makes a browser opened after the fact behave like the one
        // that turned it on.
        if (DnsBypassProxy.isRunning) applyProxy(DnsBypassProxy.port)

        tileHost = prettyHost(startUrl)
        view.loadUrl(startUrl)
        holder.addView(
            view,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        // ---- the Download button ---------------------------------------------
        //
        // A FLOATING PILL OVER THE PAGE, NOT A BAR UNDER IT. The bar version
        // took a permanent stripe off a screen somebody is using to watch
        // something, and it was present whether or not it could do anything.
        // This sits in the corner, arrives when the main video starts, and
        // leaves when the page changes — which is what the downloaders people
        // compare this one to have always done, and what makes the appearance
        // itself the message.
        labelDownloadText = labelDownload
        intent.getStringExtra(EXTRA_LABEL_WORKING)?.let { labelWorkingText = it }
        intent.getStringExtra(EXTRA_LABEL_PICK)?.let { labelPickText = it }
        intent.getStringExtra(EXTRA_LABEL_STARTED)?.let { labelStartedText = it }
        intent.getStringExtra(EXTRA_LABEL_NOSOUND)?.let { labelNoSoundText = it }
        intent.getStringExtra(EXTRA_LABEL_STREAMS)?.let { labelStreamsText = it }
        intent.getStringExtra(EXTRA_LABEL_UNREADABLE)?.let { labelUnreadableText = it }
        intent.getStringExtra(EXTRA_LABEL_RETRY)?.let { labelRetryText = it }
        intent.getStringExtra(EXTRA_LABEL_SENDSCREEN)?.let { labelSendScreenText = it }
        intent.getStringExtra(EXTRA_LABEL_BLOCKED)?.let { labelBlockedText = it }
        intent.getStringExtra(EXTRA_LABEL_VPNHINT)?.let { labelVpnHintText = it }
        intent.getStringExtra(EXTRA_LABEL_DNSHINT)?.let { labelDnsHintText = it }
        intent.getStringExtra(EXTRA_LABEL_OPENSETTINGS)
            ?.let { labelOpenSettingsText = it }
        intent.getStringExtra(EXTRA_LABEL_MORE)?.let { labelMoreText = it }
        intent.getStringExtra(EXTRA_LABEL_DNSFOUND)?.let { labelDnsFoundText = it }
        intent.getStringExtra(EXTRA_LABEL_DEEPER)?.let { labelDeeperText = it }
        intent.getStringExtra(EXTRA_LABEL_BYPASS)?.let { labelBypassText = it }
        intent.getStringExtra(EXTRA_LABEL_BYPASSHINT)?.let { labelBypassHintText = it }
        intent.getStringExtra(EXTRA_LABEL_VPNGONE)?.let { labelVpnNotNeededText = it }
        intent.getStringExtra(EXTRA_LABEL_YTWALL)?.let { labelYtWallText = it }
        intent.getStringExtra(EXTRA_LABEL_YTEMBED)?.let { labelYtEmbedText = it }
        intent.getStringExtra(EXTRA_LABEL_YTSIGNIN)?.let { labelYtSignInText = it }
        intent.getStringExtra(EXTRA_CLIENTS)
            ?.takeIf { it.isNotBlank() }
            ?.let { playerClients = it }

        val pill = android.graphics.drawable.GradientDrawable().apply {
            shape = android.graphics.drawable.GradientDrawable.RECTANGLE
            cornerRadius = dp(26).toFloat()
            setColor(Color.parseColor("#2F6BFF"))
        }
        val grab = TextView(this).apply {
            text = labelDownload
            textSize = 14.5f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
            background = pill
            setPadding(dp(22), dp(13), dp(22), dp(13))
            elevation = dp(6).toFloat()
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.BOTTOM or Gravity.END
                setMargins(0, 0, dp(16), dp(20))
            }
            setOnClickListener { offerQualities(null) }
            setOnLongClickListener {
                showStreamPicker()
                true
            }
        }
        grabButton = grab
        holder.addView(grab)

        root.addView(bar)
        root.addView(progress)
        root.addView(holder)

        // HIDDEN UNTIL THE MAIN VIDEO IS PLAYING.
        grab.visibility = View.GONE
        setContentView(root)
    }

    /** Edge to edge for a video, back to normal for a page. */
    private fun hideSystemBars(hide: Boolean) {
        try {
            val decor = window.decorView
            @Suppress("DEPRECATION")
            decor.systemUiVisibility = if (hide) {
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                    View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            } else {
                View.SYSTEM_UI_FLAG_VISIBLE
            }
        } catch (_: Throwable) {
        }
    }

    /**
     * Hides the banners a mobile site shows instead of its content.
     *
     * ON A PHONE WITH NO GOOGLE SERVICES THIS BROWSER IS YOUTUBE, and mobile
     * YouTube spends a strip of every screen — sometimes a modal over all of
     * it — telling somebody to open an app they cannot install. Hiding it is
     * not cosmetic: it is the difference between a video starting and a person
     * dismissing a dialog first, every single time.
     *
     * Written as CSS rather than clicks. A rule that hides an element cannot
     * navigate anywhere, cannot fire a handler, and cannot break a page that
     * changes its markup — it simply stops matching. And it is scoped to the
     * app-promotion classes those sites use, not to anything structural.
     *
     * No dollar signs: Kotlin raw string.
     */
    private val declutterJs = """
(function(){
  if (window.__innoTidy) { return; }
  window.__innoTidy = true;
  var css = document.createElement('style');
  css.textContent =
    'ytm-mealbar-promo-renderer,' +
    'ytm-app-promo-banner,' +
    '.mobile-topbar-app-promo,' +
    'ytm-companion-slot,' +
    '.ytp-ad-overlay-container,' +
    'yt-mealbar-promo-renderer,' +
    'tp-yt-paper-dialog[modern],' +
    '#dialog[role=dialog] ytm-app-promo-banner,' +
    'div[class*=app-promo],' +
    'div[class*=smart-banner],' +
    'div[class*=AppBanner],' +
    'div[id*=app-banner]' +
    ' { display: none !important; }';
  (document.head || document.documentElement).appendChild(css);
})();
"""

    /** The sheet currently on screen, so a later answer can reach it. */
    private var openSheet: android.app.Dialog? = null
    private var openSheetUrl: String = ""

    /**
     * Reads properly behind an already-open sheet, and merges what comes back.
     *
     * THE POINT IS THAT NOBODY WAITS FOR IT. The instant ladder is already on
     * screen and already usable; this runs behind it and, if the reader finds
     * qualities the page did not declare, the sheet quietly gains them. If the
     * person has already chosen and gone, the answer is dropped — a sheet that
     * reappears after it was dismissed is a bug, not a feature.
     *
     * Merged by LABEL, keeping what the page declared: a site's own name for a
     * rung, with a size measured from the file itself, beats the same rung
     * described second-hand by an extractor.
     */
    private fun enrichInBackground(target: String, shown: List<Choice>, title: String) {
        Thread {
          try {
            val extra = try {
                val fromDart = DownloadEngine.askDartForFormats(target)
                if (fromDart != null) rowsToChoices(fromDart) else emptyList()
            } catch (_: Throwable) {
                emptyList()
            }
            if (extra.isEmpty()) return@Thread
            val have = shown.map { it.label.lowercase() }.toMutableSet()
            val merged = ArrayList(shown)
            for (c in extra) {
                if (have.add(c.label.lowercase())) merged.add(c)
            }
            if (merged.size <= shown.size) return@Thread
            merged.sortByDescending { rankOf(it.label) }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                // ONLY IF THE SAME SHEET IS STILL THERE. A person who has
                // already picked has moved on, and redrawing over them would
                // be the app arguing with a decision they made.
                if (openSheet?.isShowing != true || openSheetUrl != target) {
                    return@runOnUiThread
                }
                openSheet?.dismiss()
                trail("filled the ladder in behind the sheet · " + merged.size + " qualities")
                showChoices(target, merged)
            }
          } catch (t: Throwable) {
            trail("filling the ladder failed: " + (t.message ?: t.javaClass.simpleName))
          }
        }.start()
    }

    /** Installs the watcher script, harmlessly, as many times as asked. */
    private fun injectWatcher(v: WebView?) {
        try {
            v?.evaluateJavascript(watchJs, null)
            v?.evaluateJavascript(declutterJs, null)
            v?.evaluateJavascript(harvestJs, null)
        } catch (_: Throwable) {
            // A page that refuses the script keeps the manual path, which is
            // exactly why the manual path is not optional.
        }
    }

    /**
     * One quality the page can be downloaded at.
     *
     * Deliberately tiny. The full parser lives in Dart and knows about codec
     * tiers, duplicate collapsing and muxing; none of that belongs here. This
     * screen needs a list somebody can read and a selector to send back, and
     * duplicating the Dart parser in Kotlin would be two parsers to keep in
     * step for no gain.
     */
    private data class Choice(
        val selector: String,
        val label: String,
        val merge: Boolean,
        /// This row's own address, when it differs from the sheet's.
        ///
        /// Every row of a parsed reply shares one address and picks a format
        /// out of it. A SIBLING row is a different file entirely -- PornHub
        /// publishes 240p and 1080p as two separate mp4s -- so the row has to
        /// carry where it points, or picking 1080p would download whichever
        /// one the sheet was opened on.
        val url: String,
        /// Container, upper-cased: MP4, M3U8, WEBM.
        val ext: String,
        /// Bytes, or 0 when the engine gave nothing to work with.
        val bytes: Long,
        /// True when [bytes] was worked out from a bitrate rather than stated.
        val estimated: Boolean,
        /// A short warning worth its own pill — "no sound", mostly.
        val badge: String
    )

    /**
     * Turns yt-dlp's JSON into a short, readable list.
     *
     * Same labelling rule as the Dart side, and for the same reason: height
     * first because it is what people think in, then bitrate because a bare
     * playlist has no height but usually has one, and never the word
     * "unknown", which is the extractor admitting it has nothing to say.
     */
    private fun choicesFrom(json: String?, pageTitleFromWeb: String): List<Choice> {
        lastParseError = null
        if (json.isNullOrBlank()) return emptyList()
        val out = ArrayList<Choice>()

        val root = try {
            org.json.JSONObject(json)
        } catch (t: Throwable) {
            // The reply was not JSON at all. Carry the opening characters so
            // the shape is visible: a warning printed on the wrong stream, an
            // error page, an empty object — each looks completely different
            // and none of them can be diagnosed from a byte count.
            lastParseError = "not JSON (${t.javaClass.simpleName}) · starts: " +
                json.take(70).replace("\n", " ")
            return emptyList()
        }

        try {
            // THE PAGE'S TITLE BEATS THE FILE'S NAME.
            //
            // Reading a bare playlist gives the engine nothing to work with,
            // so it names the video after the file — which is how a download
            // ended up called "master". The page has a real title sitting
            // right there in the browser; it is what a person would have
            // called it, and it is what the saved file should be called.
            val fromJson = root.optString("title", "")
                .ifEmpty { root.optJSONArray("entries")?.optJSONObject(0)?.optString("title", "") ?: "" }
            // PASSED IN, NOT READ HERE — and this was the whole bug.
            //
            // This used to call web?.title directly, and this function runs on
            // a background thread. A WebView may only be touched from the
            // thread that created it, so that call threw on EVERY read, the
            // catch below swallowed it, and the in-page sheet fell back to the
            // downloads screen for four releases. The reply was never at fault.
            val fromPage = pageTitleFromWeb
            pageTitle = when {
                fromJson.isNotEmpty() && !looksLikeFileName(fromJson) -> fromJson
                fromPage.isNotEmpty() -> fromPage
                fromJson.isNotEmpty() -> fromJson
                else -> pageTitle
            }
            // UNWRAP THE PLAYLIST WRAPPER FIRST — this is the bug the browser
            // note found, and it explains every one of the six sites.
            //
            // Given a bare media address the engine falls back to its generic
            // reader, and that often answers with a PLAYLIST rather than a
            // video: `{"_type": "playlist", "entries": [ { …the real thing… } ]}`.
            // There is no `formats` at the top level of that, so looking for
            // one there found nothing and the whole in-page flow fell back to
            // the downloads screen — six times, silently, while the Dart parser
            // read the very same reply correctly because it has unwrapped
            // entries since the day it was written (probe_parser.dart:61).
            //
            // Two parsers reading the same JSON must agree about its shape.
            val doc = if (root.optString("_type", "") == "playlist") {
                root.optJSONArray("entries")?.optJSONObject(0) ?: root
            } else {
                root
            }
            // LOOK EVERYWHERE THE QUALITIES COULD BE, then say what was there
            // if they are nowhere. Three shapes are known to arrive from the
            // engine and only one of them was being handled:
            //   • a video          → formats at the top
            //   • a playlist       → formats inside entries[0]
            //   • a single format  → no list at all, the fields are the video
            // A reader that knows one shape and calls the other two "empty" is
            // how six sites failed identically and silently.
            val formats = doc.optJSONArray("formats")
                ?: root.optJSONArray("formats")
                ?: findFormatsAnywhere(root)
                ?: singleFormatAsList(doc)
                ?: run {
                    lastParseError = "no formats · keys: " + keysOf(root) +
                        (if (doc !== root) " · entry keys: " + keysOf(doc) else "")
                    return emptyList()
                }
            // READ FIRST, NOT LAST. It used to be picked up after the loop
            // because nothing needed it until then; a size estimated from a
            // bitrate needs it during.
            val docDuration = doc.optDouble("duration", 0.0)
                .let { if (it > 0) it else root.optDouble("duration", 0.0) }
            val seen = HashSet<String>()
            for (i in formats.length() - 1 downTo 0) {
                val f = formats.optJSONObject(i) ?: continue

                // MIRROR THE DART RULE EXACTLY. This is the bug that sent the
                // whole feature back to the old behaviour: `optString(_, "none")`
                // turns a MISSING codec into "none", so every format from a
                // bare playlist — which is precisely what these sites give,
                // with no codec information at all — was read as audio-only and
                // dropped. An empty list then fell through to the hand-off, the
                // browser closed, and the person landed on the downloads screen
                // wondering what had happened.
                //
                // probe_parser.dart says it plainly: both codecs absent means
                // COMBINED, not silent. Only an explicit "none" means no video.
                val vRaw = if (f.isNull("vcodec")) null else f.optString("vcodec", "")
                val aRaw = if (f.isNull("acodec")) null else f.optString("acodec", "")
                val bothAbsent = vRaw.isNullOrEmpty() && aRaw.isNullOrEmpty()
                if (!bothAbsent && vRaw == "none") continue   // genuinely audio-only
                val id = f.optString("format_id", "")
                if (id.isEmpty()) continue
                val h = f.optInt("height", 0)
                val w = f.optInt("width", 0)
                val short = if (h in 1..Int.MAX_VALUE && (w == 0 || h <= w)) h else minOf(h, w)
                val tbr = f.optDouble("tbr", 0.0)
                // `resolution` is a plain string like "1280x720" and is often
                // the only place a height appears for these streams. Reading it
                // is the difference between a row that says 720p and one that
                // says 2666, which is what the device showed.
                val fromRes = f.optString("resolution", "")
                    .substringAfter('x', "")
                    .takeWhile { it.isDigit() }
                    .toIntOrNull() ?: 0
                val label = when {
                    short > 0 -> short.toString() + "p"
                    fromRes > 0 -> fromRes.toString() + "p"
                    tbr >= 1000 -> String.format("%.1f Mbps", tbr / 1000)
                    tbr > 0 -> tbr.toInt().toString() + " kbps"
                    else -> id
                }
                if (!seen.add(label)) continue          // one row per quality
                // Silent only when the extractor SAID so. When it said
                // nothing at all the stream is combined and muxing would be
                // asking ffmpeg to join a file to itself.
                val silent = !bothAbsent && aRaw == "none"

                // The second line, built from whatever the engine actually
                // told us. A row saying only "720p" makes somebody guess how
                // big it is and whether it has sound; the Flutter sheet has
                // always answered both, and this one should not be the poor
                // relation just because it is drawn in Kotlin.
                val ext = f.optString("ext", "").uppercase()
                val size = sizeOf(f, docDuration)
                out.add(
                    Choice(
                        selector = id,
                        label = label,
                        merge = silent,
                        url = "",
                        ext = ext,
                        bytes = size.first,
                        estimated = size.second,
                        badge = if (silent) labelNoSoundText else ""
                    )
                )
            }
            // IF FILTERING LEFT ALMOST NOTHING, TRUST THE ENGINE INSTEAD OF US.
            //
            // A single row from a master playlist means either the site really
            // offers one quality or our filter ate the rest — and from the
            // outside those look identical, which is exactly the complaint.
            // When the engine clearly sent more than we kept, the honest move
            // is to show what it sent rather than a confident short list. A row
            // too many costs a line of scrolling; a row too few costs the
            // quality somebody actually wanted.
            if (out.size < 2 && formats.length() > out.size) {
                for (i in formats.length() - 1 downTo 0) {
                    val f = formats.optJSONObject(i) ?: continue
                    if (f.optString("acodec", "") == "none" &&
                        f.optString("vcodec", "") == "none"
                    ) continue
                    val id = f.optString("format_id", "") .ifEmpty { i.toString() }
                    if (out.any { it.selector == id }) continue
                    val h = f.optInt("height", 0)
                    val tbr = f.optDouble("tbr", 0.0)
                    val label = when {
                        h > 0 -> h.toString() + "p"
                        tbr >= 1000 -> String.format("%.1f Mbps", tbr / 1000)
                        tbr > 0 -> tbr.toInt().toString() + " kbps"
                        else -> id
                    }
                    val ext = f.optString("ext", "").uppercase()
                    val size = sizeOf(f, docDuration)
                    out.add(
                        Choice(
                            selector = id,
                            label = label,
                            merge = false,
                            url = "",
                            ext = ext,
                            bytes = size.first,
                            estimated = size.second,
                            badge = ""
                        )
                    )
                }
            }
            rawFormatCount = formats.length()
            lastDuration = docDuration
        } catch (t: Throwable) {
            // NAME IT. This catch swallowed the fault that broke the in-page
            // flow for four releases: every read threw, every read returned
            // nothing, and the note said "no formats" because the counter was
            // never reached. A catch that reports nothing is exactly the
            // silence the browser note was added to end.
            lastParseError = "reading the reply threw — " +
                t.javaClass.simpleName + ": " + (t.message ?: "no message")
            return emptyList()
        }
        out.sortByDescending { c ->
            c.label.takeWhile { it.isDigit() }.toIntOrNull() ?: 0
        }
        return out
    }

    /**
     * Turns Dart's rows into the sheet's own type.
     *
     * Deliberately forgiving about what is missing and deliberately strict
     * about what is required: a row without a selector cannot be downloaded,
     * and quietly drawing one would be a button that does nothing. Everything
     * else has an honest default, because a row with no size is still a row
     * somebody can choose.
     */
    private fun rowsToChoices(rows: List<Map<String, Any?>>): List<Choice> {
        val out = ArrayList<Choice>()
        for (r in rows) {
            val selector = (r["selector"] as? String)?.trim().orEmpty()
            if (selector.isEmpty()) continue
            val label = (r["label"] as? String)?.trim().orEmpty()
            if (label.isEmpty()) continue
            val bytes = when (val b = r["bytes"]) {
                is Int -> b.toLong()
                is Long -> b
                is Double -> b.toLong()
                else -> 0L
            }
            out.add(
                Choice(
                    selector = selector,
                    label = label,
                    merge = r["merge"] == true,
                    url = (r["url"] as? String)?.trim().orEmpty(),
                    ext = (r["ext"] as? String)?.trim().orEmpty().uppercase(),
                    bytes = bytes,
                    estimated = r["estimated"] == true,
                    badge = (r["badge"] as? String)?.trim().orEmpty()
                )
            )
        }
        // Dart has already ordered these by its own rules -- codec tier, then
        // container, then bitrate. Re-sorting here would be this file having
        // an opinion about a question it just delegated.
        return out
    }

    /**
     * Probes the page's video and offers its qualities, over the page.
     *
     * The read happens off the UI thread because it takes seconds — the button
     * says so while it runs, and the page stays scrollable throughout, which
     * is the entire point of doing this here instead of on another screen.
     *
     * [forced] is an address the person chose from the manual list; when it is
     * null the target is worked out from what the player and the sniffer agree
     * on.
     */
    private fun offerQualities(forced: String?, skipInstant: Boolean = false) {
        val current = web?.url ?: return
        val target = forced ?: chooseTarget(current)
        if (target == null) {
            android.widget.Toast
                .makeText(this, labelHintText, android.widget.Toast.LENGTH_LONG)
                .show()
            return
        }
        saveSessionFor(current, target)

        // NO READ AT ALL, WHEN THE PAGE HAS ALREADY SAID EVERYTHING.
        //
        // Checked before anything is spawned, because the fastest extraction is
        // the one that does not happen. When a site publishes each quality as
        // its own named file the ladder is already in the addresses we caught,
        // and the sheet can open in the time it takes to draw it. Skipped
        // entirely when the person forced one address from the manual list --
        // they asked for that file, not for a ladder.
        if (forced == null && !skipInstant) {
            // THREE FREE SOURCES, NO EXTRACTION. What the page DECLARED (named
            // progressive rungs) and what its file names IMPLY (sibling mp4s)
            // both cost nothing — no network, no read. A stream-first site adds
            // a third: its HLS master, a tiny text file the player already
            // fetched, which lists every rung the page kept out of its inline
            // config. Any one of the three is enough to open the sheet at once.
            val declared = declaredChoices()
            val siblings = if (declared == null) siblingChoices() else null
            val hasMaster = declaredPlaylist() != null
            if (declared != null || siblings != null || hasMaster) {
                pageTitle = web?.title?.trim().orEmpty().ifEmpty { pageTitle }
                // CAPTURED HERE, ON THE UI THREAD. Everything below runs on a
                // worker, and a WebView may only be read from the thread that
                // created it — the same rule that cost four releases in
                // choicesFrom, reintroduced and now removed for good.
                val agent = web?.settings?.userAgentString
                val titleNowInstant = web?.title?.trim().orEmpty()
                grabButton?.isEnabled = false
                grabButton?.text = labelWorkingText
                Thread {
                  try {
                    val base = declared ?: siblings ?: emptyList()
                    // FILL A THIN LADDER FROM THE MASTER, RIGHT NOW.
                    //
                    // XVideos declares one quality inline and keeps the rest
                    // inside its HLS master — the screenshot showed the result:
                    // a single row called "Low". Reading the master here turns
                    // that one row into the whole ladder before the sheet is
                    // even drawn, rather than after a ten-second round trip.
                    // A ladder already three deep is left alone — the master
                    // would only repeat what is on screen. Runs on THIS worker
                    // because the master is a network fetch, never on the UI
                    // thread; takes no WebView, only the captured agent.
                    val fromMaster = if (base.size < 3 && hasMaster) {
                        masterChoices(agent, current) ?: emptyList()
                    } else {
                        emptyList()
                    }
                    val ladder = mergeLadders(base, fromMaster)
                    if (ladder.isEmpty()) {
                        // The only free source was a master that would not read.
                        // Hand over to the full reader rather than show nothing.
                        runOnUiThread {
                            grabButton?.isEnabled = true
                            updateButtons()
                            if (isFinishing || isDestroyed) return@runOnUiThread
                            offerQualities(target, skipInstant = true)
                        }
                        return@Thread
                    }
                    trail(
                        "quality ladder read off the page · " + ladder.size +
                            " qualities · no extraction"
                    )
                    // Sizes measured for the progressive rows off the UI thread;
                    // the HLS rows are already estimated from bitrate and need
                    // no request. A second spent on exact numbers where there
                    // would otherwise be none is worth having.
                    val sized = withSizes(ladder, agent, current)
                    DownloadEngine.sendBrowserNote(
                        "browser read: " + sized.size +
                            " qualities from the page (no extraction)"
                    )
                    runOnUiThread {
                        grabButton?.isEnabled = true
                        updateButtons()
                        if (isFinishing || isDestroyed) return@runOnUiThread
                        showChoices(target, sized)
                    }
                    // STILL THIN AND NO MASTER TO LEAN ON — let the full reader
                    // top it up behind the sheet, as before. When the master
                    // already answered, skip it: repeating the read is exactly
                    // the flaky merge race this replaced.
                    if (sized.size < 3 && fromMaster.isEmpty()) {
                        enrichInBackground(target, sized, titleNowInstant)
                    }
                  } catch (t: Throwable) {
                    // A worker that throws kills the process. Whatever went
                    // wrong, the browser stays open and says so.
                    trail("instant ladder failed: " + (t.message ?: t.javaClass.simpleName))
                    runOnUiThread {
                        grabButton?.isEnabled = true
                        updateButtons()
                    }
                  }
                }.start()
                return
            }
        }

        // Captured HERE, on the UI thread, because a WebView cannot legally be
        // read from anywhere else — see the note in choicesFrom.
        val titleNow = web?.title?.trim() ?: ""

        trail(
            "read started · " +
                // COMPARED BY KIND, NOT BY STRING. `canonicalWatch` rewrites
                // `m.youtube.com/watch?v=…` to `www.youtube.com/watch?v=…`, so
                // an equality test called a page address a stream — which is
                // exactly the sort of small lie that sends the next reader of
                // this trail looking in the wrong place.
                (if (prefersPageUrl(target)) "page address" else "stream") +
                " · " + shortAddress(target) +
                (if (playerClients.isNullOrBlank()) " · NO CLIENTS SET" else "")
        )
        grabButton?.isEnabled = false
        grabButton?.text = labelWorkingText
        Thread {
            // ASK DART FIRST. It owns the ladder, the guest session, the
            // self-heal and `probe_parser` -- so the sheet drawn from its rows
            // is the SAME sheet a pasted link gets, sound and all. Our own
            // reader below is the answer to "Flutter is not awake yet", which
            // happens on a cold start and is a bad reason to show nothing.
            val fromDart = DownloadEngine.askDartForFormats(target)
            if (fromDart != null) {
                val rows = rowsToChoices(fromDart)
                val dartTitle = fromDart.firstOrNull()
                    ?.get("pageTitle") as? String
                if (!dartTitle.isNullOrBlank()) pageTitle = dartTitle
                (fromDart.firstOrNull()?.get("duration") as? Double)
                    ?.let { if (it > 0) lastDuration = it }
                if (rows.isNotEmpty()) {
                    runOnUiThread {
                        grabButton?.isEnabled = true
                        updateButtons()
                        if (isFinishing || isDestroyed) return@runOnUiThread
                        showChoices(target, rows)
                    }
                    return@Thread
                }
            }
            trail(
                "dart read gave nothing, using the browser's own reader · " +
                    shortAddress(target)
            )
            // THE PLAYER HAS USUALLY ANSWERED THIS ALREADY. When the button is
            // visible the main video is running, and the addresses collected
            // since it started are its addresses — so the first read is nearly
            // always the right one now, and the length check below is a
            // backstop rather than the mechanism.
            //
            // It is kept because the script can be refused by a page with a
            // strict content policy, because the manual list can be used at any
            // time, and because a mid-roll can begin between the tap and the
            // read. At most two reads, and only when the first looks short.
            val candidates = if (forced != null) listOf(forced) else sniffedCandidates()
            var picked = target
            var json = probeTwice(picked)
            var choices = choicesFrom(json, titleNow)
            var duration = lastDuration
            var note = noteFor(json, choices)

            if (forced == null && choices.isEmpty() && picked == current) {
                val stream = bestSniffed()
                if (stream != null && stream != picked) {
                    val streamJson = probeTwice(stream)
                    val streamChoices = choicesFrom(streamJson, titleNow)
                    if (streamChoices.isNotEmpty()) {
                        note = "page unreadable, used the played stream · " +
                            noteFor(streamJson, streamChoices)
                        picked = stream
                        json = streamJson
                        choices = streamChoices
                        duration = lastDuration
                    }
                }
            }

            if (forced == null && duration > 0 && duration < AD_SECONDS && candidates.size > 1) {
                val alt = candidates.firstOrNull { it != picked }
                if (alt != null) {
                    val altJson = probeTwice(alt)
                    val altChoices = choicesFrom(altJson, titleNow)
                    val altDuration = lastDuration
                    if (altChoices.isNotEmpty() && altDuration > duration) {
                        note = "skipped a " + duration.toInt() + "s clip · " +
                            noteFor(altJson, altChoices)
                        picked = alt
                        json = altJson
                        choices = altChoices
                        duration = altDuration
                    } else {
                        note = "kept a " + duration.toInt() + "s clip (no longer stream) · " + note
                    }
                }
            }

            val finalUrl = picked
            val finalChoices = choices
            val finalNote = note +
                (if (duration > 0) " · " + duration.toInt() + "s" else "") +
                (if (candidates.size > 1) " · " + candidates.size + " streams" else "") +
                (if (lastWatchNote.isNotEmpty()) " · " + lastWatchNote else "")
            DownloadEngine.sendBrowserNote(finalNote)

            runOnUiThread {
                grabButton?.isEnabled = true
                updateButtons()
                if (isFinishing || isDestroyed) return@runOnUiThread
                if (finalChoices.isEmpty()) {
                    showUnreadable(finalUrl)
                    return@runOnUiThread
                }
                showChoices(finalUrl, finalChoices)
            }
        }.start()
    }

    /**
     * Reads an address, and reads it a second time if the engine said nothing.
     *
     * A read that returns no output at all is not the same as a read that
     * returns something unusable, and the device trail has shown the first
     * kind once: nothing came back, the flow fell through to the downloads
     * screen, and a Dart probe of the very same address a moment later
     * succeeded in thirteen seconds. A first attempt that produces literally
     * no bytes is the one failure where trying again immediately is right —
     * there is no rate limit to respect and no state to have corrupted.
     */
    private fun probeTwice(url: String): String? {
        val first = DownloadEngine.probeForBrowser(url, playerClients)
        if (!first.isNullOrBlank()) return first
        return DownloadEngine.probeForBrowser(url, playerClients)
    }

    /**
     * What to hand the engine for the page currently on screen.
     *
     * Two rules, in order, and both are about asking the easiest question
     * rather than the cleverest one:
     *
     *  1. On a site the extractor knows by name, GIVE IT THE PAGE. YouTube,
     *     TikTok and the rest are read better from the address in the address
     *     bar than from any stream we could catch — every quality, the real
     *     title, subtitles. This is also the only thing that works on YouTube
     *     at all, whose media has no file extension for a sniffer to find.
     *
     *  2. Otherwise take the newest stream that arrived once the main video
     *     was running. That is the line the player draws for us, and it is why
     *     the advert can no longer win: its addresses are all on the wrong
     *     side of it.
     */
    /** Pages a site's own navigation lands on that are lists, not videos. */
    private val listingPaths = listOf(
        "/foryou", "/explore", "/following", "/live", "/upload",
        "/search", "/trending", "/feed", "/results"
    )

    /** True for a page-first address that is a LISTING rather than one video. */
    private fun looksLikeListing(url: String?): Boolean {
        val u = url?.lowercase()?.substringBefore('?') ?: return false
        // A bare host — `https://m.youtube.com/` — has two slashes and nothing
        // after them, and is the commonest listing of all.
        if (u.trimEnd('/').count { it == '/' } <= 2) return true
        return listingPaths.any { u.endsWith(it) || u.contains(it + "/") }
    }

    private fun chooseTarget(pageUrl: String): String? {
        // An embed address is a way of PLAYING the video, not a different
        // video. Reading is done against the watch form so that the cookies,
        // the referer and the extractor are all pointed at the same thing
        // however somebody happened to start it.
        // PAGE-FIRST, BUT ONLY FOR A PAGE THAT IS A VIDEO. The trail caught
        // this exactly: `read started · page address · www.tiktok.com/…/foryou`
        // → `Unsupported URL`. A feed is not a video, and handing one over
        // spends seven seconds to be told so. The SITE is still page-first; it
        // is this ADDRESS that is a listing, so fall through to whatever the
        // player is actually streaming — on a feed that is the only thing
        // identifying the clip on screen.
        if (prefersPageUrl(pageUrl) && !looksLikeListing(pageUrl)) {
            return canonicalWatch(pageUrl) ?: pageUrl
        }
        // A PLAYLIST THE PAGE DECLARED IS THE MASTER, and preferring it fixes
        // the one-quality sheet. The device trail read
        // `em-h.phncdn.com/…/index-v1-a1.m3u8` and reported `1 video + 0 audio`
        // — a variant, which honestly lists the single rendition it is for.
        // The master sits in the player's own configuration, so when the page
        // has handed us one there is nothing to work out.
        declaredPlaylist()?.let { return it }
        val best = bestSniffed()
        if (best != null) return best
        // Nothing caught and not a site we know by name: the page address is
        // still worth a try, but only once something has actually played —
        // otherwise this is a ten-second wait for a 403 on a listing page.
        return if (mainVideoLive) pageUrl else null
    }

    /** Describes one read, so both attempts word themselves identically. */
    private fun noteFor(json: String?, choices: List<Choice>): String = when {
        json.isNullOrBlank() -> "browser read returned nothing (engine gave no output)"
        lastParseError != null -> "browser read unusable — $lastParseError"
        rawFormatCount == 0 -> "browser read had no formats (${json.length} bytes)"
        choices.isEmpty() -> "browser read: $rawFormatCount formats, none usable"
        else -> "browser read: $rawFormatCount formats → ${choices.size} offered" +
            (if (adsBlocked > 0) " · $adsBlocked ads blocked" else "")
    }

    /**
     * How big a format is, in bytes, or 0 when nothing can be said.
     *
     * MIRRORS probe_parser.dart's rule exactly — stated size, then the
     * engine's own approximation, then bitrate x duration. That last step is
     * not a flourish: an HLS master playlist states no filesize at all, which
     * is the normal shape on every site this browser exists for, so without it
     * the native sheet showed a bare container name where the Flutter sheet
     * showed a size. Two readers of the same JSON must agree.
     *
     * kbps to bytes: rate x 1000 bits/s / 8 x seconds.
     */
    private fun sizeOf(f: org.json.JSONObject, duration: Double): Pair<Long, Boolean> {
        val exact = f.optLong("filesize", 0L)
        if (exact > 0) return Pair(exact, false)
        val approx = f.optLong("filesize_approx", 0L)
        if (approx > 0) return Pair(approx, true)
        val rate = f.optDouble("tbr", 0.0).let {
            if (it > 0) it else f.optDouble("abr", 0.0)
        }
        if (rate > 0 && duration > 0) {
            return Pair((rate * 1000 / 8 * duration).toLong(), true)
        }
        return Pair(0L, false)
    }

    /** `1234567` → `1.2 MB`. */
    private fun humanSize(bytes: Long): String {
        val mb = bytes / 1048576.0
        return when {
            mb >= 1024 -> String.format("%.2f GB", mb / 1024)
            mb >= 1 -> String.format("%.1f MB", mb)
            else -> String.format("%d KB", (bytes / 1024).coerceAtLeast(1))
        }
    }

    /** The shell every sheet on this screen is drawn into. */
    private fun sheetShell(title: String): Pair<android.app.Dialog, LinearLayout> {
        val sheet = android.app.Dialog(this)
        sheet.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
        val body = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#1B1B1B"))
            setPadding(0, dp(8), 0, dp(8))
        }
        // A grab handle, so it reads as a sheet rather than a system alert.
        body.addView(View(this).apply {
            setBackgroundColor(Color.parseColor("#33FFFFFF"))
            layoutParams = LinearLayout.LayoutParams(dp(36), dp(4)).apply {
                gravity = Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(10)
            }
        })
        body.addView(TextView(this).apply {
            text = title
            setTextColor(Color.WHITE)
            textSize = 15f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            setPadding(dp(20), dp(2), dp(20), dp(10))
        })
        val scroll = object : android.widget.ScrollView(this) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val cap = (resources.displayMetrics.heightPixels * 0.6).toInt()
                super.onMeasure(
                    widthMeasureSpec,
                    MeasureSpec.makeMeasureSpec(cap, MeasureSpec.AT_MOST)
                )
            }
        }
        scroll.addView(body)
        sheet.setContentView(scroll)
        sheet.window?.apply {
            setBackgroundDrawable(
                android.graphics.drawable.ColorDrawable(Color.parseColor("#1B1B1B"))
            )
            setLayout(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setGravity(Gravity.BOTTOM)
        }
        return Pair(sheet, body)
    }

    /** One tappable two-line row, the shape every sheet here uses. */
    private fun sheetRow(
        into: LinearLayout,
        primary: String,
        secondary: String,
        onTap: () -> Unit
    ) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            isClickable = true
            setPadding(dp(20), dp(13), dp(20), dp(13))
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setOnClickListener { onTap() }
        }
        row.addView(TextView(this).apply {
            text = primary
            setTextColor(Color.WHITE)
            textSize = 15.5f
        })
        if (secondary.isNotEmpty()) {
            row.addView(TextView(this).apply {
                text = secondary
                setTextColor(Color.parseColor("#8CFFFFFF"))
                textSize = 12f
                maxLines = 1
                isSingleLine = true
                ellipsize = android.text.TextUtils.TruncateAt.MIDDLE
                setPadding(0, dp(2), 0, 0)
            })
        }
        into.addView(row)
    }

    /**
     * The quality list, drawn to match the sheet the rest of the app uses.
     *
     * A bare list of one-word rows was the first version and it looked like a
     * debug menu beside the sheet YouTube and TikTok links get. The same facts
     * are available here — resolution, container, size, whether there is sound
     * — so there is no reason for the browser to feel like the cheaper half of
     * the app.
     */
    private fun showChoices(mediaUrl: String, choices: List<Choice>) {
        // Captured now, while the page is still on screen.
        val sourcePage = web?.url ?: ""
        val sheet = android.app.Dialog(this)
        sheet.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)

        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#1B1B1B"))
        }
        outer.addView(grabber())

        // ---- header: what you are about to take ------------------------------
        //
        // The Flutter sheet leads with the title and a line of context, and the
        // native one led with the words "Choose quality" and nothing else --
        // which is how somebody ends up unsure whether they are downloading the
        // video or the advert. The same two facts are available here.
        val meta = ArrayList<String>()
        // THE PLAYER'S FIGURE WHEN NOTHING WAS EXTRACTED. The instant path
        // never reads a duration because it never reads anything, and a header
        // that silently drops the running time on exactly the fastest sites is
        // a poorer sheet for no reason — the watcher has known it all along.
        val shownDuration = if (lastDuration > 0) lastDuration else lastReportedDuration
        if (shownDuration > 0) meta.add(clock(shownDuration))
        prettyHost(sourcePage)?.let { meta.add(it) }
        meta.add(choices.size.toString() + " · " + labelPickText)

        val head = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(16), dp(2), dp(16), dp(12))
        }
        head.addView(View(this).apply {
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = dp(6).toFloat()
                setColor(Color.parseColor("#242424"))
            }
            layoutParams = LinearLayout.LayoutParams(dp(56), dp(38))
        })
        val headText = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
            ).apply { leftMargin = dp(12) }
        }
        headText.addView(TextView(this).apply {
            text = pageTitle.ifEmpty { web?.title ?: labelPickText }
            setTextColor(Color.WHITE)
            textSize = 14f
            maxLines = 2
            ellipsize = android.text.TextUtils.TruncateAt.END
        })
        headText.addView(TextView(this).apply {
            text = meta.joinToString(" · ")
            setTextColor(Color.parseColor("#80FFFFFF"))
            textSize = 11f
            maxLines = 1
            isSingleLine = true
            setPadding(0, dp(4), 0, 0)
        })
        head.addView(headText)
        outer.addView(head)
        outer.addView(rule())

        // ---- the rows --------------------------------------------------------
        val list = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        var chosen = choices.first()
        val rows = ArrayList<LinearLayout>()

        fun repaint() {
            for ((i, row) in rows.withIndex()) {
                row.setBackgroundColor(
                    if (choices[i] === chosen) Color.parseColor("#14FFFFFF")
                    else Color.TRANSPARENT
                )
                (row.getChildAt(0) as? TextView)?.text =
                    if (choices[i] === chosen) "\u25CF" else "\u25CB"
                (row.getChildAt(0) as? TextView)?.setTextColor(
                    if (choices[i] === chosen) Color.parseColor("#2F6BFF")
                    else Color.parseColor("#4DFFFFFF")
                )
            }
        }

        for (c in choices) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                isClickable = true
                setPadding(dp(16), dp(11), dp(16), dp(11))
                layoutParams = LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
            }
            // A RADIO, THEN A CONFIRM — the Flutter sheet's model, and it is the
            // safer one over a page: a single tap that both chooses and starts
            // means a mis-tap downloads two gigabytes.
            row.addView(TextView(this).apply {
                text = "\u25CB"
                textSize = 15f
                setTextColor(Color.parseColor("#4DFFFFFF"))
                layoutParams = LinearLayout.LayoutParams(dp(24), ViewGroup.LayoutParams.WRAP_CONTENT)
            })
            row.addView(TextView(this).apply {
                text = c.label
                setTextColor(Color.WHITE)
                textSize = 13.5f
                layoutParams = LinearLayout.LayoutParams(dp(64), ViewGroup.LayoutParams.WRAP_CONTENT)
            })
            row.addView(TextView(this).apply {
                text = c.ext
                setTextColor(Color.parseColor("#80FFFFFF"))
                textSize = 12f
                layoutParams = LinearLayout.LayoutParams(dp(52), ViewGroup.LayoutParams.WRAP_CONTENT)
            })
            if (c.badge.isNotEmpty()) {
                row.addView(TextView(this).apply {
                    text = c.badge
                    setTextColor(Color.parseColor("#F0A020"))
                    textSize = 10f
                    setPadding(dp(5), dp(1), dp(5), dp(1))
                    background = android.graphics.drawable.GradientDrawable().apply {
                        cornerRadius = dp(4).toFloat()
                        setColor(Color.parseColor("#2EF0A020"))
                    }
                })
            }
            row.addView(View(this).apply {
                layoutParams = LinearLayout.LayoutParams(0, dp(1), 1f)
            })
            // THE SIZE, RIGHT-ALIGNED, WHICH IS WHY ANY OF THIS CHANGED. It is
            // the number people actually choose on -- and until sizeOf existed
            // this column was simply empty on every HLS site.
            row.addView(TextView(this).apply {
                text = when {
                    c.selector == SELECTOR_MORE -> ""
                    c.bytes <= 0 -> "—"
                    c.estimated -> "~" + humanSize(c.bytes)
                    else -> humanSize(c.bytes)
                }
                setTextColor(Color.parseColor("#80FFFFFF"))
                textSize = 12f
            })
            row.setOnClickListener {
                chosen = c
                repaint()
            }
            rows.add(row)
            list.addView(row)
        }
        repaint()

        // AT_MOST, NOT A FIXED SIZE. Three qualities take three rows; twelve
        // scroll. Anything that sets a height instead of a ceiling gives the
        // short case the tall case's dimensions, which is exactly what a sheet
        // must never do -- it covered the video somebody was choosing for.
        val scroll = object : android.widget.ScrollView(this) {
            override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
                val cap = (resources.displayMetrics.heightPixels * 0.5).toInt()
                super.onMeasure(
                    widthMeasureSpec,
                    MeasureSpec.makeMeasureSpec(cap, MeasureSpec.AT_MOST)
                )
            }
        }
        scroll.addView(list)
        scroll.isVerticalScrollBarEnabled = false
        scroll.layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
        outer.addView(scroll)
        outer.addView(rule())

        // ---- the confirm -----------------------------------------------------
        outer.addView(TextView(this).apply {
            text = labelDownloadText
            textSize = 15f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            isClickable = true
            background = android.graphics.drawable.GradientDrawable().apply {
                cornerRadius = dp(12).toFloat()
                setColor(Color.parseColor("#2F6BFF"))
            }
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(46)
            ).apply { setMargins(dp(16), dp(12), dp(16), dp(16)) }
            setOnClickListener {
                // NOT A FORMAT — A REQUEST TO GO AND LOOK PROPERLY.
                if (chosen.selector == SELECTOR_MORE) {
                    sheet.dismiss()
                    offerQualities(null, skipInstant = true)
                    return@setOnClickListener
                }
                // THE ROW'S HOST, NOT JUST THE SHEET'S. A declared ladder can
                // point at a different delivery host than the one the session
                // was saved for, and a request to that host with no Referer is
                // the 404 this project has already debugged once.
                if (chosen.url.isNotEmpty()) saveSessionFor(sourcePage, chosen.url)
                DownloadEngine.sendBrowserPick(
                    // THE ROW'S OWN ADDRESS WINS. A parsed reply's rows all
                    // share the sheet's address and pick a format out of it; a
                    // sibling row IS a different file, and sending the sheet's
                    // address would download whichever quality the sheet
                    // happened to be opened on.
                    chosen.url.ifEmpty { mediaUrl },
                    chosen.selector,
                    pageTitle,
                    chosen.merge,
                    rawFormatCount,
                    choices.size,
                    sourcePage
                )
                // A download somebody cannot see starting is a download they
                // will start again.
                android.widget.Toast.makeText(
                    this@BrowserActivity,
                    labelStartedText,
                    android.widget.Toast.LENGTH_SHORT
                ).show()
                sheet.dismiss()
            }
        })

        sheet.setContentView(outer)
        sheet.setOnCancelListener { DownloadEngine.cancelBrowserProbe() }
        openSheet = sheet
        openSheetUrl = mediaUrl
        sheet.setOnDismissListener {
            if (openSheet === sheet) openSheet = null
        }
        sheet.window?.apply {
            setBackgroundDrawable(
                android.graphics.drawable.ColorDrawable(Color.parseColor("#1B1B1B"))
            )
            // WRAP, so the sheet is the height of what is in it. The
            // ceiling lives on the list, where it belongs; setting it here
            // made every sheet the tallest sheet.
            setLayout(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
            setGravity(Gravity.BOTTOM)
        }
        sheet.show()
    }

    /** The handle that makes a dialog read as a sheet. */
    private fun grabber(): View = View(this).apply {
        setBackgroundColor(Color.parseColor("#33FFFFFF"))
        layoutParams = LinearLayout.LayoutParams(dp(36), dp(4)).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            topMargin = dp(8)
            bottomMargin = dp(10)
        }
    }

    /** A hairline, the same one the Flutter sheet separates its bands with. */
    private fun rule(): View = View(this).apply {
        setBackgroundColor(Color.parseColor("#14FFFFFF"))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 1
        )
    }

    /** `754.0` → `12:34`; `4210.0` → `1:10:10`. */
    private fun clock(seconds: Double): String {
        val total = seconds.toInt()
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) {
            String.format("%d:%02d:%02d", h, m, s)
        } else {
            String.format("%d:%02d", m, s)
        }
    }

    /**
     * Every media address the page has offered, for the person to choose from.
     *
     * The manual counterpart to the floating button, and the reason the button
     * is allowed to be cautious. Newest first, because the newest is the one
     * they most likely just pressed play on.
     */
    private fun showStreamPicker() {
        val all = synchronized(sniffed) { sniffed.map { it.url } }.reversed()
        val page = web?.url
        val rows = ArrayList<String>()
        if (page != null && prefersPageUrl(page)) rows.add(page)
        rows.addAll(all)
        if (page != null && !rows.contains(page)) rows.add(page)
        if (rows.isEmpty()) {
            android.widget.Toast
                .makeText(this, labelHintText, android.widget.Toast.LENGTH_LONG)
                .show()
            return
        }
        val shell = sheetShell(labelStreamsText)
        val sheet = shell.first
        val body = shell.second
        for (u in rows.take(12)) {
            val kind = when {
                u == page -> prettyHost(u) ?: u
                mediaKind(u) >= 3 -> "HLS / DASH"
                else -> "MP4"
            }
            sheetRow(body, kind, shortAddress(u)) {
                sheet.dismiss()
                offerQualities(u)
            }
        }
        sheet.show()
    }

    /**
     * What to do when a read came back with nothing usable.
     *
     * IT NO LONGER LEAVES THE SITE BY ITSELF, and that was the loudest
     * complaint about this screen. The old behaviour sent the page to the
     * downloads screen automatically, so somebody who tapped Download over a
     * video found themselves on a different screen entirely, with the quality
     * sheet opening there — and their place in the site gone. Even when it
     * worked it felt like a failure.
     *
     * Now the failure is stated where it happened, with the two things worth
     * trying next, and going to the other screen is something the person
     * CHOOSES rather than something that happens to them.
     */
    private fun showUnreadable(attempted: String) {
        val shell = sheetShell(labelUnreadableText)
        val sheet = shell.first
        val body = shell.second
        sheetRow(body, labelRetryText, shortAddress(attempted)) {
            sheet.dismiss()
            offerQualities(attempted)
        }
        val others = synchronized(sniffed) { sniffed.size }
        if (others > 1) {
            sheetRow(body, labelStreamsText, "" + others) {
                sheet.dismiss()
                showStreamPicker()
            }
        }
        // A REFUSAL ON A VPN IS USUALLY THE VPN. Said here rather than left
        // for somebody to work out, because the remedy is the opposite of the
        // one that got them onto this site in the first place.
        if (onVpn()) {
            sheetRow(body, labelVpnHintText, "") { }
        }
        sheetRow(body, labelSendScreenText, "") {
            sheet.dismiss()
            handOverCurrentPage()
        }
        sheet.show()
    }

    /**
     * Says, in plain words, that the NETWORK is the problem — and what to do.
     *
     * This user's situation is the reason it exists, and it is not unusual: a
     * router that blocks sites by name, so those sites need a VPN, and a VPN
     * that YouTube and TikTok then refuse because a shared exit address is
     * exactly what a bot wall looks for. Two opposite remedies, and no way for
     * somebody to tell which one they are looking at from a blank page.
     *
     * The two facts that separate them are both available here: whether a VPN
     * is carrying this connection, and whether the failure was a NAME that
     * would not resolve. So the sheet says which, and offers the setting.
     *
     * PRIVATE DNS IS THE ANSWER NOBODY IS TOLD ABOUT. A name-based block is
     * usually done at the router's resolver, and Android has shipped
     * encrypted DNS as a system setting since version 9 — turning it on
     * defeats that kind of block WITHOUT a VPN, which means the blocked sites
     * open and YouTube keeps working. One setting instead of a trade-off.
     */
    private fun showNetworkTrouble(reason: String) {
        if (isFinishing || isDestroyed) return
        // ONE SHEET PER PAGE. A refused connection is reported once per
        // sub-resource as well as for the page, and the device trail shows
        // four identical failures in five seconds — which would have been four
        // stacked dialogs over a blank screen.
        // PER HOST, AND WITH A COOLDOWN. Keying on the address alone was not
        // enough: each failed load starts a new page, which clears the guard,
        // so the device trail shows the same refusal reported three times in
        // twenty seconds — three sheets over one blank screen.
        val here = web?.url ?: ""
        val key = prettyHost(here) ?: here
        val now = System.currentTimeMillis()
        if (key == troubleShownFor && now - troubleShownAt < 60000) return
        troubleShownFor = key
        troubleShownAt = now

        // MEASURE FIRST, THEN SPEAK — and this is the fix the trail demanded.
        //
        // The old version only offered the resolver advice when the error
        // MENTIONED a name lookup. But a resolver that blocks a site usually
        // does not refuse to answer; it answers with somewhere that goes
        // nowhere, and the browser then reports a REFUSED CONNECTION. So on
        // the one connection this feature exists for, the advice stayed silent
        // and the report said `dns unknown`.
        //
        // Every page that will not load is now measured, and the sheet says
        // what was found rather than what the error string hinted at.
        val host = prettyHost(here)
        Thread {
            var verdict = "unknown"
            var bypassable = false
            var privateDns = "unknown"
            if (host != null) {
                try {
                    val answer = DownloadEngine.networkCheck(listOf(host))
                    privateDns = (answer["privateDns"] as? String) ?: "unknown"
                    @Suppress("UNCHECKED_CAST")
                    val rows = answer["hosts"] as? List<Map<String, Any?>>
                    verdict = (rows?.firstOrNull()?.get("verdict") as? String) ?: "unknown"
                    bypassable = rows?.firstOrNull()?.get("bypassable") == true
                } catch (_: Throwable) {
                }
            }
            trail(
                "resolver check · " + (host ?: "?") + "=" + verdict +
                    (if (bypassable) " · bypassable" else "") +
                    " · private DNS " + privateDns + " · " + reason
            )
            // `differs` is deliberately NOT here — see the note in
            // networkCheck. Two public answers disagreeing is what a large
            // site looks like, not what a block looks like.
            // `differs` is deliberately NOT here — see the note in
            // networkCheck. Two public answers disagreeing is what a large
            // site looks like, not what a block looks like.
            val nameBlocked = verdict == "dns" || verdict == "sinkhole"

            // ---------------------------------------------------------------
            // DO IT, DO NOT ASK.
            //
            // The person who reported this could not tell us which button they
            // had pressed — only that pressing something had worked. That is
            // the whole verdict on the sheet: a measurement had already proved
            // what to do, and it was still being handed over as a decision.
            //
            // So when the name is blocked AND the route was proved reachable,
            // the bypass simply turns itself on and the page reloads. The
            // choice is remembered, so this happens at most once per phone;
            // afterwards it is on before the first page is asked for. Nothing
            // is silently traded away — it changes only which address the
            // phone is told to connect to — and the trail says it happened.
            //
            // The sheet stays for the cases where there is a real decision:
            // a route that is genuinely blocked, or a bypass that did not take.
            if (nameBlocked && bypassable && !DnsBypassProxy.isRunning) {
                val opened = DnsBypassProxy.enable(applicationContext)
                if (opened > 0) {
                    runOnUiThread {
                        if (isFinishing || isDestroyed) return@runOnUiThread
                        applyProxy(opened)
                        trail("blocked name — turned the app's own resolver on and reloading")
                        troubleShownFor = ""
                        troubleShownAt = 0L
                        web?.reload()
                    }
                    return@Thread
                }
            }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                val shell = sheetShell(labelBlockedText)
                val sheet = shell.first
                val body = shell.second
                if (nameBlocked) {
                    sheetRow(body, labelDnsFoundText, "")
                    // THE ONE ACTION THAT NEEDS NOTHING FROM ANYBODY. Offered
                    // FIRST and only when it was measured to work: the app
                    // resolves the name itself and opens the page, with no VPN
                    // and no system setting — so YouTube, which a VPN would
                    // have broken, is untouched.
                    if (bypassable) {
                        sheetRow(body, labelBypassText, labelBypassHintText) {
                            sheet.dismiss()
                            val opened = DnsBypassProxy.start()
                            if (opened > 0) {
                                applyProxy(opened)
                                troubleShownFor = ""
                                web?.reload()
                            }
                        }
                    }
                    if (privateDns != "on") {
                        sheetRow(body, labelDnsHintText, labelOpenSettingsText) {
                            sheet.dismiss()
                            openPrivateDnsSettings()
                        }
                    }
                } else if (verdict == "ok") {
                    sheetRow(body, labelDeeperText, "")
                    if (!onVpn()) sheetRow(body, labelVpnHintText, "")
                }
                if (onVpn() && nameBlocked) {
                    // Worth saying plainly: the VPN is not what is blocking
                    // this, so turning it off will not help and turning it on
                    // was never the fix.
                    sheetRow(body, labelVpnHintText, "")
                }
                sheetRow(body, labelRetryText, host ?: "") {
                    sheet.dismiss()
                    troubleShownFor = ""
                    web?.reload()
                }
                sheet.show()
            }
        }.start()
    }

    /** A sheet row with no action, for a statement rather than a choice. */
    private fun sheetRow(into: LinearLayout, primary: String, secondary: String) {
        sheetRow(into, primary, secondary) {}
    }

    /** True when a VPN is carrying this connection. */
    private fun onVpn(): Boolean {
        return try {
            val cm = getSystemService(android.content.Context.CONNECTIVITY_SERVICE)
                as? android.net.ConnectivityManager ?: return false
            val net = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(net) ?: return false
            // Stated as an absence by Android, and reading the transport
            // instead misses a VPN tunnelling over Wi-Fi — the ordinary case.
            !caps.hasCapability(
                android.net.NetworkCapabilities.NET_CAPABILITY_NOT_VPN
            )
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Opens the encrypted-DNS setting, or the network screen if that is all
     * this build of Android will offer.
     *
     * Two fallbacks deep, because the private-DNS screen has moved between
     * versions and manufacturers and landing somebody on a crash is worse than
     * landing them one tap away.
     */
    private fun openPrivateDnsSettings() {
        val tries = listOf(
            "android.settings.WIRELESS_SETTINGS",
            "android.settings.SETTINGS"
        )
        for (action in tries) {
            try {
                startActivity(Intent(action))
                return
            } catch (_: Throwable) {
            }
        }
    }

    /** `https://cdn.example.com/a/b/master.m3u8?x=1` → `cdn.example.com/…/master.m3u8`. */
    private fun shortAddress(url: String): String {
        val host = prettyHost(url) ?: return url.take(48)
        val tail = url.substringBefore('?').substringAfterLast('/')
        return if (tail.isEmpty()) host else host + "/…/" + tail
    }

    /**
     * Records everything the engine will need in order to be let in.
     *
     * BOTH HOSTS GET BOTH FACTS. The page and the video almost never share a
     * host — a page on pornhub.com plays a file from phncdn.com — and it is
     * the CDN that checks. The device notification showed exactly what happens
     * when only the address is handed over: the playlist downloads fine and
     * then every segment answers 404, because a segment request carrying no
     * Referer is not one that CDN will serve.
     *
     * The agent matters as much as the cookie: a clearance cookie is issued to
     * one browser and checked against whoever presents it, so a cookie earned
     * here and replayed by the engine under its own name is refused — which is
     * what the trail showed, pornhub cookies present and still 403.
     *
     * Shared by the in-place chooser AND the hand-off to the downloads screen,
     * because a session saved on only one of two paths is a bug waiting for
     * whichever path is taken next.
     */
    private fun saveSessionFor(pageUrl: String, mediaUrl: String) {
        try {
            CookieJar.harvest(this, listOf(pageUrl))
        } catch (_: Throwable) {
            // A missing session is worth trying without; a crash is not.
        }
        try {
            val ua = web?.settings?.userAgentString
            val uaDir = java.io.File(filesDir, "site_ua")
            val refDir = java.io.File(filesDir, "site_referer")
            if (!uaDir.exists()) uaDir.mkdirs()
            if (!refDir.exists()) refDir.mkdirs()
            for (h in listOfNotNull(prettyHost(pageUrl), prettyHost(mediaUrl))) {
                val key = h.lowercase()
                if (!ua.isNullOrBlank()) {
                    java.io.File(uaDir, "$key.txt").writeText(ua)
                }
                java.io.File(refDir, "$key.txt").writeText(pageUrl)
            }
        } catch (_: Throwable) {
        }
    }

    /**
     * Give the page currently on screen to the reader, with its session.
     *
     * CHOSEN, NEVER AUTOMATIC — see [showUnreadable]. The handover reuses the
     * share path rather than inventing a new one: sharing a link into Innocent
     * is the single most exercised route in this app, it survives a cold
     * start, it supersedes an in-flight read correctly, and it is already
     * instrumented end to end.
     */
    private fun handOverCurrentPage() {
        val current = web?.url ?: return
        val chosen = bestSniffed() ?: current
        saveSessionFor(current, chosen)
        try {
            val send = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_SEND
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, chosen)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            startActivity(send)
        } catch (_: Throwable) {
        }
        // DELIBERATELY NOT finish(). Back returns to the page they were on,
        // still scrolled where they left it.
        updateButtons()
    }

    /**
     * Who is visible, and why.
     *
     * The floating button means one thing and one thing only: THE MAIN VIDEO
     * IS PLAYING AND CAN BE TAKEN. Not "this page has media on it", which was
     * the old rule and which is true of every advert; not "something might
     * work", which is a button that teaches people to distrust buttons.
     *
     * The toolbar icon is the other half of the bargain — it appears as soon
     * as there is anything at all, so a page the cautious rule declines to
     * endorse is never a dead end.
     */
    private fun updateButtons() {
        val count = synchronized(sniffed) { sniffed.size }
        val page = web?.url
        val readable = count > 0 || prefersPageUrl(page)
        streamsButton?.visibility = if (readable) View.VISIBLE else View.GONE

        // THE ADVERT RULE DOES NOT APPLY WHERE THE ADVERT CANNOT BE TAKEN, and
        // missing that is why YouTube had no button at all.
        //
        // The whole reason the button waits for the main video is that on a
        // stream-first site we hand over a SNIFFED ADDRESS, and during a
        // pre-roll the newest address IS the pre-roll. On a page-first site we
        // hand over the PAGE, and the reader answers a page address with the
        // video that page is about — never with the advert in front of it. So
        // on YouTube the advert rule is protecting against something that
        // cannot happen, while being strict enough to hide the button forever
        // if the player markup is not what the script expects. It was.
        //
        // On a page-first VIDEO page the button therefore appears as soon as
        // there is any sign of playback: a video running, a media request seen,
        // or — the case that would otherwise be unrecoverable — a script that
        // never spoke at all. Deliberately narrow: a feed or a search result is
        // not a video page, and the strict rule still governs everywhere else.
        val pageFirstVideo = prefersPageUrl(page) && looksLikeWatchPage(page)
        val playbackSign = videoPlaying || count > 0 || watcherSilent
        val show = readable && (mainVideoLive || (pageFirstVideo && playbackSign))
        val button = grabButton ?: return
        if (show && button.visibility != View.VISIBLE) {
            button.alpha = 0f
            button.scaleX = 0.85f
            button.scaleY = 0.85f
            button.visibility = View.VISIBLE
            button.animate().alpha(1f).scaleX(1f).scaleY(1f).setDuration(160).start()
            ui.removeCallbacks(verdict)
            trail(
                "download button shown · " +
                    (prettyHost(page) ?: "") +
                    (if (mainVideoLive) " · main video" else " · page-first") +
                    (if (watcherSilent) " · watcher silent" else "") +
                    " · media seen=" + count
            )
        } else if (!show && button.visibility == View.VISIBLE) {
            button.visibility = View.GONE
        }
        if (button.isEnabled) button.text = labelDownloadText
    }

    /**
     * A published quality: `1080P_4000K_57004305.mp4` — height, bitrate, id.
     *
     * Not a guess at a naming scheme in general; this is the exact shape
     * PornHub and its family publish, and it appeared twice in one device
     * trail as two separate hand-picked reads.
     */
    private val qualityFile =
        Regex("^([0-9]{3,4})[pP][_-]([0-9]{2,5})[kK][_-](.+)[.](mp4|webm|m4v)$")

    /**
     * A playlist the PAGE declared, newest first — its master, if it has one.
     *
     * Distinguished from a sniffed one by having come out of the player's
     * configuration rather than off the wire, which is exactly the difference
     * between the list of qualities and the one quality being played.
     */
    private fun declaredPlaylist(): String? = synchronized(sniffed) {
        sniffed.lastOrNull { it.label.isNotEmpty() && mediaKind(it.url) >= 3 }?.url
            ?: sniffed.lastOrNull { mediaKind(it.url) >= 3 && looksLikeMaster(it.url) }?.url
    }

    /** Orders quality names the site chose, including the ones that are words. */
    private fun rankOf(label: String): Int {
        val digits = label.takeWhile { it.isDigit() }
        val n = digits.toIntOrNull()
        if (n != null && n > 0) return n
        return when (label.lowercase()) {
            "high", "hd", "best" -> 1080
            "medium", "sd" -> 480
            "low" -> 240
            else -> 1
        }
    }

    /**
     * The ladder the PAGE declared, with no extraction and no inference.
     *
     * The site has already chosen the qualities and named them — this only
     * reads. Which makes it both faster and more accurate than anything we
     * could work out: `1080p` from PornHub's own `mediaDefinitions` beats a
     * height guessed out of a file name, and `High` from XVideos is what
     * XVideos calls it.
     *
     * One row per name, newest sighting winning, ordered the way somebody
     * thinks about quality. Playlists are dropped from this list on purpose:
     * an HLS master has no single size and belongs to the reader, not here.
     */
    private fun declaredChoices(): List<Choice>? {
        val declared = synchronized(sniffed) {
            // NOT WINDOWED BY THE ADVERT MARK, and deliberately. A declared
            // address comes out of the player's configuration, which is written
            // for the film and is present from the moment the page loads —
            // long before the advert finishes. The advert rule still governs
            // whether the BUTTON appears; it has no business filtering a list
            // the site itself published.
            sniffed.filter { it.label.isNotEmpty() && mediaKind(it.url) == 2 }
        }
        if (declared.isEmpty()) return null
        val rows = ArrayList<Choice>()
        val seen = HashSet<String>()
        for (h in declared.reversed()) {
            val key = h.label.lowercase()
            if (!seen.add(key)) continue
            val name = h.url.substringBefore('?').substringAfterLast('/')
            val ext = name.substringAfterLast('.', "mp4").uppercase()
            rows.add(
                Choice(
                    selector = "best",
                    label = if (h.label.last().isDigit()) h.label + "p" else h.label,
                    merge = false,
                    url = h.url,
                    ext = ext,
                    bytes = 0L,
                    estimated = false,
                    badge = ""
                )
            )
        }
        rows.sortByDescending { rankOf(it.label) }
        return if (rows.isNotEmpty()) rows else null
    }

    /**
     * Asks each address how big it is, in parallel, and gives up quickly.
     *
     * AN EXACT SIZE, WHERE THERE WOULD OTHERWISE BE NONE. A declared address
     * carries a quality but no length, and an estimate from a bitrate is not
     * available either because nothing has been extracted. One HEAD request
     * answers it exactly — and since this path has just saved a ten-second
     * extraction, spending a second or two on real numbers is a good trade.
     *
     * Best-effort throughout: a row whose size cannot be measured is still a
     * row somebody can choose, and a slow CDN must never hold the sheet shut.
     * Carries the session the browser earned, because these hosts refuse a
     * request with no Referer — the same lesson the segment 404s taught.
     */
    private fun withSizes(rows: List<Choice>, agent: String?, referer: String): List<Choice> {
        val out = arrayOfNulls<Choice>(rows.size)
        val threads = ArrayList<Thread>()
        for ((i, c) in rows.withIndex()) {
            out[i] = c
            if (c.url.isEmpty()) continue
            val t = Thread {
                val size = sizeOfUrl(c.url, agent, referer)
                if (size > 0) out[i] = c.copy(bytes = size, estimated = false)
            }
            threads.add(t)
            t.start()
        }
        val deadline = System.currentTimeMillis() + 5000
        for (t in threads) {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) break
            try {
                t.join(left)
            } catch (_: Throwable) {
            }
        }
        // A MEASURED SIZE IS BEST; AN ESTIMATE BEATS AN EM DASH. Some CDNs
        // (phncdn among them) refuse both a HEAD and a one-byte GET, so a row
        // the site itself named with a bitrate — `1080P_4000K_…mp4` — comes back
        // with no size at all. That bitrate and the running time the player has
        // already reported are enough to estimate one. Only fills rows the
        // measurement left at zero, and marks them estimated so the sheet can
        // show the `~` it shows for every other guess.
        val duration = if (lastReportedDuration > 0) lastReportedDuration else maxSeenDuration
        if (duration > 0) {
            for (i in out.indices) {
                val c = out[i] ?: continue
                if (c.bytes > 0) continue
                val kbps = bitrateFromName(c.url)
                if (kbps > 0) {
                    val bytes = (kbps.toDouble() * 1000 / 8 * duration).toLong()
                    if (bytes > 0) out[i] = c.copy(bytes = bytes, estimated = true)
                }
            }
        }
        return out.filterNotNull()
    }

    /** `…/1080P_4000K_57004305.mp4` → 4000 kbps, or 0 when the name has none. */
    private fun bitrateFromName(url: String): Int {
        val name = url.substringBefore('?').substringAfterLast('/')
        val m = Regex("[_-]([0-9]{2,5})[kK][_.-]").find(name) ?: return 0
        return m.groupValues[1].toIntOrNull() ?: 0
    }

    /**
     * A connection to a media host, THROUGH THE APP'S OWN RESOLVER WHEN IT IS
     * RUNNING.
     *
     * These CDN names can be poisoned on the same networks the site names are,
     * and a plain connection uses the system resolver — so it would fail to
     * connect at all, which is exactly how a size came back empty on a network
     * where the download itself works (the download goes through the proxy; a
     * bare HEAD did not). Routing a HEAD, a range GET and a playlist fetch
     * through the loopback proxy makes them resolve the same way the download
     * does. Transparent when the bypass is off: a direct connection, as before.
     */
    private fun openConn(url: String): java.net.HttpURLConnection {
        val u = java.net.URL(url)
        val raw = if (DnsBypassProxy.isRunning) {
            u.openConnection(
                java.net.Proxy(
                    java.net.Proxy.Type.HTTP,
                    java.net.InetSocketAddress("127.0.0.1", DnsBypassProxy.port)
                )
            )
        } else {
            u.openConnection()
        }
        return raw as java.net.HttpURLConnection
    }

    /**
     * Fetches a small text resource — a playlist — with the session the browser
     * earned, through the app resolver when it is running, and gives up fast.
     *
     * Capped hard: a master playlist is kilobytes, and anything claiming to be
     * one but running to megabytes is not something to read into memory. Carries
     * the Referer and Cookie these hosts refuse a request without, the same
     * lesson the segment 404s taught.
     */
    private fun fetchText(url: String, agent: String?, referer: String): String? {
        var conn: java.net.HttpURLConnection? = null
        return try {
            conn = openConn(url).apply {
                requestMethod = "GET"
                connectTimeout = 5000
                readTimeout = 5000
                instanceFollowRedirects = true
                if (!agent.isNullOrBlank()) setRequestProperty("User-Agent", agent)
                setRequestProperty("Referer", referer)
                CookieManager.getInstance().getCookie(url)
                    ?.takeIf { it.isNotBlank() }
                    ?.let { setRequestProperty("Cookie", it) }
            }
            if (conn.responseCode !in 200..299) return null
            conn.inputStream.use { input ->
                val cap = 512 * 1024
                val buf = ByteArray(cap)
                var total = 0
                while (total < cap) {
                    val r = input.read(buf, total, cap - total)
                    if (r < 0) break
                    total += r
                }
                String(buf, 0, total, Charsets.UTF_8)
            }
        } catch (_: Throwable) {
            null
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * How big this file is — asked twice, two different ways.
     *
     * A HEAD IS THE POLITE QUESTION AND MANY CDNs REFUSE IT. The device
     * screenshot shows the consequence: a quality row with an em dash where
     * the size should be, on a site whose sizes are perfectly knowable. So
     * when HEAD comes back with nothing, the same question is asked as a GET
     * for a SINGLE BYTE — `Range: bytes=0-0` — and the answer arrives in the
     * `Content-Range` header as `bytes 0-0/TOTAL`. One byte of traffic for a
     * number somebody uses to choose.
     */
    private fun sizeOfUrl(url: String, agent: String?, referer: String): Long {
        val head = headSize(url, agent, referer)
        if (head > 0) return head
        return rangeSize(url, agent, referer)
    }

    /** `Content-Range: bytes 0-0/123456` → 123456, or 0. */
    private fun rangeSize(url: String, agent: String?, referer: String): Long {
        var conn: java.net.HttpURLConnection? = null
        return try {
            conn = openConn(url).apply {
                requestMethod = "GET"
                connectTimeout = 4000
                readTimeout = 4000
                instanceFollowRedirects = true
                setRequestProperty("Range", "bytes=0-0")
                if (!agent.isNullOrBlank()) setRequestProperty("User-Agent", agent)
                setRequestProperty("Referer", referer)
                CookieManager.getInstance().getCookie(url)
                    ?.takeIf { it.isNotBlank() }
                    ?.let { setRequestProperty("Cookie", it) }
            }
            val range = conn.getHeaderField("Content-Range") ?: return 0L
            range.substringAfterLast('/').trim().toLongOrNull() ?: 0L
        } catch (_: Throwable) {
            0L
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Throwable) {
            }
        }
    }

    /** One HEAD request, or 0. */
    private fun headSize(url: String, agent: String?, referer: String): Long {
        var conn: java.net.HttpURLConnection? = null
        return try {
            conn = openConn(url).apply {
                requestMethod = "HEAD"
                connectTimeout = 4000
                readTimeout = 4000
                instanceFollowRedirects = true
                if (!agent.isNullOrBlank()) setRequestProperty("User-Agent", agent)
                setRequestProperty("Referer", referer)
                CookieManager.getInstance().getCookie(url)
                    ?.takeIf { it.isNotBlank() }
                    ?.let { setRequestProperty("Cookie", it) }
            }
            val len = conn.contentLengthLong
            if (len > 0) len else 0L
        } catch (_: Throwable) {
            0L
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * The whole quality ladder, straight off the page, with no read at all.
     *
     * THE TRAIL SHOWED THE PERSON DOING THIS BY HAND. Two entries, minutes
     * apart, each costing a ten-second extraction to be told `1 formats · 1
     * offered`:
     *
     *     read started · stream · em.phncdn.com//240P_1000K_57004305.mp4
     *     read started · stream · em.phncdn.com//1080P_4000K_57004305.mp4
     *
     * They are the same video. The site publishes each quality as its own
     * file and names it with the height, the bitrate and the video's id, and
     * the browser had already seen both go past. Everything a row needs is in
     * those names -- and the size, which no extraction would have supplied
     * either, follows from the bitrate and the duration the PLAYER is already
     * reporting.
     *
     * So this is not a faster read; it is no read. Tap the button and the
     * ladder is simply there. Returns null unless at least two DIFFERENT
     * heights share one video id, because one row proves nothing and a guess
     * would be worse than the ten seconds it saved.
     */
    private fun siblingChoices(): List<Choice>? {
        val pool = candidatePool().filter { mediaKind(it) == 2 }
        if (pool.size < 2) return null
        val families = LinkedHashMap<String, MutableList<Triple<Int, Int, String>>>()
        for (u in pool) {
            val name = u.substringBefore('?').substringAfterLast('/')
            val m = qualityFile.find(name) ?: continue
            val height = m.groupValues[1].toIntOrNull() ?: continue
            val kbps = m.groupValues[2].toIntOrNull() ?: continue
            val family = m.groupValues[3] + "." + m.groupValues[4]
            families.getOrPut(family) { mutableListOf() }
                .add(Triple(height, kbps, u))
        }
        // The newest family wins, for the same reason the newest folder does:
        // on a page with an advert in front, the film is asked for second.
        val best = families.values.lastOrNull { group ->
            group.map { it.first }.distinct().size >= 2
        } ?: return null

        val duration = if (lastReportedDuration > 0) lastReportedDuration else maxSeenDuration
        val seen = HashSet<Int>()
        val rows = ArrayList<Choice>()
        for ((height, kbps, url) in best.sortedByDescending { it.first }) {
            if (!seen.add(height)) continue
            val ext = url.substringBefore('?').substringAfterLast('.').uppercase()
            // kbps to bytes, the same arithmetic sizeOf does for a bitrate.
            val bytes = if (duration > 0) {
                (kbps.toDouble() * 1000 / 8 * duration).toLong()
            } else {
                0L
            }
            rows.add(
                Choice(
                    selector = "best",
                    label = height.toString() + "p",
                    merge = false,
                    url = url,
                    ext = ext,
                    bytes = bytes,
                    estimated = true,
                    badge = ""
                )
            )
        }
        return if (rows.size >= 2) rows else null
    }

    /**
     * The full quality ladder read straight out of the HLS master playlist.
     *
     * WHY THIS IS HERE, WHEN THE READER COULD DO IT. On a stream-first site the
     * page declares ONE progressive rung inline (XVideos calls it "Low") and
     * keeps every other quality inside its HLS master — so the instant ladder
     * was a single row, and the full read that would fill it in is a ten-second
     * round trip the person is left staring at. The master itself is a tiny
     * text file the player already fetched; parsing it here turns one row into
     * the whole ladder in the time of one small GET, WITH a size for each rung.
     * A stream carries no Content-Length, but its declared BANDWIDTH times the
     * running time the player reports is a sound estimate — the same arithmetic
     * the sibling path uses for named mp4s.
     *
     * Each row points at the MASTER and selects its own height, so yt-dlp reads
     * the master, picks that exact rendition, and pulls a separate audio track
     * in with it on the rare master that keeps one apart — which a bare variant
     * URL would silently miss.
     *
     * [agent] and [referer] are captured on the UI thread by the caller; this
     * runs on a worker and never touches the WebView.
     */
    private fun masterChoices(agent: String?, referer: String): List<Choice>? {
        val master = declaredPlaylist() ?: return null
        if (mediaKind(master) < 3) return null
        val body = fetchText(master, agent, referer) ?: return null
        // No variant list means this was a MEDIA playlist (one rendition's
        // segments), not a master — nothing to enumerate here.
        if (!body.contains("#EXT-X-STREAM-INF")) return null
        val duration = if (lastReportedDuration > 0) lastReportedDuration else maxSeenDuration
        val lines = body.split("\n")
        val rows = ArrayList<Choice>()
        val seen = HashSet<Int>()
        var i = 0
        while (i < lines.size) {
            val line = lines[i].trim()
            if (!line.startsWith("#EXT-X-STREAM-INF")) {
                i++
                continue
            }
            val bandwidth = streamBandwidth(line)
            val declaredH = streamHeight(line)
            // The variant address is the next line that is not a comment.
            var j = i + 1
            while (j < lines.size && lines[j].trim().startsWith("#")) j++
            i = j + 1
            if (j >= lines.size || lines[j].trim().isEmpty()) continue
            // A height names the rung when the stream declares one; otherwise a
            // bitrate stands in for it, so a master that omits RESOLUTION still
            // becomes a readable ladder rather than a row called "0p".
            val h = if (declaredH > 0) declaredH else bandwidthRung(bandwidth)
            if (h <= 0 || !seen.add(h)) continue
            val bytes = if (bandwidth > 0 && duration > 0) {
                (bandwidth.toDouble() / 8 * duration).toLong()
            } else {
                0L
            }
            rows.add(
                Choice(
                    selector = "b[height<=" + h + "]/bv[height<=" + h + "]+ba/best",
                    label = h.toString() + "p",
                    merge = false,
                    url = master,
                    ext = "MP4",
                    bytes = bytes,
                    estimated = bytes > 0,
                    badge = ""
                )
            )
        }
        if (rows.isEmpty()) return null
        rows.sortByDescending { rankOf(it.label) }
        return rows
    }

    /** `RESOLUTION=1280x720` → 720, or 0 when the stream declared none. */
    private fun streamHeight(line: String): Int {
        val m = Regex("RESOLUTION=[0-9]+[xX]([0-9]+)").find(line) ?: return 0
        return m.groupValues[1].toIntOrNull() ?: 0
    }

    /** Bits per second — the average preferred over the peak — or 0. */
    private fun streamBandwidth(line: String): Int {
        Regex("AVERAGE-BANDWIDTH=([0-9]+)").find(line)?.let {
            return it.groupValues[1].toIntOrNull() ?: 0
        }
        // A leading space so plain BANDWIDTH at the start of the tag list still
        // has a non-hyphen char in front — the guard that keeps this from
        // matching the tail of AVERAGE-BANDWIDTH.
        val m = Regex("[^-]BANDWIDTH=([0-9]+)").find(" " + line) ?: return 0
        return m.groupValues[1].toIntOrNull() ?: 0
    }

    /** A stand-in height for a stream that named a bitrate but no resolution. */
    private fun bandwidthRung(bandwidth: Int): Int {
        if (bandwidth <= 0) return 0
        val kbps = bandwidth / 1000
        return when {
            kbps >= 4500 -> 1080
            kbps >= 2500 -> 720
            kbps >= 1200 -> 480
            kbps >= 600 -> 360
            else -> 240
        }
    }

    /**
     * Combines quality lists into one ladder, the earlier source winning a tie.
     *
     * Rungs are matched by height, so a rung a later source repeats does not
     * become a second row for the same quality. A row that carries a measured
     * or stated size is kept over one that only estimates the same height — an
     * exact number beats a guess — but otherwise the earlier list wins, which
     * is why the caller passes the page's own declared rungs first.
     */
    private fun mergeLadders(vararg lists: List<Choice>): List<Choice> {
        val byHeight = LinkedHashMap<Int, Choice>()
        for (list in lists) {
            for (c in list) {
                val h = rankOf(c.label)
                val existing = byHeight[h]
                if (existing == null) {
                    byHeight[h] = c
                } else if (existing.bytes == 0L && c.bytes > 0L && !c.estimated) {
                    byHeight[h] = c
                }
            }
        }
        val rows = ArrayList(byHeight.values)
        rows.sortByDescending { rankOf(it.label) }
        return rows
    }

    /**
     * The best address the page offered, or null if it offered none.
     *
     * A playlist beats a plain file because it carries every quality; between
     * equals the LAST one wins, since a page usually asks for its poster and
     * preview clips before the video somebody actually pressed play on.
     *
     * WITHIN THE MAIN VIDEO'S WINDOW, when the player has given us one. That
     * window is the whole point: an advert's addresses are older than the main
     * video's first frame, so restricting the search to what arrived after it
     * removes the advert from consideration entirely rather than trying to
     * out-guess it afterwards.
     */
    private fun bestSniffed(): String? {
        val pool = candidatePool()
        if (pool.isEmpty()) return null
        // A PLAYLIST: TAKE THE FIRST OF ITS FOLDER, NOT THE LAST — and this is
        // why only one quality was ever offered.
        //
        // A player fetches the MASTER playlist first (which lists every
        // quality) and then immediately fetches the VARIANT for the one it
        // decided to play (which lists exactly one). Preferring the latest
        // therefore handed over the variant every time, and the reader
        // faithfully reported the single quality it contained.
        //
        // Grouping resolves both pressures at once: a master and its variants
        // share a folder, so the LAST DISTINCT FOLDER is the newest stream, and
        // the earliest entry inside that folder is its master.
        val playlists = pool.filter { mediaKind(it) >= 3 }
        return if (playlists.isNotEmpty()) {
            val newest = folderOf(playlists.last())
            val group = playlists.filter { folderOf(it) == newest }
            group.firstOrNull { looksLikeMaster(it) } ?: group.first()
        } else {
            pool.lastOrNull()
        }
    }

    /**
     * The addresses worth considering, oldest first.
     *
     * When the player has told us when the main video started, only what
     * arrived from then on counts — less a few seconds of slack, because a
     * master playlist is fetched while the player is still deciding to play
     * and would otherwise fall just outside its own window. If that leaves
     * nothing, everything counts: a rule that can empty the list is a rule
     * that can break the feature, and being wrong about which stream beats
     * having no stream at all.
     */
    private fun candidatePool(): List<String> {
        synchronized(sniffed) {
            val all = sniffed.filter { mediaKind(it.url) > 0 }
            if (mainVideoSince > 0L) {
                val cut = mainVideoSince - MARK_SLACK_MS
                val after = all.filter { it.at >= cut }.map { it.url }
                if (after.isNotEmpty()) return after
            }
            return all.map { it.url }
        }
    }

    /** The top-level field names, so a reply's shape is legible at a glance. */
    private fun keysOf(o: org.json.JSONObject): String {
        return try {
            val names = ArrayList<String>()
            val it = o.keys()
            while (it.hasNext() && names.size < 14) names.add(it.next())
            if (names.isEmpty()) "(none)" else names.joinToString(",")
        } catch (_: Throwable) {
            "(unreadable)"
        }
    }

    /**
     * A `formats` array nested one level down, wherever it happens to sit.
     *
     * Deliberately shallow: one level of objects and one level of arrays. A
     * full search would find arrays that only look like formats, and guessing
     * wrong here means offering somebody the wrong video.
     */
    private fun findFormatsAnywhere(root: org.json.JSONObject): org.json.JSONArray? {
        try {
            val it = root.keys()
            while (it.hasNext()) {
                val key = it.next()
                val v = root.opt(key)
                if (v is org.json.JSONObject) {
                    v.optJSONArray("formats")?.let { if (it.length() > 0) return it }
                } else if (v is org.json.JSONArray) {
                    for (i in 0 until minOf(v.length(), 4)) {
                        v.optJSONObject(i)?.optJSONArray("formats")
                            ?.let { if (it.length() > 0) return it }
                    }
                }
            }
        } catch (_: Throwable) {
        }
        return null
    }

    /**
     * The document itself as a one-entry list, when the engine returned a
     * single format rather than a choice of them.
     *
     * A bare media address often has exactly one quality, and answering "no
     * qualities" to that is wrong in the way that matters: it sends somebody
     * to another screen when the thing they asked for was right there.
     */
    private fun singleFormatAsList(doc: org.json.JSONObject): org.json.JSONArray? {
        val hasMedia = doc.optString("url", "").isNotEmpty() ||
            doc.optString("format_id", "").isNotEmpty()
        if (!hasMedia) return null
        return org.json.JSONArray().put(doc)
    }

    /**
     * One address per stream, newest stream first.
     *
     * A page can offer several: the advert, the feature, sometimes a preview.
     * They are distinguished by folder — a quality list and its variants share
     * one — and the newest is tried first because the feature is requested
     * after the advert.
     */
    private fun sniffedCandidates(): List<String> {
        val pool = candidatePool()
        val playlists = pool.filter { mediaKind(it) >= 3 }
        val source = if (playlists.isNotEmpty()) playlists else pool
        val byFolder = LinkedHashMap<String, String>()
        for (u in source) {
            val key = folderOf(u)
            val existing = byFolder[key]
            // Within a folder keep the master, which lists every quality.
            if (existing == null || (!looksLikeMaster(existing) && looksLikeMaster(u))) {
                byFolder[key] = u
            }
        }
        return byFolder.values.toList().reversed()
    }

    /** Everything up to the last slash — one stream's folder. */
    private fun folderOf(url: String): String {
        val clean = url.substringBefore('?')
        val cut = clean.lastIndexOf('/')
        return if (cut > 0) clean.substring(0, cut) else clean
    }

    /**
     * True for the sort of name a playlist file has rather than a video.
     *
     * `master`, `index`, `playlist`, `hls`, `1820` — none of these is
     * something anybody would name a video, and all of them are what a bare
     * playlist address leaves the engine to guess from.
     */
    private fun looksLikeFileName(v: String): Boolean {
        val t = v.trim().lowercase()
        if (t.isEmpty()) return true
        if (t.toIntOrNull() != null) return true
        return t == "master" || t == "index" || t == "playlist" ||
            t == "video" || t == "hls" || t.startsWith("master.") ||
            t.startsWith("index.") || t.startsWith("playlist.")
    }

    /** `index-v1-a1.m3u8` — a stream's ONE quality, not its list of them. */
    private val variantName = Regex("-v[0-9]+-a[0-9]+")

    /**
     * Names that a master playlist tends to carry, when it carries one.
     *
     * THE VARIANT CHECK COMES FIRST, and its absence is why PornHub has only
     * ever offered a single quality. `index-v1-a1.m3u8` contains "index", so
     * the old rule called it a master; it is in fact the playlist for ONE
     * rendition, and reading it truthfully reports the one quality it lists.
     * The trail said so every time -- `1 formats · 1 offered` -- and it read
     * like a stingy site rather than a naming mistake of ours.
     *
     * A `-v<n>-a<n>` suffix is HLS's own way of saying "video track n, audio
     * track n", which is a thing only a variant has.
     */
    private fun looksLikeMaster(url: String): Boolean {
        val name = url.lowercase().substringBefore('?').substringAfterLast('/')
        if (variantName.containsMatchIn(name)) return false
        return name.contains("master") || name.contains("playlist") ||
            name.contains("index")
    }

    /** `www.pornhub.com/view?x=1` → `www.pornhub.com`. */
    ///
    /// BLOCK BODY, deliberately. Written as an expression body (`= try {…}`)
    /// this does not compile: the `?: return null` inside it is a return, and
    /// Kotlin forbids returns in a function whose body is an expression. The
    /// null check moves to its own line, which is clearer anyway — the elvis
    /// was doing two jobs at once.
    private fun prettyHost(url: String?): String? {
        if (url == null) return null
        return try {
            Uri.parse(url).host
        } catch (_: Throwable) {
            null
        }
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        // FULLSCREEN FIRST. Back out of a video means back out of the video,
        // not back out of the page it is on — every player on the platform
        // behaves this way and one that does not feels broken.
        if (fullscreenView != null) {
            web?.webChromeClient?.onHideCustomView()
            return
        }
        // Back walks the page history first. Leaving the app on the first back
        // press is what an in-app browser must never do.
        val v = web
        if (v != null && v.canGoBack()) {
            v.goBack()
            return
        }
        super.onBackPressed()
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    override fun onPause() {
        super.onPause()
        try {
            CookieManager.getInstance().flush()
        } catch (_: Throwable) {
        }
    }

    override fun onDestroy() {
        try {
            CookieManager.getInstance().flush()
        } catch (_: Throwable) {
        }
        // A read nobody is waiting for is a Python process burning battery on
        // a phone whose owner has walked away. The browser probe has its own
        // id precisely so stopping it cannot touch a normal read.
        ui.removeCallbacks(verdict)
        try {
            DownloadEngine.cancelBrowserProbe()
        } catch (_: Throwable) {
        }
        try {
            web?.stopLoading()
            web?.removeJavascriptInterface("InnocentWatch")
            web?.destroy()
        } catch (_: Throwable) {
        }
        web = null
        super.onDestroy()
    }
}
