package com.royp.maccysync.net

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.royp.maccysync.MaccyApp
import com.royp.maccysync.R

// Keeps the sync connection (and mDNS discovery) alive in the background.
class SyncForegroundService : Service() {
  private var discovery: NsdDiscovery? = null

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    startForegroundCompat()
    val app = MaccyApp.from(this)
    app.controller.start()
    if (discovery == null) {
      discovery = NsdDiscovery(this) { host, port ->
        app.prefs.macHost = host
        app.prefs.macPort = port
      }.also { it.start() }
    }
    return START_STICKY
  }

  override fun onDestroy() {
    discovery?.stop()
    discovery = null
    MaccyApp.from(this).controller.stop()
    super.onDestroy()
  }

  private fun startForegroundCompat() {
    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val channel = NotificationChannel(
        CHANNEL_ID, getString(R.string.fgs_channel), NotificationManager.IMPORTANCE_LOW)
      manager.createNotificationChannel(channel)
    }
    val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle(getString(R.string.fgs_title))
      .setSmallIcon(R.drawable.ic_tile)
      .setOngoing(true)
      .build()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    } else {
      startForeground(NOTIFICATION_ID, notification)
    }
  }

  companion object {
    private const val CHANNEL_ID = "sync"
    private const val NOTIFICATION_ID = 1

    fun start(context: Context) {
      ContextCompat.startForegroundService(context, Intent(context, SyncForegroundService::class.java))
    }

    fun stop(context: Context) {
      context.stopService(Intent(context, SyncForegroundService::class.java))
    }
  }
}
