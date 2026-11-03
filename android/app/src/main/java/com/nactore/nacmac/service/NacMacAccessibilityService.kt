package com.nactore.nacmac.service

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.widget.Toast
import com.nactore.nacmac.data.DeviceStore
import com.nactore.nacmac.model.ClipboardSyncPayload
import com.nactore.nacmac.model.NacMacEnvelope
import com.nactore.nacmac.model.NacMacMessageType
import com.nactore.nacmac.network.ConnectionManager
import kotlinx.coroutines.*
import java.security.MessageDigest

class NacMacAccessibilityService : AccessibilityService() {
    private val TAG = "NacMac-A11y"
    private var clipboardManager: ClipboardManager? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var debounceJob: Job? = null

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        onClipboardChanged()
    }

    companion object {
        @Volatile
        var instance: NacMacAccessibilityService? = null
            private set

        @Volatile
        var lastSyncedHash: String? = null

        fun isRunning(): Boolean = instance != null

        fun handleIncomingClipboard(context: Context, payloadStr: String) {
            try {
                val payload = ClipboardSyncPayload.fromJSON(payloadStr) ?: return
                if (payload.text.isEmpty()) return

                val hash = computeSha256(payload.text)
                if (hash == lastSyncedHash) return

                lastSyncedHash = hash // Loop prevention: avoid echoing back to Mac

                Handler(Looper.getMainLooper()).post {
                    try {
                        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val clip = ClipData.newPlainText("NacMac", payload.text)
                        cm.setPrimaryClip(clip)
                        Toast.makeText(context, "Copied from Mac", Toast.LENGTH_SHORT).show()
                        Log.i("NacMac-A11y", "Synced incoming clipboard from Mac (${payload.text.length} chars)")
                    } catch (e: Exception) {
                        Log.e("NacMac-A11y", "Failed to set clipboard: ${e.message}")
                    }
                }
            } catch (e: Exception) {
                Log.e("NacMac-A11y", "Error handling incoming clipboard: ${e.message}")
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
        info.eventTypes = AccessibilityEvent.TYPE_VIEW_CLICKED or
                AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED or
                AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                AccessibilityEvent.TYPE_NOTIFICATION_STATE_CHANGED
        info.feedbackType = AccessibilityServiceInfo.FEEDBACK_GENERIC
        info.flags = AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        info.notificationTimeout = 100
        serviceInfo = info

        Log.i(TAG, "NacMac Accessibility Service connected & clipboard monitoring active")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                onClipboardChanged()
            }
        }
    }

    private fun onClipboardChanged() {
        debounceJob?.cancel()
        debounceJob = scope.launch {
            delay(300) // 300ms debounce
            try {
                val cm = clipboardManager ?: return@launch
                val clip = cm.primaryClip ?: return@launch
                if (clip.itemCount == 0) return@launch
                val text = clip.getItemAt(0).coerceToText(this@NacMacAccessibilityService)?.toString() ?: return@launch
                if (text.isEmpty()) return@launch

                val hash = computeSha256(text)
                if (hash == lastSyncedHash) return@launch // Loop prevention

                lastSyncedHash = hash
                val payload = ClipboardSyncPayload(
                    text = text,
                    timestamp = System.currentTimeMillis(),
                    sourceDeviceId = DeviceStore(applicationContext).androidId,
                    hash = hash
                )
                val envelope = NacMacEnvelope(NacMacMessageType.CLIPBOARD_SYNC, payload.toJSON().toString())
                ConnectionManager.getInstance(applicationContext).sendEnvelope(envelope)
                Log.i(TAG, "Broadcasted local clipboard copy to Mac (${text.length} chars)")
            } catch (e: Exception) {
                Log.e(TAG, "Error checking clipboard: ${e.message}")
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
