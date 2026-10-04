/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;
import android.view.View;
import android.widget.FrameLayout;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Locale;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.android.FlutterView;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterJNI;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;


public class VideoOutput {
    public long id = 0;
    public long wid = 0;

    private Surface surface;
    // Exactly one of these two is set, for the life of the output.
    private TextureRegistry.SurfaceTextureEntry surfaceTextureEntry;
    private TextureRegistry.SurfaceProducer surfaceProducer;
    // SurfaceProducer only: the next size call must hand libmpv a brand new
    // Surface (a new file was loaded, see [createSurface]).
    private boolean surfaceOwed = true;

    private boolean flutterJNIAPIAvailable;
    private final Method newGlobalObjectRef;
    private final Method deleteGlobalObjectRef;
    private boolean waitUntilFirstFrameRenderedNotify;

    private long handle;
    private MethodChannel channelReference;
    private TextureRegistry textureRegistryReference;

    private final Object lock = new Object();

    VideoOutput(long handle, MethodChannel channelReference, TextureRegistry textureRegistryReference, boolean useSurfaceProducer) {
        this.handle = handle;
        this.channelReference = channelReference;
        this.textureRegistryReference = textureRegistryReference;
        try {
            flutterJNIAPIAvailable = false;
            waitUntilFirstFrameRenderedNotify = false;
            // com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper is part of package:media_kit_libs_android_video & package:media_kit_libs_android_audio packages.
            // Use reflection to invoke methods of com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.
            Class<?> mediaKitAndroidHelperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (Throwable e) {
            Log.i("media_kit", "package:media_kit_libs_android_video missing. Make sure you have added it to pubspec.yaml.");
            throw new RuntimeException("Failed to initialize com.alexmercerind.media_kit_video.VideoOutput.");
        }

        // INNOCENT PATCH — SurfaceProducer instead of SurfaceTexture.
        //
        // With Impeller on Vulkan (Flutter's default on Android since 3.27) a
        // SurfaceTexture cannot be sampled by Vulkan directly: every video
        // frame is first copied by an extra OpenGL ES context into a buffer
        // Vulkan can read, on the raster thread. On a Galaxy S23 Ultra that
        // copy was 7-10 % of a core and most of the player's GPU load
        // (report ZVDDRQQH, 2026-10-04; GPUWatch showed the extra "OpenGL
        // 1x1" context). A SurfaceProducer on Android 10+ is backed by an
        // ImageReader whose HardwareBuffers Vulkan imports as they are: no
        // copy, no second GL context.
        //
        // SurfaceLifecycle.manual: Flutter must NOT tear the surface down
        // when the app goes to the background — background play and the
        // screen-off path keep libmpv attached to it exactly as they did to
        // the SurfaceTexture.
        if (useSurfaceProducer && Build.VERSION.SDK_INT >= 29) {
            surfaceProducer = textureRegistryReference.createSurfaceProducer(
                    TextureRegistry.SurfaceLifecycle.manual);
            id = surfaceProducer.id();
            Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutput: id = %d (SurfaceProducer)", id));
            return;
        }

        surfaceTextureEntry = textureRegistryReference.createSurfaceTexture();

        // If we call setOnFrameAvailableListener after creating SurfaceTextureEntry, the texture won't be displayed inside Flutter UI, because callback set by us will override the Flutter engine's own registered callback:
        // https://github.com/flutter/engine/blob/f47e864f2dcb9c299a3a3ed22300a1dcacbdf1fe/shell/platform/android/io/flutter/view/FlutterView.java#L942-L958
        try {
            if (!flutterJNIAPIAvailable) {
                flutterJNIAPIAvailable = getFlutterJNIReference() != null;
            }
        } catch (Throwable e) {
            e.printStackTrace();
        }
        Log.i("media_kit", String.format(Locale.ENGLISH, "flutterJNIAPIAvailable = %b", flutterJNIAPIAvailable));
        if (flutterJNIAPIAvailable) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                surfaceTextureEntry.surfaceTexture().setOnFrameAvailableListener((texture) -> {
                    synchronized (lock) {
                        try {
                            if (!waitUntilFirstFrameRenderedNotify) {
                                waitUntilFirstFrameRenderedNotify = true;
                                final HashMap<String, Object> data = new HashMap<>();
                                data.put("handle", handle);
                                channelReference.invokeMethod("VideoOutput.WaitUntilFirstFrameRenderedNotify", data);
                                Log.i("media_kit", String.format(Locale.ENGLISH, "VideoOutput.WaitUntilFirstFrameRenderedNotify = %d", handle));
                            }

                            FlutterJNI flutterJNI = null;
                            while (flutterJNI == null) {
                                flutterJNI = getFlutterJNIReference();
                                flutterJNI.markTextureFrameAvailable(id);
                            }
                        } catch (Throwable e) {
                            e.printStackTrace();
                        }
                    }
                }, new Handler());
            } else {
                surfaceTextureEntry.surfaceTexture().setOnFrameAvailableListener((texture) -> {
                    synchronized (lock) {
                        try {
                            if (!waitUntilFirstFrameRenderedNotify) {
                                waitUntilFirstFrameRenderedNotify = true;
                                final HashMap<String, Object> data = new HashMap<>();
                                data.put("handle", handle);
                                channelReference.invokeMethod("VideoOutput.WaitUntilFirstFrameRenderedNotify", data);
                                Log.i("media_kit", String.format(Locale.ENGLISH, "VideoOutput.WaitUntilFirstFrameRenderedNotify = %d", handle));
                            }

                            FlutterJNI flutterJNI = null;
                            while (flutterJNI == null) {
                                flutterJNI = getFlutterJNIReference();
                                flutterJNI.markTextureFrameAvailable(id);
                            }
                        } catch (Throwable e) {
                            e.printStackTrace();
                        }
                    }
                });
            }
        } else {
            if (!waitUntilFirstFrameRenderedNotify) {
                waitUntilFirstFrameRenderedNotify = true;
                final HashMap<String, Object> data = new HashMap<>();
                data.put("id", id);
                data.put("wid", wid);
                data.put("handle", handle);
                channelReference.invokeMethod("VideoOutput.WaitUntilFirstFrameRenderedNotify", data);
            }
        }

        try {
            id = surfaceTextureEntry.id();
            Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutput: id = %d", id));
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    public void dispose() {
        try {
            if (surfaceProducer != null) {
                surfaceProducer.release();
            } else {
                surfaceTextureEntry.release();
            }
        } catch (Throwable e) {
            e.printStackTrace();
        }
        try {
            surface.release();
        } catch (Throwable e) {
            e.printStackTrace();
        }
        try {
            final Handler handler = new Handler(Looper.getMainLooper());
            handler.postDelayed(() -> {
                try {
                    // Invoke DeleteGlobalRef after a voluntary delay to eliminate possibility of libmpv referencing it sometime in the near future.
                    deleteGlobalObjectRef.invoke(null, wid);
                    Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.deleteGlobalObjectRef: %d", wid));
                } catch (Throwable e) {
                    e.printStackTrace();
                }
            }, 5000);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    public long createSurface() {
        synchronized (lock) {
            if (surfaceProducer != null) {
                // An ImageReader's size is fixed, so the real Surface can only
                // be made once the video's size is known: [setSurfaceTextureSize]
                // makes it and returns it. Until then libmpv holds no surface
                // (the controller attaches only after the video parameters
                // arrive), and the previous one is let go here, like below.
                releaseCurrentSurfaceReference();
                surfaceOwed = true;
                return 0;
            }
            // Delete previous android.view.Surface & object reference.
            try {
                if (surface != null) {
                    clearSurface();
                    surface.release();
                    surface = null;
                }
                if (wid != 0) {
                    deleteGlobalObjectRef.invoke(null, wid);
                    wid = 0;
                }
            } catch (Throwable e) {
                e.printStackTrace();
            }
            // Create new android.view.Surface & object reference.
            try {
                surface = new Surface(surfaceTextureEntry.surfaceTexture());
                wid = (long) newGlobalObjectRef.invoke(null, surface);
            } catch (Throwable e) {
                e.printStackTrace();
            }
            return wid;
        }
    }

    /**
     * Sizes the output to the video and returns the Surface reference libmpv
     * must render into. For a SurfaceTexture that is always the one
     * [createSurface] made; for a SurfaceProducer a new size (or a new file)
     * means a new ImageReader and so a new Surface.
     */
    public long setSurfaceTextureSize(int width, int height) {
        synchronized (lock) {
            if (surfaceProducer != null) {
                try {
                    final boolean resized = surfaceProducer.getWidth() != width
                            || surfaceProducer.getHeight() != height;
                    if (resized || surfaceOwed || wid == 0) {
                        surfaceProducer.setSize(width, height);
                        releaseCurrentSurfaceReference();
                        surface = surfaceProducer.getForcedNewSurface();
                        wid = (long) newGlobalObjectRef.invoke(null, surface);
                        surfaceOwed = false;
                        notifyFirstFrameOnce();
                    }
                } catch (Throwable e) {
                    e.printStackTrace();
                }
                return wid;
            }
        }
        try {
            surfaceTextureEntry.surfaceTexture().setDefaultBufferSize(width, height);
        } catch (Throwable e) {
            e.printStackTrace();
        }
        return wid;
    }

    /** True when this output renders through a SurfaceProducer. */
    public boolean usesSurfaceProducer() {
        return surfaceProducer != null;
    }

    /**
     * Drops this side's hold on the Surface handed to libmpv. The JNI global
     * reference is deleted after a delay, as in [dispose]: libmpv may still
     * be letting go of it.
     */
    private void releaseCurrentSurfaceReference() {
        final long old = wid;
        wid = 0;
        surface = null;
        if (old == 0) return;
        try {
            new Handler(Looper.getMainLooper()).postDelayed(() -> {
                try {
                    deleteGlobalObjectRef.invoke(null, old);
                } catch (Throwable e) {
                    e.printStackTrace();
                }
            }, 5000);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    /**
     * SurfaceProducer only. Flutter's ImageReader schedules its own frames,
     * so there is no frame listener to hook; the first frame follows the
     * first surface within a frame or two, which is what the Dart side waits
     * for.
     */
    private void notifyFirstFrameOnce() {
        if (waitUntilFirstFrameRenderedNotify) return;
        waitUntilFirstFrameRenderedNotify = true;
        try {
            final HashMap<String, Object> data = new HashMap<>();
            data.put("handle", handle);
            channelReference.invokeMethod("VideoOutput.WaitUntilFirstFrameRenderedNotify", data);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    private void clearSurface() {
        try {
            final Canvas canvas = surface.lockCanvas(null);
            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR);
            surface.unlockCanvasAndPost(canvas);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

    private FlutterJNI getFlutterJNIReference() {
        try {
            FlutterView view = null;
            // io.flutter.embedding.android.FlutterActivity
            if (view == null) {
                view = MediaKitVideoPlugin.activity.findViewById(FlutterActivity.FLUTTER_VIEW_ID);
            }
            // io.flutter.embedding.android.FlutterFragmentActivity
            if (view == null) {
                final FrameLayout layout = (FrameLayout) MediaKitVideoPlugin.activity.findViewById(FlutterFragmentActivity.FRAGMENT_CONTAINER_ID);
                for (int i = 0; i < layout.getChildCount(); i++) {
                    final View child = layout.getChildAt(i);
                    if (child instanceof FlutterView) {
                        view = (FlutterView) child;
                        break;
                    }
                }
            }
            final FlutterEngine engine = view.getAttachedFlutterEngine();
            final Field field = engine.getClass().getDeclaredField("flutterJNI");
            field.setAccessible(true);
            return (FlutterJNI) field.get(engine);
        } catch (Throwable e) {
            e.printStackTrace();
            return null;
        }
    }
}
