package com.nactore.nacmac.service

import android.app.Notification
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import com.nactore.nacmac.data.DeviceStore
import com.nactore.nacmac.model.NacMacEnvelope
import com.nactore.nacmac.model.NacMacMessageType
import com.nactore.nacmac.model.NotificationActionInfo
import com.nactore.nacmac.model.NotificationActionPayload
import com.nactore.nacmac.model.NotificationPayload
import com.nactore.nacmac.network.ConnectionManager
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

class NacMacNotificationListener : NotificationListenerService() {
    private val TAG = "NacMac-NotifListener"

    companion object {
        private val activeNotificationCache = ConcurrentHashMap<String, StatusBarNotification>()
        @Volatile
        var instance: NacMacNotificationListener? = null
            private set

        fun isRunning(): Boolean = instance != null

        fun handleNotificationAction(context: Context, payload: NotificationActionPayload) {
            val sbn = activeNotificationCache[payload.notificationKey] ?: run {
                instance?.let { inst ->
                    try {
                        inst.activeNotifications?.find {
                            "${it.packageName}_${it.id}_${it.tag ?: "0"}" == payload.notificationKey
                        }
                    } catch (_: Exception) {
                        null
                    }
                }
            }

            if (sbn == null) {
                Log.w("NacMac-NotifListener", "No active notification found for key: ${payload.notificationKey}")
                return
            }

            val actions = sbn.notification.actions
            if (actions.isNullOrEmpty() || payload.actionIndex < 0 || payload.actionIndex >= actions.size) {
                Log.w("NacMac-NotifListener", "Invalid actionIndex ${payload.actionIndex} (actions count: ${actions?.size ?: 0})")
                return
            }

            val action = actions[payload.actionIndex]
            try {
                if (!payload.replyText.isNullOrEmpty() && !action.remoteInputs.isNullOrEmpty()) {
                    val intent = Intent()
                    val bundle = Bundle()
                    for (remoteInput in action.remoteInputs) {
                        bundle.putCharSequence(remoteInput.resultKey, payload.replyText)
                    }
                    RemoteInput.addResultsToIntent(action.remoteInputs, intent, bundle)
                    action.actionIntent.send(context, 0, intent)
                    Log.i("NacMac-NotifListener", "Dispatched RemoteInput inline reply: \"${payload.replyText}\" for ${sbn.packageName}")
                } else {
                    action.actionIntent.send()
                    Log.i("NacMac-NotifListener", "Dispatched action button click: \"${action.title}\" for ${sbn.packageName}")
                }
            } catch (e: Exception) {
                Log.e("NacMac-NotifListener", "Failed to dispatch notification action: ${e.message}")
            }
        }

        fun handleNotificationDismissed(context: Context, notifId: String) {
            val sbn = activeNotificationCache.remove(notifId) ?: run {
                instance?.let { inst ->
                    try {
                        inst.activeNotifications?.find {
                            "${it.packageName}_${it.id}_${it.tag ?: "0"}" == notifId
                        }
                    } catch (_: Exception) {
                        null
                    }
                }
            }
            if (sbn != null && instance != null) {
                try {
                    instance?.cancelNotification(sbn.key)
                    Log.i("NacMac-NotifListener", "Cancelled notification ${sbn.key} on Android")
                } catch (e: Exception) {
                    Log.e("NacMac-NotifListener", "Failed to cancel notification: ${e.message}")
                }
            }
        }
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.i(TAG, "Notification listener connected to Android system")
        try {
            val active = activeNotifications
            active?.forEach { sbn ->
                val id = "${sbn.packageName}_${sbn.id}_${sbn.tag ?: "0"}"
                activeNotificationCache[id] = sbn
            }
        } catch (_: Exception) {}
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        if (instance == this) instance = null
        Log.w(TAG, "Notification listener disconnected from Android system")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                requestRebind(ComponentName(this, NacMacNotificationListener::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to request rebind: ${e.message}")
            }
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)

        val pkg = sbn.packageName
        // Ignore NacMac self notifications and persistent ongoing services
        if (pkg == packageName || sbn.isOngoing) return

        val extras = sbn.notification.extras

        // Robust Title Extraction
        var title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim()
        if (title.isNullOrEmpty()) {
            title = extras?.getCharSequence(Notification.EXTRA_TITLE_BIG)?.toString()?.trim()
        }
        if (title.isNullOrEmpty()) {
            title = extras?.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()?.trim()
        }

        // Robust Body / Text Extraction (covers standard, BigText, Inbox, and MessagingStyle)
        var text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim()
        if (text.isNullOrEmpty()) {
            text = extras?.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim()
        }
        if (text.isNullOrEmpty()) {
            val lines = extras?.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            if (!lines.isNullOrEmpty()) {
                text = lines.filterNotNull().joinToString("\n").trim()
            }
        }
        if (text.isNullOrEmpty()) {
            // Android MessagingStyle messages (WhatsApp, Signal, Telegram, Google Messages)
            val messages = extras?.get("android.messages")
            if (messages is Array<*> && messages.isNotEmpty()) {
                val lastMsg = messages.lastOrNull()
                if (lastMsg is Bundle) {
                    text = lastMsg.getCharSequence("text")?.toString()?.trim()
                    if (title.isNullOrEmpty()) {
                        title = lastMsg.getCharSequence("sender")?.toString()?.trim()
                    }
                }
            }
        }
        if (text.isNullOrEmpty()) {
            text = extras?.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()?.trim()
        }
        if (text.isNullOrEmpty()) {
            text = extras?.getCharSequence(Notification.EXTRA_SUMMARY_TEXT)?.toString()?.trim()
        }
        if (text.isNullOrEmpty()) {
            text = sbn.notification.tickerText?.toString()?.trim()
        }

        val pm = applicationContext.packageManager
        val appName = try {
            val appInfo = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            pkg
        }

        if (title.isNullOrEmpty()) {
            title = appName
        }

        val body = text ?: ""

        // Discard if both title equals appName and body is completely empty with no ticker
        if (title == appName && body.isEmpty() && sbn.notification.tickerText == null) {
            return
        }

        // Extract app icon as compact 96x96 PNG base64
        val iconBase64 = try {
            val drawable = pm.getApplicationIcon(pkg)
            bitmapToBase64(drawableToBitmap(drawable))
        } catch (e: Exception) {
            null
        }

        // Extract action buttons and remote input replies
        val actionsList = mutableListOf<NotificationActionInfo>()
        sbn.notification.actions?.forEachIndexed { idx, action ->
            val isReply = action.remoteInputs?.isNotEmpty() == true
            val actTitle = action.title?.toString()?.trim() ?: if (isReply) "Reply" else "Action $idx"
            actionsList.add(NotificationActionInfo(index = idx, title = actTitle, isReply = isReply))
        }

        val notifId = "${pkg}_${sbn.id}_${sbn.tag ?: "0"}"
        activeNotificationCache[notifId] = sbn

        val deviceStore = DeviceStore(applicationContext)
        val payload = NotificationPayload(
            id = notifId,
            packageName = pkg,
            appName = appName,
            title = title,
            body = body,
            iconBase64 = iconBase64,
            timestamp = sbn.postTime / 1000,
            hasReplyAction = actionsList.any { it.isReply },
            deviceId = deviceStore.androidId,
            deviceName = deviceStore.deviceName,
            actions = actionsList
        )

        val envelope = NacMacEnvelope(NacMacMessageType.NOTIFICATION, payload.toJSON().toString())
        ConnectionManager.getInstance(applicationContext).sendEnvelope(envelope)
        Log.i(TAG, "Forwarded notification: [$appName] $title: $body (actions: ${actionsList.size})")
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        super.onNotificationRemoved(sbn)
        if (sbn.packageName == packageName) return

        val dismissId = "${sbn.packageName}_${sbn.id}_${sbn.tag ?: "0"}"
        activeNotificationCache.remove(dismissId)

        val deviceStore = DeviceStore(applicationContext)
        val obj = JSONObject().apply {
            put("id", dismissId)
            put("deviceId", deviceStore.androidId)
        }
        val envelope = NacMacEnvelope(NacMacMessageType.NOTIFICATION_DISMISSED, obj.toString())
        ConnectionManager.getInstance(applicationContext).sendEnvelope(envelope)
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            val src = drawable.bitmap
            if (src.width <= 96 && src.height <= 96) return src
            return Bitmap.createScaledBitmap(src, 96, 96, true)
        }
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        return bitmap
    }

    private fun bitmapToBase64(bitmap: Bitmap): String {
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 85, stream)
        val byteArray = stream.toByteArray()
        return Base64.encodeToString(byteArray, Base64.NO_WRAP)
    }
}
