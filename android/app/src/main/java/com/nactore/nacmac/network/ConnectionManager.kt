package com.nactore.nacmac.network

import android.content.Context
import android.util.Log
import com.nactore.nacmac.data.DeviceStore
import com.nactore.nacmac.data.PairedMac
import com.nactore.nacmac.model.NacMacEnvelope
import com.nactore.nacmac.model.NacMacMessageType
import com.nactore.nacmac.transfer.FileTransferWorker
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer

sealed class ConnectionStatus {
    object Disconnected : ConnectionStatus()
    data class Connecting(val target: String) : ConnectionStatus()
    data class Connected(val macName: String, val ip: String) : ConnectionStatus()
}

class ConnectionManager private constructor(private val context: Context) {
    private val TAG = "NacMac-Connection"
    private val deviceStore = DeviceStore(context)
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private var socket: Socket? = null
    private var inStream: DataInputStream? = null
    private var outStream: DataOutputStream? = null

    private val _status = MutableStateFlow<ConnectionStatus>(ConnectionStatus.Disconnected)
    val status: StateFlow<ConnectionStatus> = _status

    private var reconnectJob: Job? = null
    private var readJob: Job? = null
    private var heartbeatJob: Job? = null

    var fileTransferWorker: FileTransferWorker? = null

    companion object {
        @Volatile
        private var instance: ConnectionManager? = null

        fun getInstance(context: Context): ConnectionManager {
            return instance ?: synchronized(this) {
                instance ?: ConnectionManager(context.applicationContext).also { instance = it }
            }
        }
    }

    fun startAutoConnect() {
        if (!deviceStore.isPaired) {
            _status.value = ConnectionStatus.Disconnected
            return
        }

        if (reconnectJob?.isActive == true) return

        reconnectJob = scope.launch {
            var delayMs = 1000L
            while (isActive) {
                val paired = deviceStore.getPairedMac() ?: break
                if (_status.value is ConnectionStatus.Connected) {
                    delay(5000)
                    continue
                }

                _status.value = ConnectionStatus.Connecting("${paired.lastKnownIp}:${paired.port}")
                Log.d(TAG, "Attempting auto-connect to Mac at ${paired.lastKnownIp}:${paired.port}...")

                val connected = connectToMac(paired.lastKnownIp, paired.port, paired.secret)
                if (connected) {
                    delayMs = 1000L
                    _status.value = ConnectionStatus.Connected(paired.macName, paired.lastKnownIp)
                    startHeartbeat()
                    startReading()
                } else {
                    _status.value = ConnectionStatus.Disconnected
                    Log.d(TAG, "Connect failed. Retrying in ${delayMs / 1000}s...")
                    delay(delayMs)
                    delayMs = (delayMs * 2).coerceAtMost(15000L)
                }
            }
        }
    }

    private suspend fun connectToMac(ip: String, port: Int, secret: String): Boolean = withContext(Dispatchers.IO) {
        try {
            val s = Socket()
            s.tcpNoDelay = true
            s.keepAlive = true
            s.connect(InetSocketAddress(ip, port), 4000)

            val out = DataOutputStream(s.getOutputStream())
            val inS = DataInputStream(s.getInputStream())

            // Send PAIR_REQUEST to authenticate
            val pairReq = JSONObject().apply {
                put("androidId", deviceStore.androidId)
                put("deviceName", deviceStore.deviceName)
                put("authSecret", secret)
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
                    socket = s
                    outStream = out
                    inStream = inS
                    return@withContext true
                }
            }
            s.close()
            false
        } catch (e: Exception) {
            Log.e(TAG, "Socket connect exception: ${e.message}")
            false
        }
    }

    private fun startReading() {
        readJob?.cancel()
        readJob = scope.launch(Dispatchers.IO) {
            val inS = inStream ?: return@launch
            try {
                while (isActive) {
                    val length = inS.readInt()
                    if (length <= 0 || length > 100 * 1024 * 1024) break
                    val payloadBytes = ByteArray(length)
                    inS.readFully(payloadBytes)

                    val jsonStr = String(payloadBytes, Charsets.UTF_8)
                    val envelope = NacMacEnvelope.fromJSON(jsonStr) ?: continue
                    handleInboundEnvelope(envelope)
                }
            } catch (e: Exception) {
                Log.d(TAG, "Connection lost in read loop: ${e.message}")
            } finally {
                disconnectInternal()
            }
        }
    }

    private fun handleInboundEnvelope(envelope: NacMacEnvelope) {
        when (envelope.type) {
            NacMacMessageType.HEARTBEAT_PING -> {
                sendEnvelope(NacMacEnvelope(NacMacMessageType.HEARTBEAT_PONG, "{}"))
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
            else -> {
                Log.d(TAG, "Received message: ${envelope.type}")
            }
        }
    }

    private fun startHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch(Dispatchers.IO) {
            while (isActive) {
                delay(10000)
                sendEnvelope(NacMacEnvelope(NacMacMessageType.HEARTBEAT_PING, "{}"))
            }
        }
    }

    fun sendEnvelope(envelope: NacMacEnvelope) {
        scope.launch(Dispatchers.IO) {
            val out = outStream ?: return@launch
            try {
                sendRawEnvelope(envelope, out)
            } catch (e: Exception) {
                Log.e(TAG, "Send failed: ${e.message}")
                disconnectInternal()
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

    fun disconnect() {
        scope.launch {
            reconnectJob?.cancel()
            disconnectInternal()
        }
    }

    private fun disconnectInternal() {
        try {
            readJob?.cancel()
            heartbeatJob?.cancel()
            socket?.close()
        } catch (_: Exception) {}
        socket = null
        inStream = null
        outStream = null
        _status.value = ConnectionStatus.Disconnected
    }
}
