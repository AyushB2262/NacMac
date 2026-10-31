package com.nactore.nacmac.transfer

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import com.nactore.nacmac.model.*
import com.nactore.nacmac.network.ConnectionManager
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class FileTransferWorker(
    private val context: Context,
    private val connectionManager: ConnectionManager
) {
    private val TAG = "NacMac-FileTransfer"
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val activeTransfers = mutableMapOf<String, FileOutputStream>()
    private val transferFiles = mutableMapOf<String, Pair<File, File>>() // transferId -> (partFile, finalFile)

    init {
        createChannel()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                "nacmac_transfers",
                "File Transfers",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    fun handleIncomingFileEnvelope(envelope: NacMacEnvelope) {
        when (envelope.type) {
            NacMacMessageType.FILE_START -> {
                val start = FileStartPayload.fromJSON(envelope.payload) ?: return
                startReceiving(start)
            }
            NacMacMessageType.FILE_CHUNK -> {
                val chunk = FileChunkPayload.fromJSON(envelope.payload) ?: return
                writeChunk(chunk)
            }
            NacMacMessageType.FILE_END -> {
                val obj = JSONObject(envelope.payload)
                val id = obj.getString("transferId")
                finishReceiving(id)
            }
            NacMacMessageType.FILE_CANCEL -> {
                val obj = JSONObject(envelope.payload)
                val id = obj.getString("transferId")
                cancelReceiving(id)
            }
            else -> {}
        }
    }

    private fun startReceiving(start: FileStartPayload) {
        val downloadDir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            "NacMac"
        )
        downloadDir.mkdirs()

        val finalFile = File(downloadDir, start.filename)
        val partFile = File(downloadDir, "${start.filename}.part")

        if (partFile.exists()) partFile.delete()

        try {
            val fos = FileOutputStream(partFile)
            activeTransfers[start.transferId] = fos
            transferFiles[start.transferId] = Pair(partFile, finalFile)
            Log.d(TAG, "Started receiving file: ${start.filename} (${start.size} bytes)")
        } catch (e: Exception) {
            Log.e(TAG, "Error starting file receive: ${e.message}")
        }
    }

    private fun writeChunk(chunk: FileChunkPayload) {
        val fos = activeTransfers[chunk.transferId] ?: return
        try {
            val data = Base64.decode(chunk.dataBase64, Base64.NO_WRAP)
            fos.write(data)
        } catch (e: Exception) {
            Log.e(TAG, "Error writing chunk: ${e.message}")
        }
    }

    private fun finishReceiving(transferId: String) {
        val fos = activeTransfers.remove(transferId) ?: return
        val files = transferFiles.remove(transferId) ?: return

        try {
            fos.flush()
            fos.close()

            val (partFile, finalFile) = files
            if (finalFile.exists()) finalFile.delete()
            partFile.renameTo(finalFile)

            Log.d(TAG, "File successfully received: ${finalFile.name}")

            // Show download notification
            val notif = NotificationCompat.Builder(context, "nacmac_transfers")
                .setContentTitle("File Received from Mac")
                .setContentText("${finalFile.name} saved to Downloads/NacMac")
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setAutoCancel(true)
                .build()

            val manager = context.getSystemService(NotificationManager::class.java)
            manager.notify(transferId.hashCode(), notif)
        } catch (e: Exception) {
            Log.e(TAG, "Error finishing file: ${e.message}")
        }
    }

    private fun cancelReceiving(transferId: String) {
        val fos = activeTransfers.remove(transferId)
        val files = transferFiles.remove(transferId)
        try {
            fos?.close()
            files?.first?.delete()
            Log.d(TAG, "Transfer $transferId cancelled")
        } catch (_: Exception) {}
    }

    // MARK: - Sending File to Mac

    fun sendFileToMac(uri: Uri, onProgress: (percent: Int) -> Unit = {}) {
        scope.launch(Dispatchers.IO) {
            val transferId = UUID.randomUUID().toString()
            val resolver = context.contentResolver

            // Get file name and size
            var filename = "shared_file_${System.currentTimeMillis()}"
            var fileSize = 0L

            resolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (nameIndex != -1) filename = cursor.getString(nameIndex)
                    if (sizeIndex != -1) fileSize = cursor.getLong(sizeIndex)
                }
            }

            val inputStream = resolver.openInputStream(uri) ?: return@launch

            // 1. Send FILE_START
            val startPayload = FileStartPayload(transferId, filename, fileSize)
            connectionManager.sendEnvelope(
                NacMacEnvelope(NacMacMessageType.FILE_START, startPayload.toJSON().toString())
            )

            // 2. Stream chunks (Optimized 256 KB buffer with zero sleep throttling)
            val buffer = ByteArray(256 * 1024) // 256 KB high-throughput
            var bytesRead: Int
            var offset = 0L

            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                val chunkData = if (bytesRead == buffer.size) buffer else buffer.copyOf(bytesRead)
                val base64Data = Base64.encodeToString(chunkData, Base64.NO_WRAP)

                val chunkPayload = FileChunkPayload(transferId, offset, bytesRead, base64Data)
                connectionManager.sendEnvelope(
                    NacMacEnvelope(NacMacMessageType.FILE_CHUNK, chunkPayload.toJSON().toString())
                )

                offset += bytesRead
                if (fileSize > 0) {
                    val percent = ((offset.toDouble() / fileSize) * 100).toInt()
                    onProgress(percent)
                }
                yield() // Cooperative yield without blocking thread execution
            }

            inputStream.close()

            // 3. Send FILE_END
            val endObj = JSONObject().apply {
                put("transferId", transferId)
                put("totalBytes", offset)
            }
            connectionManager.sendEnvelope(
                NacMacEnvelope(NacMacMessageType.FILE_END, endObj.toString())
            )
            onProgress(100)
            Log.d(TAG, "Finished sending $filename ($offset bytes)")
        }
    }
}
