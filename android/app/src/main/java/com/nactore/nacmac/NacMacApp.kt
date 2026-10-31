package com.nactore.nacmac

import android.app.Application
import android.content.Context
import androidx.appcompat.app.AppCompatDelegate

class NacMacApp : Application() {
    override fun onCreate() {
        super.onCreate()
        val prefs = getSharedPreferences("nacmac_prefs", Context.MODE_PRIVATE)
        val mode = prefs.getInt("theme_mode", AppCompatDelegate.MODE_NIGHT_FOLLOW_SYSTEM)
        AppCompatDelegate.setDefaultNightMode(mode)
    }
}
