package com.innocent.media

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/**
 * Tells Dart the moment the phone's videos change — the reason a video that
 * lands on an MX Player phone is simply THERE when you look.
 *
 * Until this, nothing told the library a file had arrived. The Video tab read
 * MediaStore when it was opened or pulled, and a download that finished while
 * it was on screen stayed invisible until something else made it look again:
 * the owner measured more than ten minutes (2026-10-08).
 *
 * One ContentObserver on the video tables of every external volume (the SD
 * card's too). MediaProvider notifies for every insert, update and delete,
 * often several times per file and once per file in a folder copied in, so
 * the events are folded: one event once the changes have been quiet for
 * [QUIET] ms, and never later than [MAX_WAIT] ms after the first — a long
 * copy still shows its first files promptly. Videos only: a phone taking
 * photos does not rescan the video library.
 *
 * The event carries nothing but the time; Dart rescans (LibraryWatcher).
 */
class MediaChangeWatcher(private val context: Context) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var observer: ContentObserver? = null
    private var firstAt = 0L

    private val emit = Runnable {
        firstAt = 0L
        sink?.success(System.currentTimeMillis())
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (observer != null) return
        val o = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) = changed()
            override fun onChange(selfChange: Boolean, uri: Uri?) = changed()
        }
        val resolver = context.contentResolver
        val uris = linkedSetOf(MediaStore.Video.Media.EXTERNAL_CONTENT_URI)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                for (v in MediaStore.getExternalVolumeNames(context)) {
                    uris.add(MediaStore.Video.Media.getContentUri(v))
                }
            } catch (_: Throwable) {
            }
        }
        var any = false
        for (u in uris) {
            try {
                resolver.registerContentObserver(u, true, o)
                any = true
            } catch (_: Throwable) {
            }
        }
        if (any) observer = o
    }

    private fun changed() {
        val now = System.currentTimeMillis()
        if (firstAt == 0L) firstAt = now
        main.removeCallbacks(emit)
        main.postDelayed(emit, if (now - firstAt >= MAX_WAIT) 0L else QUIET)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        main.removeCallbacks(emit)
        observer?.let {
            try {
                context.contentResolver.unregisterContentObserver(it)
            } catch (_: Throwable) {
            }
        }
        observer = null
        firstAt = 0L
    }

    companion object {
        const val CHANNEL = "mx_clone/media_changes"
        private const val QUIET = 1200L
        private const val MAX_WAIT = 5000L

        fun register(messenger: BinaryMessenger, context: Context): MediaChangeWatcher {
            val w = MediaChangeWatcher(context.applicationContext)
            EventChannel(messenger, CHANNEL).setStreamHandler(w)
            return w
        }

        /**
         * MediaStore id → DATE_ADDED (seconds) for every video: when the
         * phone first saw each file. photo_manager's create time is
         * DATE_TAKEN where the file carries one — the date written inside
         * the file, which for a film downloaded today is whenever it was
         * made — so a fresh download read as old and never got its NEW tag
         * or its place in Recently added. One query for the whole library.
         */
        fun datesAdded(context: Context): Map<String, Long> {
            val out = HashMap<String, Long>()
            val uris = linkedSetOf(MediaStore.Video.Media.EXTERNAL_CONTENT_URI)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    for (v in MediaStore.getExternalVolumeNames(context)) {
                        uris.add(MediaStore.Video.Media.getContentUri(v))
                    }
                } catch (_: Throwable) {
                }
            }
            for (u in uris) {
                try {
                    context.contentResolver.query(
                        u,
                        arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.DATE_ADDED),
                        null, null, null
                    )?.use { c ->
                        val id = c.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
                        val added = c.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_ADDED)
                        while (c.moveToNext()) {
                            out[c.getLong(id).toString()] = c.getLong(added)
                        }
                    }
                } catch (_: Throwable) {
                }
            }
            return out
        }
    }
}
