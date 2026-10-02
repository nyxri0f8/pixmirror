package com.pixmirror.pixmirror

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps PixMirror alive in the background so paired PCs can still find this
 * phone and ask to mirror it. Without it Android freezes the app shortly
 * after it leaves the screen, and discovery goes silent.
 */
class PresenceService : Service() {

    companion object {
        private const val CHANNEL_READY = "pixmirror_ready"
        private const val CHANNEL_REQUESTS = "pixmirror_requests"
        private const val NOTIFICATION_ID = 8
        private const val REQUEST_ID = 9

        private fun channels(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_READY, "Ready to connect", NotificationManager.IMPORTANCE_MIN)
            )
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_REQUESTS, "Connection requests", NotificationManager.IMPORTANCE_HIGH)
            )
        }

        private fun builder(context: Context, channel: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel)
            else @Suppress("DEPRECATION") Notification.Builder(context)

        private fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        /** Heads-up "nyx wants to mirror this phone" when the app is not in view. */
        fun notifyRequest(context: Context, name: String) {
            channels(context)
            val n = builder(context, CHANNEL_REQUESTS)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("$name wants to mirror this phone")
                .setContentText("Tap to start sharing")
                .setContentIntent(openApp(context))
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_CALL)
                .build()
            (context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(REQUEST_ID, n)
        }

        fun clearRequest(context: Context) {
            (context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager).cancel(REQUEST_ID)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        channels(this)
        val notification = builder(this, CHANNEL_READY)
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentTitle("PixMirror is ready")
            .setContentText("Your PC can find this phone")
            .setContentIntent(openApp(this))
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Background-start restrictions: we will retry next time the app opens.
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away: the Flutter engine is gone, so stop advertising.
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }
}
