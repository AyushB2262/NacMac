package com.nactore.nacmac.ui

import android.app.Activity
import android.app.NotificationManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.util.Log
import android.widget.Toast
import com.nactore.nacmac.service.NacMacAccessibilityService

class ClipboardCopyActivity : Activity() {
    companion object {
        const val EXTRA_CLIPBOARD_TEXT = "extra_clipboard_text"
        private const val TAG = "ClipboardCopyActivity"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = intent.getStringExtra(EXTRA_CLIPBOARD_TEXT)
        if (!text.isNullOrEmpty()) {
            try {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = ClipData.newPlainText("NacMac", text)
                cm.setPrimaryClip(clip)
                NacMacAccessibilityService.recordSyncedHash(text)
                Toast.makeText(this, "Copied to clipboard", Toast.LENGTH_SHORT).show()
                Log.i(TAG, "Successfully copied to clipboard via foreground activity (${text.length} chars)")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to copy text: ${e.message}")
                Toast.makeText(this, "Failed to copy to clipboard", Toast.LENGTH_SHORT).show()
            }
        }

        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NacMacAccessibilityService.NOTIFICATION_ID_CLIPBOARD)
        } catch (_: Exception) {}

        finish()
    }
}
