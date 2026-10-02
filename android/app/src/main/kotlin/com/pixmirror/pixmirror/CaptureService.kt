package com.pixmirror.pixmirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.DisplayMetrics
import android.view.WindowManager
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * Foreground service that owns the MediaProjection session.
 *
 * Frames are produced on demand: Dart calls [requestFrame] once it has sent
 * the previous one, and the service answers with the newest screen content
 * (only if it changed). This keeps latency low because frames never queue.
 */
class CaptureService : Service() {

    interface Listener {
        fun onFrame(jpeg: ByteArray, width: Int, height: Int)
        fun onStopped()
    }

    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_DATA = "data"
        const val EXTRA_MAX_WIDTH = "maxWidth"
        const val EXTRA_QUALITY = "quality"
        const val EXTRA_FPS = "fps"
        const val ACTION_STOP = "com.pixmirror.STOP_CAPTURE"
        private const val CHANNEL_ID = "pixmirror_sharing"
        private const val NOTIFICATION_ID = 7

        @Volatile var instance: CaptureService? = null
        @Volatile var listener: Listener? = null
        @Volatile var onReady: ((Boolean) -> Unit)? = null

        val isRunning: Boolean get() = instance != null
    }

    private lateinit var thread: HandlerThread
    private lateinit var handler: Handler
    private val mainHandler = Handler(Looper.getMainLooper())

    private var projection: MediaProjection? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null

    private var maxWidth = 1080
    private var quality = 70
    private var minFrameMs = 33L

    private var width = 0
    private var height = 0
    private var bitmap: Bitmap? = null
    private var dirty = false
    private var requested = false
    private var lastEmit = 0L
    private var emitScheduled = false

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {}
        override fun onDisplayRemoved(displayId: Int) {}
        override fun onDisplayChanged(displayId: Int) {
            handler.post { resizeIfRotated() }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        thread = HandlerThread("pixmirror-capture").also { it.start() }
        handler = Handler(thread.looper)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startInForeground()

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, 0) ?: 0
        @Suppress("DEPRECATION")
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            intent?.getParcelableExtra(EXTRA_DATA)
        }
        maxWidth = intent?.getIntExtra(EXTRA_MAX_WIDTH, 1080) ?: 1080
        quality = intent?.getIntExtra(EXTRA_QUALITY, 70) ?: 70
        val fps = (intent?.getIntExtra(EXTRA_FPS, 30) ?: 30).coerceIn(5, 60)
        minFrameMs = 1000L / fps

        val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val mp = if (data != null) manager.getMediaProjection(resultCode, data) else null
        if (mp == null) {
            finishReady(false)
            stopSelf()
            return START_NOT_STICKY
        }
        projection = mp
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                stopSelf()
            }
        }, handler)

        instance = this
        handler.post {
            createDisplay()
            finishReady(true)
        }
        (getSystemService(DISPLAY_SERVICE) as DisplayManager)
            .registerDisplayListener(displayListener, handler)
        return START_NOT_STICKY
    }

    private fun finishReady(ok: Boolean) {
        val cb = onReady
        onReady = null
        mainHandler.post { cb?.invoke(ok) }
    }

    private fun startInForeground() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Screen sharing", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, CaptureService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle("PixMirror is sharing your screen")
            .setContentText("Tap to open. Stop anytime.")
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop sharing", stopIntent).build())
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    // A Service is not a visual context, so ask DisplayManager rather than
    // WindowManager for the physical size in the current rotation.
    private fun realMetrics(): DisplayMetrics = ScreenInfo.realMetrics(this)

    private fun targetSize(): Pair<Int, Int> {
        val m = realMetrics()
        var w = m.widthPixels
        var h = m.heightPixels
        // Limit the longer side so portrait phones are not blurry.
        val longSide = maxOf(w, h)
        val limit = maxWidth.coerceAtLeast(320)
        if (longSide > limit) {
            val scale = limit.toFloat() / longSide
            w = (w * scale).toInt()
            h = (h * scale).toInt()
        }
        return Pair(w and 1.inv(), h and 1.inv())
    }

    private fun createDisplay() {
        val mp = projection ?: return
        val (w, h) = targetSize()
        width = w
        height = h
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        r.setOnImageAvailableListener({ onImage(it) }, handler)
        reader = r
        display = mp.createVirtualDisplay(
            "pixmirror", w, h, realMetrics().densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            r.surface, null, handler
        )
    }

    private fun resizeIfRotated() {
        val vd = display ?: return
        val (w, h) = targetSize()
        if (w == width && h == height) return
        width = w
        height = h
        val old = reader
        val r = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 2)
        r.setOnImageAvailableListener({ onImage(it) }, handler)
        reader = r
        // A MediaProjection may only create one VirtualDisplay on Android 14+,
        // so resize the existing one and swap its surface.
        vd.resize(w, h, realMetrics().densityDpi)
        vd.surface = r.surface
        old?.close()
        bitmap = null
    }

    private var staging: ByteBuffer? = null

    private fun onImage(r: ImageReader) {
        val image = try { r.acquireLatestImage() } catch (e: Exception) { null } ?: return
        try {
            val plane = image.planes[0]
            val rowPixels = plane.rowStride / plane.pixelStride
            val w = image.width
            val h = image.height
            var bmp = bitmap
            if (bmp == null || bmp.width != rowPixels || bmp.height != h) {
                bmp = Bitmap.createBitmap(rowPixels, h, Bitmap.Config.ARGB_8888)
                bitmap = bmp
            }
            // Many devices pad each row and omit the padding after the last
            // row, so the plane is shorter than rowStride * height. Copy into
            // a full-size buffer first or copyPixelsFromBuffer throws.
            val needed = bmp!!.byteCount
            var buf = staging
            if (buf == null || buf.capacity() != needed) {
                buf = ByteBuffer.allocateDirect(needed)
                staging = buf
            }
            val src = plane.buffer
            src.rewind()
            buf!!.clear()
            if (src.remaining() > buf.remaining()) src.limit(src.position() + buf.remaining())
            buf.put(src)
            buf.rewind()
            bmp.copyPixelsFromBuffer(buf)
            width = w
            height = h
            dirty = true
        } catch (e: Exception) {
            android.util.Log.w("PixMirror", "frame copy failed", e)
        } finally {
            image.close()
        }
        tryEmit()
    }

    fun requestFrame(force: Boolean) {
        handler.post {
            requested = true
            if (force) dirty = bitmap != null
            tryEmit()
        }
    }

    private fun tryEmit() {
        if (!requested || !dirty) return
        val bmp = bitmap ?: return
        val wait = minFrameMs - (SystemClock.uptimeMillis() - lastEmit)
        if (wait > 0) {
            if (!emitScheduled) {
                emitScheduled = true
                handler.postDelayed({ emitScheduled = false; tryEmit() }, wait)
            }
            return
        }
        requested = false
        dirty = false
        lastEmit = SystemClock.uptimeMillis()

        val bytes = try {
            val frame = if (bmp.width != width) Bitmap.createBitmap(bmp, 0, 0, width, height) else bmp
            val out = ByteArrayOutputStream(64 * 1024)
            frame.compress(Bitmap.CompressFormat.JPEG, quality, out)
            if (frame !== bmp) frame.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            android.util.Log.w("PixMirror", "encode failed", e)
            requested = true
            return
        }
        val w = width
        val h = height
        mainHandler.post { listener?.onFrame(bytes, w, h) }
    }

    fun updateSettings(newMaxWidth: Int, newQuality: Int, fps: Int) {
        handler.post {
            quality = newQuality.coerceIn(20, 95)
            minFrameMs = 1000L / fps.coerceIn(5, 60)
            if (newMaxWidth != maxWidth) {
                maxWidth = newMaxWidth
                resizeIfRotated()
            }
            dirty = bitmap != null
        }
    }

    override fun onDestroy() {
        (getSystemService(DISPLAY_SERVICE) as DisplayManager).unregisterDisplayListener(displayListener)
        instance = null
        handler.post {
            display?.release()
            display = null
            reader?.close()
            reader = null
            projection?.stop()
            projection = null
            thread.quitSafely()
        }
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        mainHandler.post { listener?.onStopped() }
        super.onDestroy()
    }
}
