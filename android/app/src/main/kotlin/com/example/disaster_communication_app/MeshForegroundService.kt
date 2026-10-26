package com.example.disaster_communication_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps the app process (and with it the GATT server, advertiser and the
 * Dart relay logic) running while the Affected Person screen is in the
 * background or the display is off. Type connectedDevice: it serves BLE
 * connections to the Rescue Team laptop and relay phones. It does no work
 * itself -- MeshGattServer owns the BLE objects.
 */
class MeshForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "disaster_mesh"
        private const val NOTIFICATION_ID = 7701
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Never crash the app over the keep-alive; BLE still runs while
            // the screen is open.
            Log.w("MeshForegroundService", "startForeground failed: $e")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Disaster mesh", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while the SOS relay and Rescue Team link are active"
                },
            )
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("Disaster mesh active")
            .setContentText("SOS relay and Rescue Team link stay on")
            .setOngoing(true)
            .apply { if (open != null) setContentIntent(open) }
            .build()
    }
}
