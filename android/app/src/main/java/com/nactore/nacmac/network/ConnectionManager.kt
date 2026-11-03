package com.nactore.nacmac.network

import android.content.Context
import android.util.Log
import com.nactore.nacmac.data.DeviceStore
import com.nactore.nacmac.data.PairedMac
import com.nactore.nacmac.model.*
import com.nactore.nacmac.service.NacMacAccessibilityService
import com.nactore.nacmac.service.NacMacNotificationListener
import com.nactore.nacmac.sms.SmsManagerHelper
import com.nactore.nacmac.transfer.FileTransferWorker
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

sealed class ConnectionStatus {
    object Disconnected : ConnectionStatus()
    data class Connecting(val target: String) : ConnectionStatus()
    data class Connected(val macName: String, val ip: String) : ConnectionStatus()
}

data class MacConnection(
    val macId: String,
    val macName: String,
    val ip: String,
    val port: Int,
    val socket: Socket,
    val inStream: DataInputStream,
    val outStream: DataOutputStream,
    var readJob: Job? = null,
    var heartbeatJob: Job? = null
)

class ConnectionManager private constructor(private val context: Context) {
    private val TAG = "NacMac-Connection"
    private val deviceStore = DeviceStore(context)
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    val activeConnections = ConcurrentHashMap<String, MacConnection>()

    private val _status = MutableStateFlow<ConnectionStatus>(ConnectionStatus.Disconnected)
    val status: StateFlow<ConnectionStatus> = _status

    private val _connectedMacs = MutableStateFlow<List<PairedMac>>(emptyList())
    val connectedMacs: StateFlow<List<PairedMac>> = _connectedMacs

    private var reconnectJob: Job? = null

    private val discoveryClient = DiscoveryClient(context) { ip, port ->
        scope.launch(Dispatchers.IO) {
            val pairedMacs = deviceStore.getPairedMacs()
            for (paired in pairedMacs) {
                if (!activeConnections.containsKey(paired.macId)) {
                    val updated = paired.copy(lastKnownIp = ip, port = port)
                    deviceStore.savePairedMac(updated)
                    connectToMac(updated)
                }
            }
        }
    }

    var fileTransferWorker: FileTransferWorker? = null
        get() {
            if (field == null) {
                field = FileTransferWorker(context, this)
            }
            return field
        }

    companion object {
        @Volatile
        private var instance: ConnectionManager? = null

        fun getInstance(context: Context): ConnectionManager {
            return instance ?: synchronized(this) {
                instance ?: ConnectionManager(context.applicationContext).also { instance = it }
            }
        }
    }

    private fun updateStatus() {
        val conns = activeConnections.values.toList()
        _connectedMacs.value = conns.map { PairedMac(it.macId, it.macName, it.ip, it.port, "") }
        _status.value = when {
            conns.isEmpty() -> ConnectionStatus.Disconnected
            conns.size == 1 -> ConnectionStatus.Connected(conns[0].macName, conns[0].ip)
            else -> ConnectionStatus.Connected("${conns.size} Macs Online", conns.first().ip)
        }
    }

    fun startAutoConnect() {
        val pairedMacs = deviceStore.getPairedMacs()
        if (pairedMacs.isEmpty()) {
            _status.value = ConnectionStatus.Disconnected
            return
        }

        discoveryClient.startDiscovery()

        if (reconnectJob?.isActive == true) return

        reconnectJob = scope.launch {
            var delayMs = 1500L
            while (isActive) {
                val currentPaired = deviceStore.getPairedMacs()
                if (currentPaired.isEmpty()) {
                    updateStatus()
                    delay(5000)
                    continue
                }

                for (paired in currentPaired) {
                    if (!activeConnections.containsKey(paired.macId)) {
                        _status.value = ConnectionStatus.Connecting("${paired.lastKnownIp}:${paired.port}")
                        Log.d(TAG, "Attempting auto-connect to ${paired.macName} at ${paired.lastKnownIp}:${paired.port}...")
                        val ok = connectToMac(paired)
                        if (ok) {
                            delayMs = 1500L
                        }
                    }
                }

                updateStatus()
                delay(delayMs)
                delayMs = (delayMs * 2).coerceAtMost(10000L)
            }
        }
    }

    private suspend fun connectToMac(paired: PairedMac): Boolean = withContext(Dispatchers.IO) {
        if (activeConnections.containsKey(paired.macId)) return@withContext true
        try {
            val s = Socket()
            s.tcpNoDelay = true
            s.keepAlive = true
            s.connect(InetSocketAddress(paired.lastKnownIp, paired.port), 3500)

            val out = DataOutputStream(s.getOutputStream())
            val inS = DataInputStream(s.getInputStream())

            // Send PAIR_REQUEST to authenticate
            val pairReq = JSONObject().apply {
                put("androidId", deviceStore.androidId)
                put("deviceName", deviceStore.deviceName)
                put("authSecret", paired.secret)
            }
            val envelope = NacMacEnvelope(NacMacMessageType.PAIR_REQUEST, pairReq.toString())
            sendRawEnvelope(envelope, out)

            // Read response
            val len = inS.readInt()
            val buf = ByteArray(len)
            inS.readFully(buf)
            val respEnvelope = NacMacEnvelope.fromJSON(String(buf, Charsets.UTF_8))

            if (respEnvelope?.type == NacMacMessageType.PAIR_RESPONSE) {
                val respObj = JSONObject(respEnvelope.payload)
                if (respObj.optBoolean("success", false)) {
                    val conn = MacConnection(
                        macId = paired.macId,
                        macName = paired.macName,
                        ip = paired.lastKnownIp,
                        port = paired.port,
                        socket = s,
                        inStream = inS,
                        outStream = out
                    )
                    activeConnections[paired.macId] = conn
                    startReading(conn)
                    startHeartbeat(conn)
                    updateStatus()
                    Log.i(TAG, "Successfully connected to Mac: ${paired.macName} (${paired.lastKnownIp}:${paired.port})")
                    return@withContext true
                }
            }
            s.close()
            false
        } catch (e: Exception) {
            Log.d(TAG, "Socket connect exception for ${paired.macName}: ${e.message}")
            false
        }
    }

    private fun startReading(conn: MacConnection) {
        conn.readJob?.cancel()
        conn.readJob = scope.launch(Dispatchers.IO) {
            val inS = conn.inStream
            try {
                while (isActive) {
                    val length = inS.readInt()
                    if (length <= 0 || length > 100 * 1024 * 1024) break
                    val payloadBytes = ByteArray(length)
                    inS.readFully(payloadBytes)

                    val jsonStr = String(payloadBytes, Charsets.UTF_8)
                    val envelope = NacMacEnvelope.fromJSON(jsonStr) ?: continue
                    handleInboundEnvelope(envelope, conn)
                }
            } catch (e: Exception) {
                Log.d(TAG, "Connection lost in read loop for ${conn.macName}: ${e.message}")
            } finally {
                disconnectMacInternal(conn.macId)
            }
        }
    }

    private fun handleInboundEnvelope(envelope: NacMacEnvelope, conn: MacConnection) {
        when (envelope.type) {
            NacMacMessageType.HEARTBEAT_PING -> {
                sendEnvelope(NacMacEnvelope(NacMacMessageType.HEARTBEAT_PONG, "{}"), conn.macId)
            }
            NacMacMessageType.HEARTBEAT_PONG -> {
                // Heartbeat healthy
            }
            NacMacMessageType.FILE_START,
            NacMacMessageType.FILE_CHUNK,
            NacMacMessageType.FILE_END,
            NacMacMessageType.FILE_CANCEL -> {
                fileTransferWorker?.handleIncomingFileEnvelope(envelope)
            }
            NacMacMessageType.CLIPBOARD_SYNC -> {
                NacMacAccessibilityService.handleIncomingClipboard(context, envelope.payload)
            }
            NacMacMessageType.NOTIFICATION_ACTION -> {
                val actionPayload = NotificationActionPayload.fromJSON(envelope.payload)
                if (actionPayload != null) {
                    NacMacNotificationListener.handleNotificationAction(context, actionPayload)
                }
            }
            NacMacMessageType.NOTIFICATION_DISMISSED -> {
                val dismissPayload = NotificationDismissPayload.fromJSON(envelope.payload)
                if (dismissPayload != null) {
                    NacMacNotificationListener.handleNotificationDismissed(context, dismissPayload.id)
                }
            }
            NacMacMessageType.SMS_CONVERSATIONS_REQUEST -> {
                scope.launch(Dispatchers.IO) {
                    val req = SMSConversationsRequestPayload.fromJSON(envelope.payload)
                    val limit = req?.limit ?: 50
                    val threads = SmsManagerHelper.getConversations(context, limit)
                    val resp = SMSConversationsResponsePayload(threads = threads)
                    val respEnvelope = NacMacEnvelope(NacMacMessageType.SMS_CONVERSATIONS_RESPONSE, resp.toJSON().toString())
                    sendEnvelope(respEnvelope, conn.macId)
                    Log.d(TAG, "Responded to SMS_CONVERSATIONS_REQUEST with ${threads.size} threads to ${conn.macName}")
                }
            }
            NacMacMessageType.SMS_MESSAGES_REQUEST -> {
                scope.launch(Dispatchers.IO) {
                    val req = SMSMessagesRequestPayload.fromJSON(envelope.payload)
                    if (req != null) {
                        val messages = SmsManagerHelper.getMessages(context, req.threadId, req.limit)
                        val resp = SMSMessagesResponsePayload(threadId = req.threadId, messages = messages)
                        val respEnvelope = NacMacEnvelope(NacMacMessageType.SMS_MESSAGES_RESPONSE, resp.toJSON().toString())
                        sendEnvelope(respEnvelope, conn.macId)
                        Log.d(TAG, "Responded to SMS_MESSAGES_REQUEST for thread ${req.threadId} with ${messages.size} messages to ${conn.macName}")
                    }
                }
            }
            NacMacMessageType.SMS_SEND -> {
                scope.launch(Dispatchers.IO) {
                    val req = SMSSendPayload.fromJSON(envelope.payload)
                    if (req != null) {
                        val ok = SmsManagerHelper.sendSms(context, req.recipient, req.message)
                        val resp = SMSSendStatusPayload(
                            success = ok,
                            message = if (ok) "Sent" else "SMS delivery failed",
                            threadId = req.threadId
                        )
                        val respEnvelope = NacMacEnvelope(NacMacMessageType.SMS_SEND_STATUS, resp.toJSON().toString())
                        sendEnvelope(respEnvelope, conn.macId)
                        Log.i(TAG, "Handled SMS_SEND to ${req.recipient} (success: $ok)")
                    }
                }
            }
            else -> {
                Log.d(TAG, "Received message: ${envelope.type} from ${conn.macName}")
            }
        }
    }

    private fun startHeartbeat(conn: MacConnection) {
        conn.heartbeatJob?.cancel()
        conn.heartbeatJob = scope.launch(Dispatchers.IO) {
            while (isActive) {
                delay(10000)
                try {
                    sendRawEnvelope(NacMacEnvelope(NacMacMessageType.HEARTBEAT_PING, "{}"), conn.outStream)
                } catch (e: Exception) {
                    Log.d(TAG, "Heartbeat failed for ${conn.macName}: ${e.message}")
                    disconnectMacInternal(conn.macId)
                    break
                }
            }
        }
    }

    fun sendEnvelope(envelope: NacMacEnvelope, targetMacId: String? = null) {
        scope.launch(Dispatchers.IO) {
            if (targetMacId != null) {
                val conn = activeConnections[targetMacId]
                if (conn != null) {
                    try {
                        sendRawEnvelope(envelope, conn.outStream)
                    } catch (e: Exception) {
                        Log.e(TAG, "Send failed to Mac $targetMacId: ${e.message}")
                        disconnectMacInternal(targetMacId)
                    }
                } else {
                    Log.w(TAG, "Target Mac $targetMacId not currently connected")
                }
            } else {
                for ((macId, conn) in activeConnections) {
                    try {
                        sendRawEnvelope(envelope, conn.outStream)
                    } catch (e: Exception) {
                        Log.e(TAG, "Broadcast failed to Mac $macId: ${e.message}")
                        disconnectMacInternal(macId)
                    }
                }
            }
        }
    }

    private fun sendRawEnvelope(envelope: NacMacEnvelope, out: DataOutputStream) {
        val jsonStr = envelope.toJSON().toString()
        val bytes = jsonStr.toByteArray(Charsets.UTF_8)
        synchronized(out) {
            out.writeInt(bytes.size)
            out.write(bytes)
            out.flush()
        }
    }

    fun disconnectMac(macId: String) {
        scope.launch {
            disconnectMacInternal(macId)
        }
    }

    private fun disconnectMacInternal(macId: String) {
        val conn = activeConnections.remove(macId) ?: return
        try {
            conn.readJob?.cancel()
            conn.heartbeatJob?.cancel()
            conn.socket.close()
        } catch (_: Exception) {}
        updateStatus()
        Log.i(TAG, "Disconnected from Mac: ${conn.macName} ($macId)")
    }

    fun disconnect() {
        scope.launch {
            reconnectJob?.cancel()
            discoveryClient.stopDiscovery()
            val ids = activeConnections.keys.toList()
            for (macId in ids) {
                disconnectMacInternal(macId)
            }
        }
    }
}
