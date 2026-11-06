package org.zaviya.installer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** The running download as the notification shows it. */
data class DownloadProgress(val title: String, val percent: Int)

/**
 * The link between the view model, which does the download, and the service,
 * which keeps the process alive while the app is in the background.
 */
object BackgroundDownload {
    const val RUNNING_ID = 1
    private const val RESULT_ID = 2
    private const val CHANNEL = "download"

    /** Null means nothing is running and the service should stop. */
    val progress = MutableStateFlow<DownloadProgress?>(null)

    /** Set by MainActivity. The result notification is only for someone who left the app. */
    @Volatile var appVisible = false

    private fun manager(ctx: Context) = ctx.getSystemService(NotificationManager::class.java)

    private fun builder(ctx: Context, title: String): Notification.Builder {
        manager(ctx).createNotificationChannel(NotificationChannel(CHANNEL, "Download", NotificationManager.IMPORTANCE_LOW))
        val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?.let { PendingIntent.getActivity(ctx, 0, it, PendingIntent.FLAG_IMMUTABLE) }
        return Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.mark)
            .setContentTitle(title)
            .setContentIntent(open)
    }

    fun running(ctx: Context, p: DownloadProgress): Notification =
        builder(ctx, p.title)
            .setContentText("${p.percent}%")
            .setProgress(100, p.percent, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .build()

    fun notifyRunning(ctx: Context, p: DownloadProgress) = manager(ctx).notify(RUNNING_ID, running(ctx, p))

    /** Without the service the download still runs, but only while the app stays open. */
    fun start(ctx: Context, first: DownloadProgress) {
        clearResult(ctx)
        progress.value = first
        try {
            ctx.startForegroundService(Intent(ctx, DownloadService::class.java))
        } catch (_: IllegalStateException) {
        }
    }

    fun update(p: DownloadProgress) { progress.value = p }

    /** Ends the service. [result] tells someone who left the app how it went. */
    fun stop(ctx: Context, result: String?) {
        progress.value = null
        if (result != null && !appVisible) {
            manager(ctx).notify(RESULT_ID, builder(ctx, result).setAutoCancel(true).build())
        }
    }

    fun clearResult(ctx: Context) = manager(ctx).cancel(RESULT_ID)
}

/**
 * Keeps the process running while an image downloads and shows its progress.
 * It stops when [BackgroundDownload.progress] goes null, never through stopService,
 * which would crash if it arrived before startForeground ran.
 */
class DownloadService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var following: Job? = null
    private var lastStart = 0
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        wake = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "zaviya:download")
            .apply { acquire(LOCK_MS) }
        @Suppress("DEPRECATION")
        wifi = getSystemService(WifiManager::class.java)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "zaviya:download")
            .apply { acquire() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStart = startId
        val now = BackgroundDownload.progress.value ?: DownloadProgress("Getting Zaviya.", 0)
        try {
            startForeground(BackgroundDownload.RUNNING_ID, BackgroundDownload.running(this, now), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } catch (_: IllegalStateException) {
            // Android refused, for example the daily limit on this kind of service.
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (following == null) {
            following = scope.launch {
                BackgroundDownload.progress.collect { p ->
                    // A newer start keeps the service: stopSelf(id) does nothing if id isn't the latest.
                    if (p == null) stopSelf(lastStart) else BackgroundDownload.notifyRunning(this@DownloadService, p)
                }
            }
        }
        return START_NOT_STICKY
    }

    /** Android 15 caps this service type at six hours a day. */
    override fun onTimeout(startId: Int, fgsType: Int) = stopSelf()

    override fun onDestroy() {
        scope.cancel()
        wake?.let { if (it.isHeld) it.release() }
        wifi?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

    private companion object {
        const val LOCK_MS = 3 * 60 * 60 * 1000L
    }
}
