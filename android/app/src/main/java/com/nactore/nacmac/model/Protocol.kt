package com.nactore.nacmac.model

import org.json.JSONObject

enum class NacMacMessageType(val rawValue: String) {
    PAIR_REQUEST("PAIR_REQUEST"),
    PAIR_RESPONSE("PAIR_RESPONSE"),
    HEARTBEAT_PING("HEARTBEAT_PING"),
    HEARTBEAT_PONG("HEARTBEAT_PONG"),
    NOTIFICATION("NOTIFICATION"),
    NOTIFICATION_DISMISSED("NOTIFICATION_DISMISSED"),
    NOTIFICATION_ACTION("NOTIFICATION_ACTION"),
    CLIPBOARD_SYNC("CLIPBOARD_SYNC"),
    SMS_CONVERSATIONS_REQUEST("SMS_CONVERSATIONS_REQUEST"),
    SMS_CONVERSATIONS_RESPONSE("SMS_CONVERSATIONS_RESPONSE"),
    SMS_MESSAGES_REQUEST("SMS_MESSAGES_REQUEST"),
    SMS_MESSAGES_RESPONSE("SMS_MESSAGES_RESPONSE"),
    SMS_SEND("SMS_SEND"),
    SMS_SEND_STATUS("SMS_SEND_STATUS"),
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

data class NotificationActionInfo(
    val index: Int,
    val title: String,
    val isReply: Boolean = false
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("index", index)
        obj.put("title", title)
        obj.put("isReply", isReply)
        return obj
    }

    companion object {
        fun fromJSON(obj: JSONObject): NotificationActionInfo {
            return NotificationActionInfo(
                index = obj.getInt("index"),
                title = obj.getString("title"),
                isReply = obj.optBoolean("isReply", false)
            )
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
    val hasReplyAction: Boolean = false,
    val deviceId: String? = null,
    val deviceName: String? = null,
    val actions: List<NotificationActionInfo> = emptyList()
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
        if (deviceId != null) obj.put("deviceId", deviceId)
        if (deviceName != null) obj.put("deviceName", deviceName)
        if (actions.isNotEmpty()) {
            val arr = org.json.JSONArray()
            actions.forEach { arr.put(it.toJSON()) }
            obj.put("actions", arr)
        }
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): NotificationPayload? {
            return try {
                val obj = JSONObject(jsonString)
                val actionsList = mutableListOf<NotificationActionInfo>()
                if (obj.has("actions")) {
                    val arr = obj.getJSONArray("actions")
                    for (i in 0 until arr.length()) {
                        actionsList.add(NotificationActionInfo.fromJSON(arr.getJSONObject(i)))
                    }
                }
                NotificationPayload(
                    id = obj.getString("id"),
                    packageName = obj.optString("packageName", ""),
                    appName = obj.optString("appName", "Android"),
                    title = obj.optString("title", ""),
                    body = obj.optString("body", ""),
                    iconBase64 = if (obj.has("iconBase64") && !obj.isNull("iconBase64")) obj.getString("iconBase64") else null,
                    timestamp = obj.optLong("timestamp", System.currentTimeMillis() / 1000),
                    hasReplyAction = obj.optBoolean("hasReplyAction", false),
                    deviceId = if (obj.has("deviceId") && !obj.isNull("deviceId")) obj.getString("deviceId") else null,
                    deviceName = if (obj.has("deviceName") && !obj.isNull("deviceName")) obj.getString("deviceName") else null,
                    actions = actionsList
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class NotificationDismissPayload(
    val id: String,
    val deviceId: String? = null
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("id", id)
        if (deviceId != null) obj.put("deviceId", deviceId)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): NotificationDismissPayload? {
            return try {
                val obj = JSONObject(jsonString)
                NotificationDismissPayload(
                    id = obj.getString("id"),
                    deviceId = if (obj.has("deviceId") && !obj.isNull("deviceId")) obj.getString("deviceId") else null
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class NotificationActionPayload(
    val notificationKey: String,
    val actionIndex: Int,
    val replyText: String? = null,
    val deviceId: String? = null
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("notificationKey", notificationKey)
        obj.put("actionIndex", actionIndex)
        if (replyText != null) obj.put("replyText", replyText)
        if (deviceId != null) obj.put("deviceId", deviceId)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): NotificationActionPayload? {
            return try {
                val obj = JSONObject(jsonString)
                NotificationActionPayload(
                    notificationKey = obj.getString("notificationKey"),
                    actionIndex = obj.getInt("actionIndex"),
                    replyText = if (obj.has("replyText") && !obj.isNull("replyText")) obj.getString("replyText") else null,
                    deviceId = if (obj.has("deviceId") && !obj.isNull("deviceId")) obj.getString("deviceId") else null
                )
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

data class TransferRecord(
    val id: String,
    val name: String,
    val sizeBytes: Long,
    val isIncoming: Boolean, // true = Received from Mac, false = Sent to Mac
    val timestamp: Long = System.currentTimeMillis(),
    val isCompleted: Boolean = true
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("id", id)
        obj.put("name", name)
        obj.put("sizeBytes", sizeBytes)
        obj.put("isIncoming", isIncoming)
        obj.put("timestamp", timestamp)
        obj.put("isCompleted", isCompleted)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): TransferRecord? {
            return try {
                val obj = JSONObject(jsonString)
                TransferRecord(
                    id = obj.getString("id"),
                    name = obj.getString("name"),
                    sizeBytes = obj.optLong("sizeBytes", 0),
                    isIncoming = obj.getBoolean("isIncoming"),
                    timestamp = obj.optLong("timestamp", System.currentTimeMillis()),
                    isCompleted = obj.optBoolean("isCompleted", true)
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

// MARK: - Clipboard Sync Payload
data class ClipboardSyncPayload(
    val text: String,
    val timestamp: Long = System.currentTimeMillis(),
    val sourceDeviceId: String,
    val hash: String
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("text", text)
        obj.put("timestamp", timestamp)
        obj.put("sourceDeviceId", sourceDeviceId)
        obj.put("hash", hash)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): ClipboardSyncPayload? {
            return try {
                val obj = JSONObject(jsonString)
                ClipboardSyncPayload(
                    text = obj.getString("text"),
                    timestamp = obj.optLong("timestamp", System.currentTimeMillis()),
                    sourceDeviceId = obj.getString("sourceDeviceId"),
                    hash = obj.getString("hash")
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

// MARK: - SMS / RCS Messaging Payloads
data class SMSThreadItem(
    val threadId: Long,
    val address: String,
    val contactName: String? = null,
    val snippet: String,
    val timestamp: Long,
    val unreadCount: Int = 0
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("threadId", threadId)
        obj.put("address", address)
        if (contactName != null) obj.put("contactName", contactName)
        obj.put("snippet", snippet)
        obj.put("timestamp", timestamp)
        obj.put("unreadCount", unreadCount)
        return obj
    }

    companion object {
        fun fromJSON(obj: JSONObject): SMSThreadItem {
            return SMSThreadItem(
                threadId = obj.getLong("threadId"),
                address = obj.getString("address"),
                contactName = if (obj.has("contactName") && !obj.isNull("contactName")) obj.getString("contactName") else null,
                snippet = obj.optString("snippet", ""),
                timestamp = obj.optLong("timestamp", 0),
                unreadCount = obj.optInt("unreadCount", 0)
            )
        }
    }
}

data class SMSConversationsRequestPayload(
    val limit: Int = 50
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("limit", limit)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): SMSConversationsRequestPayload? {
            return try {
                val obj = JSONObject(jsonString)
                SMSConversationsRequestPayload(limit = obj.optInt("limit", 50))
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class SMSConversationsResponsePayload(
    val threads: List<SMSThreadItem>,
    val deviceId: String? = null
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        val arr = org.json.JSONArray()
        threads.forEach { arr.put(it.toJSON()) }
        obj.put("threads", arr)
        if (deviceId != null) obj.put("deviceId", deviceId)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): SMSConversationsResponsePayload? {
            return try {
                val obj = JSONObject(jsonString)
                val arr = obj.getJSONArray("threads")
                val list = (0 until arr.length()).map { SMSThreadItem.fromJSON(arr.getJSONObject(it)) }
                SMSConversationsResponsePayload(
                    threads = list,
                    deviceId = if (obj.has("deviceId") && !obj.isNull("deviceId")) obj.getString("deviceId") else null
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class SMSMessageItem(
    val messageId: Long,
    val threadId: Long,
    val address: String,
    val body: String,
    val timestamp: Long,
    val isIncoming: Boolean
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("messageId", messageId)
        obj.put("threadId", threadId)
        obj.put("address", address)
        obj.put("body", body)
        obj.put("timestamp", timestamp)
        obj.put("isIncoming", isIncoming)
        return obj
    }

    companion object {
        fun fromJSON(obj: JSONObject): SMSMessageItem {
            return SMSMessageItem(
                messageId = obj.getLong("messageId"),
                threadId = obj.getLong("threadId"),
                address = obj.optString("address", ""),
                body = obj.optString("body", ""),
                timestamp = obj.optLong("timestamp", 0),
                isIncoming = obj.optBoolean("isIncoming", true)
            )
        }
    }
}

data class SMSMessagesRequestPayload(
    val threadId: Long,
    val limit: Int = 100
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("threadId", threadId)
        obj.put("limit", limit)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): SMSMessagesRequestPayload? {
            return try {
                val obj = JSONObject(jsonString)
                SMSMessagesRequestPayload(
                    threadId = obj.getLong("threadId"),
                    limit = obj.optInt("limit", 100)
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class SMSMessagesResponsePayload(
    val threadId: Long,
    val messages: List<SMSMessageItem>,
    val deviceId: String? = null
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("threadId", threadId)
        val arr = org.json.JSONArray()
        messages.forEach { arr.put(it.toJSON()) }
        obj.put("messages", arr)
        if (deviceId != null) obj.put("deviceId", deviceId)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): SMSMessagesResponsePayload? {
            return try {
                val obj = JSONObject(jsonString)
                val threadId = obj.getLong("threadId")
                val arr = obj.getJSONArray("messages")
                val list = (0 until arr.length()).map { SMSMessageItem.fromJSON(arr.getJSONObject(it)) }
                SMSMessagesResponsePayload(
                    threadId = threadId,
                    messages = list,
                    deviceId = if (obj.has("deviceId") && !obj.isNull("deviceId")) obj.getString("deviceId") else null
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class SMSSendPayload(
    val recipient: String,
    val message: String,
    val threadId: Long? = null
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("recipient", recipient)
        obj.put("message", message)
        if (threadId != null) obj.put("threadId", threadId)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): SMSSendPayload? {
            return try {
                val obj = JSONObject(jsonString)
                SMSSendPayload(
                    recipient = obj.getString("recipient"),
                    message = obj.getString("message"),
                    threadId = if (obj.has("threadId") && !obj.isNull("threadId")) obj.getLong("threadId") else null
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

data class SMSSendStatusPayload(
    val success: Boolean,
    val message: String,
    val threadId: Long? = null
) {
    fun toJSON(): JSONObject {
        val obj = JSONObject()
        obj.put("success", success)
        obj.put("message", message)
        if (threadId != null) obj.put("threadId", threadId)
        return obj
    }

    companion object {
        fun fromJSON(jsonString: String): SMSSendStatusPayload? {
            return try {
                val obj = JSONObject(jsonString)
                SMSSendStatusPayload(
                    success = obj.getBoolean("success"),
                    message = obj.optString("message", ""),
                    threadId = if (obj.has("threadId") && !obj.isNull("threadId")) obj.getLong("threadId") else null
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}


