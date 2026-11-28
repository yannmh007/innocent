package com.innocent.media

import android.app.Activity
import android.graphics.PixelFormat
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterSurfaceView
import java.lang.ref.WeakReference

/**
 * The app's window, as the player needs it (P1 in production, 28 Nov 2026:
 * the owner chose the film on Android's own SurfaceView, the dialogs'
 * glass a tint — docs/handoff_2026_11_29_beyond_mx_p2.md §3-§4).
 *
 * WHY. On the texture every video frame makes Flutter draw its whole scene
 * again (Test Lab 46124628533: realme 61 % of a core, OPPO 52 %); a film
 * on a SurfaceView of its own is composed by the display, and Flutter
 * draws only when its controls change (realme 39 %, OPPO ~42 %). For that
 * the film's SurfaceView lies UNDER Flutter's, and Flutter's must be
 * see-through where the player draws nothing.
 *
 * HOW, WITHOUT A BLINK. The lab made the window see-through by recreating
 * the Activity in FlutterActivity's transparent mode (a visible blink, and
 * Flutter's surface then sits above the window). Here Flutter's own
 * SurfaceView is given an alpha format and the media-overlay layer before
 * the window first shows it — once, as the Activity is made — so nothing
 * is ever switched while the app runs:
 *  * the film's SurfaceView: the media layer (a SurfaceView's default),
 *  * Flutter's: the media OVERLAY layer, just above it, see-through,
 *  * the window's own views above both (each SurfaceView clears its part
 *    of the window, as Flutter's opaque one always did).
 * Every screen of the app paints its own opaque background, so nothing
 * else changes: a pixel Flutter leaves empty was black before (an opaque
 * surface drops its alpha) and is black now (nothing lies under it) —
 * unless the player has put the film there.
 *
 * Off ([seeThrough] false) when the surface was already attached (never
 * seen) or a lab asked for the old opaque window ([labOpaque], set by
 * PlayerLab before it recreates the Activity): the film then stays on
 * Flutter's texture, as before.
 */
object PlayerWindow {
    private const val TAG = "PlayerWindow"

    private var activity: WeakReference<Activity>? = null

    /** Flutter's surface is see-through, so a film can lie under it. */
    @Volatile
    var seeThrough = false
        private set

    /** What [seeThrough] was set from, for the trail. */
    @Volatile
    var how = "not yet"
        private set

    /** LAB ONLY (PlayerLab `opaque`): the next Activity keeps 1.64.90's opaque surface. */
    @Volatile
    var labOpaque = false

    fun attach(a: Activity) {
        activity = WeakReference(a)
    }

    fun current(): Activity? = activity?.get()

    /**
     * Before super.onCreate: watches for the FlutterFragment's view, whose
     * FlutterSurfaceView exists then but is not yet in a window.
     */
    fun watch(a: FragmentActivity) {
        attach(a)
        seeThrough = false
        a.supportFragmentManager.registerFragmentLifecycleCallbacks(
            object : FragmentManager.FragmentLifecycleCallbacks() {
                override fun onFragmentViewCreated(
                    fm: FragmentManager, f: Fragment, v: View, savedInstanceState: Bundle?,
                ) {
                    if (f is FlutterFragment) prepare(v)
                }
            },
            false,
        )
    }

    private fun prepare(root: View) {
        if (labOpaque) {
            seeThrough = false
            how = "opaque (lab)"
            return
        }
        val sv = flutterSurface(root)
        if (sv == null) {
            seeThrough = false
            how = "no FlutterSurfaceView"
            return
        }
        if (sv.isAttachedToWindow) {
            // Too late to change its layer without a blink: as before.
            seeThrough = false
            how = "already in the window"
            return
        }
        try {
            sv.holder.setFormat(PixelFormat.TRANSPARENT)
            sv.setZOrderMediaOverlay(true)
            seeThrough = true
            how = "see-through"
        } catch (t: Throwable) {
            seeThrough = false
            how = "refused (${t.javaClass.simpleName})"
            Log.w(TAG, "Flutter's surface stays opaque", t)
        }
    }

    /** Flutter's own SurfaceView under [v] (not a film's). */
    fun flutterSurface(v: View?): FlutterSurfaceView? {
        if (v is FlutterSurfaceView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                flutterSurface(v.getChildAt(i))?.let { return it }
            }
        }
        return null
    }
}
