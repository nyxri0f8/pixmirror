package com.pixmirror.pixmirror

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val REQUEST_CAPTURE = 4201
        private const val REQUEST_NOTIFICATIONS = 4202
    }

    private var multicastLock: WifiManager.MulticastLock? = null
    private var pendingCapture: MethodChannel.Result? = null
    private var pendingSettings = Triple(1080, 70, 30)
    private var frameSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "pixmirror/frames").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                frameSink = events
            }
            override fun onCancel(arguments: Any?) {
                frameSink = null
            }
        })

        CaptureService.listener = object : CaptureService.Listener {
            override fun onFrame(jpeg: ByteArray, width: Int, height: Int) {
                frameSink?.success(mapOf("jpeg" to jpeg, "w" to width, "h" to height))
            }
            override fun onStopped() {
                frameSink?.success(mapOf("stopped" to true))
            }
        }

        MethodChannel(messenger, "pixmirror/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceName" -> result.success(deviceName())
                "acquireMulticast" -> {
                    if (multicastLock == null) {
                        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wifi.createMulticastLock("pixmirror").apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                    }
                    result.success(true)
                }
                "requestNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
                    }
                    result.success(true)
                }
                "startCapture" -> {
                    if (CaptureService.isRunning) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    pendingSettings = Triple(
                        call.argument<Int>("maxWidth") ?: 1080,
                        call.argument<Int>("quality") ?: 70,
                        call.argument<Int>("fps") ?: 30
                    )
                    pendingCapture?.success(false)
                    pendingCapture = result
                    val mpm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                    @Suppress("DEPRECATION")
                    startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_CAPTURE)
                }
                "stopCapture" -> {
                    stopService(Intent(this, CaptureService::class.java))
                    result.success(true)
                }
                "isCapturing" -> result.success(CaptureService.isRunning)
                "requestFrame" -> {
                    CaptureService.instance?.requestFrame(call.argument<Boolean>("force") ?: false)
                    result.success(null)
                }
                "captureSettings" -> {
                    CaptureService.instance?.updateSettings(
                        call.argument<Int>("maxWidth") ?: 1080,
                        call.argument<Int>("quality") ?: 70,
                        call.argument<Int>("fps") ?: 30
                    )
                    result.success(null)
                }
                "screenInfo" -> result.success(ScreenInfo.describe(this))
                "vaultSeal", "vaultOpen" -> {
                    try {
                        val data = call.argument<ByteArray>("data") ?: ByteArray(0)
                        result.success(if (call.method == "vaultSeal") Vault.seal(data) else Vault.open(data))
                    } catch (e: Exception) {
                        result.error("vault", e.message, null)
                    }
                }
                "openAppInfo" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(android.net.Uri.parse("package:$packageName"))
                    )
                    result.success(null)
                }
                "openBatterySettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    } catch (e: Exception) {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(android.net.Uri.parse("package:$packageName"))
                        )
                    }
                    result.success(null)
                }
                "startPresence" -> {
                    try {
                        val i = Intent(this, PresenceService::class.java)
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                    } catch (e: Exception) {}
                    result.success(null)
                }
                "notifyRequest" -> {
                    PresenceService.notifyRequest(this, call.argument<String>("name") ?: "Your PC")
                    result.success(null)
                }
                "clearRequest" -> {
                    PresenceService.clearRequest(this)
                    result.success(null)
                }
                "touchDown" -> result.success(
                    InputService.instance?.touchDown(call.argument<Double>("x") ?: 0.0, call.argument<Double>("y") ?: 0.0) ?: false
                )
                "touchMove" -> {
                    InputService.instance?.touchMove(call.argument<Double>("x") ?: 0.0, call.argument<Double>("y") ?: 0.0)
                    result.success(null)
                }
                "touchUp" -> {
                    InputService.instance?.touchUp(call.argument<Double>("x") ?: 0.0, call.argument<Double>("y") ?: 0.0)
                    result.success(null)
                }
                "inputEnabled" -> result.success(InputService.isEnabled)
                "openInputSettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(null)
                }
                "gesture" -> {
                    val points = call.argument<List<Double>>("points") ?: emptyList()
                    val duration = (call.argument<Number>("duration") ?: 50).toLong()
                    result.success(InputService.instance?.gesture(points, duration) ?: false)
                }
                "globalAction" -> result.success(
                    InputService.instance?.globalAction(call.argument<String>("action") ?: "") ?: false
                )
                "typeText" -> result.success(
                    InputService.instance?.typeText(call.argument<String>("text") ?: "") ?: false
                )
                "key" -> result.success(
                    InputService.instance?.key(call.argument<String>("key") ?: "") ?: false
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun deviceName(): String {
        val name = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
        if (!name.isNullOrBlank()) return name
        val model = Build.MODEL ?: "Android"
        val maker = Build.MANUFACTURER ?: ""
        return if (model.startsWith(maker, ignoreCase = true)) model
        else "${maker.replaceFirstChar { it.uppercase() }} $model"
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CAPTURE) return
        val pending = pendingCapture ?: return
        pendingCapture = null
        if (resultCode != RESULT_OK || data == null) {
            pending.success(false)
            return
        }
        CaptureService.onReady = { ok -> pending.success(ok) }
        val (maxWidth, quality, fps) = pendingSettings
        val intent = Intent(this, CaptureService::class.java)
            .putExtra(CaptureService.EXTRA_RESULT_CODE, resultCode)
            .putExtra(CaptureService.EXTRA_DATA, data)
            .putExtra(CaptureService.EXTRA_MAX_WIDTH, maxWidth)
            .putExtra(CaptureService.EXTRA_QUALITY, quality)
            .putExtra(CaptureService.EXTRA_FPS, fps)
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
    }

    override fun onDestroy() {
        // The Dart side that serves frames dies with the activity.
        if (isFinishing) {
            stopService(Intent(this, CaptureService::class.java))
            stopService(Intent(this, PresenceService::class.java))
        }
        multicastLock?.release()
        multicastLock = null
        super.onDestroy()
    }
}
