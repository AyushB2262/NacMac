package com.nactore.nacmac.model

import org.json.JSONObject

enum class NacMacMessageType(val rawValue: String) {
    PAIR_REQUEST("PAIR_REQUEST"),
    PAIR_RESPONSE("PAIR_RESPONSE"),
    HEARTBEAT_PING("HEARTBEAT_PING"),
    HEARTBEAT_PONG("HEARTBEAT_PONG"),
    NOTIFICATION("NOTIFICATION"),
    NOTIFICATION_DISMISSED("NOTIFICATION_DISMISSED"),
    FILE_START("FILE_START"),
    FILE_CHUNK("FILE_CHUNK"),
    FILE_END("FILE_END"),
    FILE_CANCEL("FILE_CANCEL"),
    FILE_ACK("FILE_ACK"),
    ERROR("ERROR");

    companion object {
        fun from(value: String): NacMacMessageType? = entries.find { it.rawValue == value }
    }
}

typealias LMMMessageType = NacMacMessageType

data class NacMacEnvelope(
    val type: NacMacMessageType,
    val payload: String
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("type", type.rawValue)
        obj.put("payload", payload)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): NacMacEnvelope? {
            return try {
                val obj = JSONObject(jsonString)
                val type = NacMacMessageType.from(obj.getString("type")) ?: return null
                val payload = obj.getString("payload")
                NacMacEnvelope(type, payload)
            } catch (e: Exception) {
                null
            }
        }
    }
}

typealias LMMEnvelope = NacMacEnvelope

data class PairingQRPayload(
    val macId: String,
    val macName: String,
    val ips: List<String>,
    val port: Int,
    val secret: String,
    val v: Int = 1,
    val timestamp: Long = System.currentTimeMillis() / 1000
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("v", v)
        obj.put("macId", macId)
        obj.put("macName", macName)
        val arr = org.json.JSONArray()
        ips.forEach { arr.put(it) }
        obj.put("ips", arr)
        obj.put("port", port)
        obj.put("secret", secret)
        obj.put("timestamp", timestamp)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): PairingQRPayload? {
            return try {
                val obj = JSONObject(jsonString)
                val ipsArray = obj.getJSONArray("ips")
                val ips = (0 until ipsArray.length()).map { ipsArray.getString(it) }
                PairingQRPayload(
                    macId = obj.getString("macId"),
                    macName = obj.getString("macName"),
                    ips = ips,
                    port = obj.getInt("port"),
                    secret = obj.getString("secret"),
                    v = obj.optInt("v", 1),
                    timestamp = obj.optLong("timestamp", System.currentTimeMillis() / 1000)
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class PairRequestPayload(
    val androidId: String,
    val deviceName: String,
    val authSecret: String
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("androidId", androidId)
        obj.put("deviceName", deviceName)
        obj.put("authSecret", authSecret)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): PairRequestPayload? {
            return try {
                val obj = JSONObject(jsonString)
                PairRequestPayload(
                    androidId = obj.getString("androidId"),
                    deviceName = obj.getString("deviceName"),
                    authSecret = obj.getString("authSecret")
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class PairResponsePayload(
    val success: Boolean,
    val macName: String,
    val message: String
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("success", success)
        obj.put("macName", macName)
        obj.put("message", message)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): PairResponsePayload? {
            return try {
                val obj = JSONObject(jsonString)
                PairResponsePayload(
                    success = obj.getBoolean("success"),
                    macName = obj.optString("macName", ""),
                    message = obj.optString("message", "")
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class NotificationPayload(
    val id: String,
    val packageName: String,
    val appName: String,
    val title: String,
    val body: String,
    val iconBase64: String? = null,
    val timestamp: Long = System.currentTimeMillis() / 1000,
    val hasReplyAction: Boolean = false
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("id", id)
        obj.put("packageName", packageName)
        obj.put("appName", appName)
        obj.put("title", title)
        obj.put("body", body)
        if (iconBase64 != null) obj.put("iconBase64", iconBase64)
        obj.put("timestamp", timestamp)
        obj.put("hasReplyAction", hasReplyAction)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): NotificationPayload? {
            return try {
                val obj = JSONObject(jsonString)
                NotificationPayload(
                    id = obj.getString("id"),
                    packageName = obj.getString("packageName"),
                    appName = obj.getString("appName"),
                    title = obj.getString("title"),
                    body = obj.getString("body"),
                    iconBase64 = if (obj.has("iconBase64") && !obj.isNull("iconBase64")) obj.getString("iconBase64") else null,
                    timestamp = obj.optLong("timestamp", System.currentTimeMillis() / 1000),
                    hasReplyAction = obj.optBoolean("hasReplyAction", false)
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class NotificationDismissPayload(
    val id: String
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("id", id)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): NotificationDismissPayload? {
            return try {
                val obj = JSONObject(jsonString)
                NotificationDismissPayload(id = obj.getString("id"))
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class FileStartPayload(
    val transferId: String,
    val filename: String,
    val size: Long,
    val sha256: String? = null
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("transferId", transferId)
        obj.put("filename", filename)
        obj.put("size", size)
        if (sha256 != null) obj.put("sha256", sha256)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): FileStartPayload? {
            return try {
                val obj = JSONObject(jsonString)
                FileStartPayload(
                    transferId = obj.getString("transferId"),
                    filename = obj.getString("filename"),
                    size = obj.getLong("size"),
                    sha256 = if (obj.has("sha256") && !obj.isNull("sha256")) obj.getString("sha256") else null
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class FileChunkPayload(
    val transferId: String,
    val offset: Long,
    val length: Int,
    val dataBase64: String
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("transferId", transferId)
        obj.put("offset", offset)
        obj.put("length", length)
        obj.put("dataBase64", dataBase64)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): FileChunkPayload? {
            return try {
                val obj = JSONObject(jsonString)
                FileChunkPayload(
                    transferId = obj.getString("transferId"),
                    offset = obj.getLong("offset"),
                    length = obj.getInt("length"),
                    dataBase64 = obj.getString("dataBase64")
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class FileEndPayload(
    val transferId: String,
    val totalBytes: Long
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("transferId", transferId)
        obj.put("totalBytes", totalBytes)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): FileEndPayload? {
            return try {
                val obj = JSONObject(jsonString)
                FileEndPayload(
                    transferId = obj.getString("transferId"),
                    totalBytes = obj.getLong("totalBytes")
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class FileCancelPayload(
    val transferId: String,
    val reason: String = "User cancelled"
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("transferId", transferId)
        obj.put("reason", reason)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): FileCancelPayload? {
            return try {
                val obj = JSONObject(jsonString)
                FileCancelPayload(
                    transferId = obj.getString("transferId"),
                    reason = obj.optString("reason", "User cancelled")
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class FileAckPayload(
    val transferId: String,
    val success: Boolean,
    val message: String
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("transferId", transferId)
        obj.put("success", success)
        obj.put("message", message)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): FileAckPayload? {
            return try {
                val obj = JSONObject(jsonString)
                FileAckPayload(
                    transferId = obj.getString("transferId"),
                    success = obj.getBoolean("success"),
                    message = obj.optString("message", "")
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}
