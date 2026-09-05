package com.innocent.media

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.view.KeyEvent
import android.widget.RemoteViews

/**
 * Home-screen widget for Innocent's music player. Shows the current track
 * with previous / play-pause / next controls.
 *
 * Data lives in the "music_widget_prefs" SharedPreferences, written by the
 * Flutter side through the mx_clone/music_widget MethodChannel (see
 * MainActivity). After writing, MainActivity calls [render] directly, which
 * rebuilds the RemoteViews and pushes them with updateAppWidget — no
 * broadcast / onUpdate round-trip, so it is deterministic on every device.
 *
 * The transport buttons deliver media-button KeyEvents to the existing
 * audio_service MediaButtonReceiver (the MediaSession the playback
 * notification already uses), so no extra playback wiring is needed.
 */
class MusicWidgetProvider : AppWidgetProvider() {

    companion object {
        const val PREFS = "music_widget_prefs"

        /**
         * Rebuild and push the widget UI for every placed instance, reading
         * the latest values straight from prefs. Safe to call from anywhere
         * (Activity, receiver, service) — all share the same app process.
         */
        fun render(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, MusicWidgetProvider::class.java)
            )
            if (ids == null || ids.isEmpty()) return

            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val title = prefs.getString("music_title", null) ?: "Nothing playing"
            val artist = prefs.getString("music_artist", null) ?: "Innocent"
            val playing = prefs.getBoolean("music_playing", false)

            for (id in ids) {
                val views = RemoteViews(context.packageName, R.layout.music_widget).apply {
                    setTextViewText(R.id.widget_title, title)
                    setTextViewText(R.id.widget_artist, artist)
                    setImageViewResource(
                        R.id.widget_play_pause,
                        if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play
                    )

                    val launch = context.packageManager
                        .getLaunchIntentForPackage(context.packageName)
                    if (launch != null) {
                        setOnClickPendingIntent(
                            R.id.widget_root, activityIntent(context, launch, 100)
                        )
                    }
                    setOnClickPendingIntent(
                        R.id.widget_prev,
                        mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS, 101)
                    )
                    setOnClickPendingIntent(
                        R.id.widget_play_pause,
                        mediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, 102)
                    )
                    setOnClickPendingIntent(
                        R.id.widget_next,
                        mediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT, 103)
                    )
                }
                manager.updateAppWidget(id, views)
            }
        }

        private fun activityIntent(context: Context, intent: Intent, requestCode: Int): PendingIntent {
            return PendingIntent.getActivity(context, requestCode, intent, immutableFlags())
        }

        private fun mediaButton(context: Context, keyCode: Int, requestCode: Int): PendingIntent {
            val intent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                component = ComponentName(
                    context.packageName,
                    "com.ryanheise.audioservice.MediaButtonReceiver"
                )
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            }
            return PendingIntent.getBroadcast(context, requestCode, intent, immutableFlags())
        }

        private fun immutableFlags(): Int {
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return flags
        }
    }

    /** System-triggered updates (widget added / resized / restored). */
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        render(context)
    }
}
