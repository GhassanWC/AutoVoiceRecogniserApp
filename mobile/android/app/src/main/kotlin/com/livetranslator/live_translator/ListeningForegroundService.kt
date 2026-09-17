package com.livetranslator.live_translator

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Keeps the process alive (and the microphone legally usable) while the user
 * has Live Translation running in the background. Android requires — and our
 * privacy rules demand — a persistent, visible notification the whole time,
 * with a Stop action so listening can always be ended in one tap.
 */
class ListeningForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "live_translation_listening"
        private const val NOTIFICATION_ID = 4242
        const val ACTION_STOP = "com.livetranslator.live_translator.action.STOP_LISTENING"

        fun start(context: Context) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, ListeningForegroundService::class.java),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ListeningForegroundService::class.java))
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // User pressed Stop on the notification: end capture immediately
            // and let Dart know so the UI switches to "Not Listening".
            AudioCaptureManager.stopWithReason("notification")
            stopSelf()
            return START_NOT_STICKY
        }

        createChannel()

        val stopIntent = Intent(this, ListeningForegroundService::class.java)
            .setAction(ACTION_STOP)
        val stopPending = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val openPending = PendingIntent.getActivity(
            this, 2, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Sayvo is listening")
            .setContentText("Translating nearby speech. Audio is not saved.")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(openPending)
            .addAction(0, "Stop", stopPending)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // Never auto-restart: listening must only ever begin via user action.
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Live Translation",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shown while Live Translation is listening"
                    setShowBadge(false)
                },
            )
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
