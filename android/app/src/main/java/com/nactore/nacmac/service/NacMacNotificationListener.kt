package com.nactore.nacmac.service

import android.app.Notification
import android.content.ComponentName
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
import com.nactore.nacmac.model.NacMacEnvelope
import com.nactore.nacmac.model.NacMacMessageType
import com.nactore.nacmac.model.NotificationPayload
import com.nactore.nacmac.network.ConnectionManager
import org.json.JSONObject
import java.io.ByteArrayOutputStream

class NacMacNotificationListener : NotificationListenerService() {
    private val TAG = "NacMac-NotifListener"

    override fun onListenerConnected() {
        super.onListenerConnected()
        Log.i(TAG, "Notification listener connected to Android system")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
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

        // Check if notification has an inline reply action
        var hasReply = false
        sbn.notification.actions?.forEach { action ->
            if (action.remoteInputs?.isNotEmpty() == true) {
                hasReply = true
            }
        }

        val payload = NotificationPayload(
            id = "${pkg}_${sbn.id}_${sbn.tag ?: "0"}",
            packageName = pkg,
            appName = appName,
            title = title,
            body = body,
            iconBase64 = iconBase64,
            timestamp = sbn.postTime / 1000,
            hasReplyAction = hasReply
        )

        val envelope = NacMacEnvelope(NacMacMessageType.NOTIFICATION, payload.toJSON().toString())
        ConnectionManager.getInstance(applicationContext).sendEnvelope(envelope)
        Log.i(TAG, "Forwarded notification: [$appName] $title: $body")
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        super.onNotificationRemoved(sbn)
        if (sbn.packageName == packageName) return

        val dismissId = "${sbn.packageName}_${sbn.id}_${sbn.tag ?: "0"}"
        val obj = JSONObject().apply { put("id", dismissId) }
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
