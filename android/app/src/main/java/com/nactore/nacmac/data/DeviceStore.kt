package com.nactore.nacmac.data

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.nactore.nacmac.model.TransferRecord
import org.json.JSONArray
import java.util.UUID

data class PairedMac(
    val macId: String,
    val macName: String,
    val lastKnownIp: String,
    val port: Int,
    val secret: String
)

class DeviceStore(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("nacmac_prefs", Context.MODE_PRIVATE)

    val androidId: String
        get() {
            var id = prefs.getString("android_id", null)
            if (id == null) {
                id = UUID.randomUUID().toString()
                prefs.edit().putString("android_id", id).apply()
            }
            return id
        }

    var deviceName: String
        get() = prefs.getString("custom_device_name", null)
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"
        set(value) {
            prefs.edit().putString("custom_device_name", value).apply()
        }

    fun savePairedMac(mac: PairedMac) {
        prefs.edit()
            .putString("mac_id", mac.macId)
            .putString("mac_name", mac.macName)
            .putString("mac_ip", mac.lastKnownIp)
            .putInt("mac_port", mac.port)
            .putString("mac_secret", mac.secret)
            .apply()
    }

    fun getPairedMac(): PairedMac? {
        val macId = prefs.getString("mac_id", null) ?: return null
        val macName = prefs.getString("mac_name", "Mac") ?: "Mac"
        val ip = prefs.getString("mac_ip", "127.0.0.1") ?: "127.0.0.1"
        val port = prefs.getInt("mac_port", 52840)
        val secret = prefs.getString("mac_secret", null) ?: return null

        return PairedMac(macId, macName, ip, port, secret)
    }

    fun updateLastKnownIp(newIp: String) {
        prefs.edit().putString("mac_ip", newIp).apply()
    }

    fun unpair() {
        prefs.edit()
            .remove("mac_id")
            .remove("mac_name")
            .remove("mac_ip")
            .remove("mac_port")
            .remove("mac_secret")
            .apply()
    }

    val isPaired: Boolean
        get() = prefs.contains("mac_id") && prefs.contains("mac_secret")

    fun getRecentTransfers(): List<TransferRecord> {
        val jsonArrStr = prefs.getString("recent_transfers_json", null) ?: return emptyList()
        return try {
            val arr = JSONArray(jsonArrStr)
            (0 until arr.length()).mapNotNull { TransferRecord.fromJSON(arr.getString(it)) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun addRecentTransfer(record: TransferRecord) {
        val current = getRecentTransfers().toMutableList()
        current.removeAll { it.id == record.id }
        current.add(0, record)
        val trimmed = current.take(15)
        val arr = JSONArray()
        trimmed.forEach { arr.put(it.toJSON().toString()) }
        prefs.edit().putString("recent_transfers_json", arr.toString()).apply()
    }

    fun clearRecentTransfers() {
        prefs.edit().remove("recent_transfers_json").apply()
    }
}
