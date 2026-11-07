package com.nactore.nacmac.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.widget.Toast
import androidx.core.app.NotificationCompat
import com.nactore.nacmac.NacMacApp
import com.nactore.nacmac.R
import com.nactore.nacmac.data.DeviceStore
import com.nactore.nacmac.model.ClipboardSyncPayload
import com.nactore.nacmac.model.NacMacEnvelope
import com.nactore.nacmac.model.NacMacMessageType
import com.nactore.nacmac.network.ConnectionManager
import com.nactore.nacmac.ui.ClipboardCopyActivity
import kotlinx.coroutines.*
import java.security.MessageDigest

class NacMacAccessibilityService : AccessibilityService() {
    private val TAG = "NacMac-A11y"
    private var clipboardManager: ClipboardManager? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var fallbackJob: Job? = null

    // Primary system listener: fires IMMEDIATELY when clipboard content changes
    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        syncClipboardImmediate()
    }

    companion object {
        const val NOTIFICATION_ID_CLIPBOARD = 52841
        const val CHANNEL_ID_CLIPBOARD = "nacmac_clipboard"

        @Volatile
        var instance: NacMacAccessibilityService? = null
            private set

        @Volatile
        var lastSyncedHash: String? = null

        fun isRunning(): Boolean = instance != null

        fun recordSyncedHash(text: String) {
            lastSyncedHash = computeSha256(text)
        }

        fun handleIncomingClipboard(context: Context, payloadStr: String) {
            try {
                val payload = ClipboardSyncPayload.fromJSON(payloadStr) ?: return
                if (payload.text.isEmpty()) return

                val hash = computeSha256(payload.text)
                if (hash == lastSyncedHash) {
                    Log.d("NacMac-A11y", "Ignored redundant incoming clipboard with identical hash")
                    return
                }

                Handler(Looper.getMainLooper()).post {
                    val targetContext = NacMacApp.currentActivity ?: instance ?: context.applicationContext

                    try {
                        val cm = targetContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val clip = ClipData.newPlainText("NacMac", payload.text)
                        cm.setPrimaryClip(clip)

                        lastSyncedHash = hash
                        Toast.makeText(targetContext, "Copied from Mac", Toast.LENGTH_SHORT).show()
                        dismissClipboardNotification(targetContext)
                        Log.i("NacMac-A11y", "Synced incoming clipboard directly to phone (${payload.text.length} chars)")
                    } catch (e: Exception) {
                        Log.e("NacMac-A11y", "Direct clipboard write exception: ${e.message}. Fallback to notification.")
                        showClipboardNotification(targetContext, payload.text)
                    }
                }
            } catch (e: Exception) {
                Log.e("NacMac-A11y", "Error handling incoming clipboard: ${e.message}")
            }
        }

        fun showClipboardNotification(context: Context, text: String) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                createClipboardNotificationChannel(nm)

                val copyIntent = Intent(context, ClipboardCopyActivity::class.java).apply {
                    putExtra(ClipboardCopyActivity.EXTRA_CLIPBOARD_TEXT, text)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    NOTIFICATION_ID_CLIPBOARD,
                    copyIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )

                val snippet = if (text.length > 60) text.take(60) + "..." else text

                val notif = NotificationCompat.Builder(context, CHANNEL_ID_CLIPBOARD)
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle("Copied from Mac")
                    .setContentText(snippet)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(text))
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .setAutoCancel(true)
                    .setContentIntent(pendingIntent)
                    .addAction(0, "Copy to Clipboard", pendingIntent)
                    .build()

                nm.notify(NOTIFICATION_ID_CLIPBOARD, notif)
            } catch (e: Exception) {
                Log.e("NacMac-A11y", "Failed to display clipboard notification: ${e.message}")
            }
        }

        fun dismissClipboardNotification(context: Context) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(NOTIFICATION_ID_CLIPBOARD)
            } catch (_: Exception) {}
        }

        private fun createClipboardNotificationChannel(manager: NotificationManager) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID_CLIPBOARD,
                    "NacMac Clipboard Sync",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Instant notifications for text copied from your Mac"
                    setShowBadge(false)
                }
                manager.createNotificationChannel(channel)
            }
        }

        fun computeSha256(input: String): String {
            val md = MessageDigest.getInstance("SHA-256")
            val digest = md.digest(input.toByteArray(Charsets.UTF_8))
            return digest.joinToString("") { "%02x".format(it) }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboardManager = cm
            cm.addPrimaryClipChangedListener(clipListener)
        } catch (e: Exception) {
            Log.e(TAG, "Error registering clip listener: ${e.message}")
        }

        val info = serviceInfo ?: AccessibilityServiceInfo()
        info.eventTypes = AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED or
                AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
        info.flags = AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        info.notificationTimeout = 50
        serviceInfo = info

        Log.i(TAG, "NacMac Accessibility Service connected & clipboard monitoring active")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                // Throttled fallback check: never cancels or delays the primary clipListener
                fallbackJob?.cancel()
                fallbackJob = scope.launch {
                    delay(250)
                    syncClipboardImmediate()
                }
            }
        }
    }

    // Immediate dispatch when clipboard changes on phone
    private fun syncClipboardImmediate() {
        scope.launch {
            try {
                val cm = clipboardManager ?: (getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager) ?: return@launch
                val clip = cm.primaryClip ?: return@launch
                if (clip.itemCount == 0) return@launch
                val text = clip.getItemAt(0).coerceToText(this@NacMacAccessibilityService)?.toString() ?: return@launch
                if (text.isEmpty()) return@launch

                val hash = computeSha256(text)
                synchronized(NacMacAccessibilityService) {
                    if (hash == lastSyncedHash) return@launch // Loop prevention: avoid echoing back
                    lastSyncedHash = hash
                }

                val payload = ClipboardSyncPayload(
                    text = text,
                    timestamp = System.currentTimeMillis(),
                    sourceDeviceId = DeviceStore(applicationContext).androidId,
                    hash = hash
                )
                val envelope = NacMacEnvelope(NacMacMessageType.CLIPBOARD_SYNC, payload.toJSON().toString())
                ConnectionManager.getInstance(applicationContext).sendEnvelope(envelope)
                Log.i(TAG, "Instantly synced local clipboard copy to Mac (${text.length} chars)")
            } catch (e: Exception) {
                Log.e(TAG, "Error checking immediate clipboard: ${e.message}")
            }
        }
    }

    override fun onInterrupt() {
        Log.w(TAG, "Accessibility Service interrupted")
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) instance = null
        try {
            clipboardManager?.removePrimaryClipChangedListener(clipListener)
        } catch (_: Exception) {}
        scope.cancel()
    }
}
