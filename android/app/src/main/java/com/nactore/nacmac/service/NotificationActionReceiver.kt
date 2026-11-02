package com.nactore.nacmac.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.nactore.nacmac.util.FileUtils

class NotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_OPEN_FOLDER = "com.nactore.nacmac.ACTION_OPEN_FOLDER"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == ACTION_OPEN_FOLDER) {
            FileUtils.openDownloadsFolder(context)
        }
    }
}
