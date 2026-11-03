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
) {
    fun toJSON(): org.json.JSONObject {
        val obj = org.json.JSONObject()
        obj.put("macId", macId)
        obj.put("macName", macName)
        obj.put("lastKnownIp", lastKnownIp)
        obj.put("port", port)
        obj.put("secret", secret)
        return obj
    }

    companion object {
        fun fromJSON(obj: org.json.JSONObject): PairedMac {
            return PairedMac(
                macId = obj.getString("macId"),
                macName = obj.optString("macName", "Mac"),
                lastKnownIp = obj.optString("lastKnownIp", "127.0.0.1"),
                port = obj.optInt("port", 52840),
                secret = obj.getString("secret")
            )
        }
    }
}

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

    fun getPairedMacs(): List<PairedMac> {
        val jsonStr = prefs.getString("paired_macs_json", null)
        if (jsonStr != null) {
            return try {
                val arr = JSONArray(jsonStr)
                (0 until arr.length()).map { PairedMac.fromJSON(arr.getJSONObject(it)) }
            } catch (e: Exception) {
                emptyList()
            }
        }
        
        // Migrate legacy single Mac
        val legacy = getLegacyPairedMac()
        if (legacy != null) {
            val list = listOf(legacy)
            savePairedMacsList(list)
            return list
        }
        return emptyList()
    }

    fun getPairedMac(): PairedMac? {
        return getPairedMacs().firstOrNull()
    }

    fun getPairedMac(macId: String): PairedMac? {
        return getPairedMacs().find { it.macId == macId }
    }

    fun savePairedMac(mac: PairedMac) {
        val current = getPairedMacs().toMutableList()
        current.removeAll { it.macId == mac.macId }
        current.add(mac)
        savePairedMacsList(current)
        
        // Save to legacy fields for backward compatibility
        prefs.edit()
            .putString("mac_id", mac.macId)
            .putString("mac_name", mac.macName)
            .putString("mac_ip", mac.lastKnownIp)
            .putInt("mac_port", mac.port)
            .putString("mac_secret", mac.secret)
            .apply()
    }

    private fun savePairedMacsList(macs: List<PairedMac>) {
        val arr = JSONArray()
        macs.forEach { arr.put(it.toJSON()) }
        prefs.edit().putString("paired_macs_json", arr.toString()).apply()
    }

    fun updateLastKnownIp(newIp: String) {
        val first = getPairedMac() ?: return
        updateLastKnownIp(first.macId, newIp)
    }

    fun updateLastKnownIp(macId: String, newIp: String) {
        val list = getPairedMacs().map {
            if (it.macId == macId) it.copy(lastKnownIp = newIp) else it
        }
        savePairedMacsList(list)
        if (list.firstOrNull()?.macId == macId) {
            prefs.edit().putString("mac_ip", newIp).apply()
        }
    }

    fun removePairedMac(macId: String) {
        val list = getPairedMacs().filterNot { it.macId == macId }
        savePairedMacsList(list)
        if (list.isEmpty()) {
            clearLegacyMac()
        }
    }

    fun unpair(macId: String? = null) {
        if (macId != null) {
            removePairedMac(macId)
        } else {
            prefs.edit().remove("paired_macs_json").apply()
            clearLegacyMac()
        }
    }

    private fun clearLegacyMac() {
        prefs.edit()
            .remove("mac_id")
            .remove("mac_name")
            .remove("mac_ip")
            .remove("mac_port")
            .remove("mac_secret")
            .apply()
    }

    private fun getLegacyPairedMac(): PairedMac? {
        val macId = prefs.getString("mac_id", null) ?: return null
        val macName = prefs.getString("mac_name", "Mac") ?: "Mac"
        val ip = prefs.getString("mac_ip", "127.0.0.1") ?: "127.0.0.1"
        val port = prefs.getInt("mac_port", 52840)
        val secret = prefs.getString("mac_secret", null) ?: return null
        return PairedMac(macId, macName, ip, port, secret)
    }

    val isPaired: Boolean
        get() = getPairedMacs().isNotEmpty()

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
