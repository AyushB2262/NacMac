package com.nactore.nacmac.service

import android.app.Notification
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
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

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        super.onNotificationPosted(sbn)

        val pkg = sbn.packageName
        // Ignore self notifications and persistent ongoing services
        if (pkg == packageName || sbn.isOngoing) return

        val extras = sbn.notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString() ?: ""

        if (title.isEmpty() && text.isEmpty()) return

        val pm = applicationContext.packageManager
        val appName = try {
            val appInfo = pm.getApplicationInfo(pkg, 0)
            pm.getApplicationLabel(appInfo).toString()
        } catch (e: Exception) {
            pkg
        }

        // Extract app icon
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
            body = text,
            iconBase64 = iconBase64,
            timestamp = sbn.postTime / 1000,
            hasReplyAction = hasReply
        )

        val envelope = NacMacEnvelope(NacMacMessageType.NOTIFICATION, payload.toJSON().toString())
        ConnectionManager.getInstance(applicationContext).sendEnvelope(envelope)
        Log.d(TAG, "Forwarded notification: [$appName] $title: $text")
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
            return drawable.bitmap
        }
        val bitmap = Bitmap.createBitmap(
            drawable.intrinsicWidth.coerceAtLeast(64).coerceAtMost(128),
            drawable.intrinsicHeight.coerceAtLeast(64).coerceAtMost(128),
            Bitmap.Config.ARGB_8888
        )
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
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
