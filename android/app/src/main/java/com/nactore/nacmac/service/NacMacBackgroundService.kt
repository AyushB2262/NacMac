package com.nactore.nacmac.service

import android.app.*
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.nactore.nacmac.network.ConnectionManager
import com.nactore.nacmac.network.ConnectionStatus
import com.nactore.nacmac.transfer.FileTransferWorker
import com.nactore.nacmac.ui.MainActivity
import kotlinx.coroutines.*

class NacMacBackgroundService : Service() {
    private val CHANNEL_ID = "nacmac_connection_channel_v2"
    private val NOTIF_ID = 1001
    private val scope = CoroutineScope(Dispatchers.Main + Job())
    private lateinit var connectionManager: ConnectionManager
    private lateinit var connectivityManager: ConnectivityManager

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            super.onAvailable(network)
            // Wi-Fi restored or connected -> instant auto reconnect
            connectionManager.startAutoConnect()
        }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification("NacMac", "Searching for paired Mac..."))

        connectionManager = ConnectionManager.getInstance(this)
        connectionManager.fileTransferWorker = FileTransferWorker(this, connectionManager)

        connectivityManager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivityManager.registerNetworkCallback(request, networkCallback)

        // Observe connection status to update persistent notification
        scope.launch {
            connectionManager.status.collect { status ->
                val (title, text) = when (status) {
                    is ConnectionStatus.Connected -> Pair("NacMac Connected", "Currently connected to ${status.macName}")
                    is ConnectionStatus.Connecting -> Pair("NacMac", "Connecting to ${status.target}...")
                    is ConnectionStatus.Disconnected -> Pair("NacMac", "Waiting for local Wi-Fi...")
                }
                updateNotification(title, text)
            }
        }

        connectionManager.startAutoConnect()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "NacMac Connection Service",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Keeps NacMac connected to your Mac for notifications and file sharing"
                setShowBadge(true)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, statusText: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(statusText)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
    }

    private fun updateNotification(title: String, text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIF_ID, buildNotification(title, text))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        connectionManager.startAutoConnect()
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        connectivityManager.unregisterNetworkCallback(networkCallback)
        scope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
