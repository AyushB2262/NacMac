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
import com.nactore.nacmac.data.DeviceStore
import com.nactore.nacmac.model.*
import com.nactore.nacmac.network.ConnectionManager
import com.nactore.nacmac.util.FileUtils
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

data class ActiveTransferState(
    val transferId: String,
    val filename: String,
    val bytesTransferred: Long,
    val totalBytes: Long,
    val isIncoming: Boolean,
    val percent: Int
)

class FileTransferWorker(
    private val context: Context,
    private val connectionManager: ConnectionManager
) {
    private val TAG = "NacMac-FileTransfer"
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val deviceStore = DeviceStore(context)

    private val activeTransfers = mutableMapOf<String, FileOutputStream>()
    private val transferFiles = mutableMapOf<String, Pair<File, File>>() // transferId -> (partFile, finalFile)
    private val incomingSizes = mutableMapOf<String, Long>()
    private val incomingBytes = mutableMapOf<String, Long>()

    private val _activeTransfer = MutableStateFlow<ActiveTransferState?>(null)
    val activeTransfer: StateFlow<ActiveTransferState?> = _activeTransfer

    private val _recentTransfers = MutableStateFlow<List<TransferRecord>>(deviceStore.getRecentTransfers())
    val recentTransfers: StateFlow<List<TransferRecord>> = _recentTransfers

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
                val endPayload = FileEndPayload.fromJSON(envelope.payload)
                if (endPayload != null) {
                    finishReceiving(endPayload.transferId, endPayload.totalBytes, endPayload.sha256)
                }
            }
            NacMacMessageType.FILE_CANCEL -> {
                val obj = JSONObject(envelope.payload)
                val id = obj.getString("transferId")
                cancelReceiving(id)
            }
            else -> {}
        }
    }

    private fun getUniqueFile(targetFile: File): File {
        if (!targetFile.exists()) return targetFile
        val parent = targetFile.parentFile ?: return targetFile
        val name = targetFile.nameWithoutExtension
        val ext = targetFile.extension
        var counter = 1
        while (true) {
            val newName = if (ext.isEmpty()) "$name ($counter)" else "$name ($counter).$ext"
            val newFile = File(parent, newName)
            if (!newFile.exists()) return newFile
            counter++
        }
    }

    private fun startReceiving(start: FileStartPayload) {
        val downloadDir = FileUtils.getDownloadsDirectory()
        val rawFilename = File(start.filename).name.trim()
        if (rawFilename.isEmpty() || rawFilename == "." || rawFilename == "..") {
            Log.e(TAG, "Rejected unsafe filename: ${start.filename}")
            return
        }

        val finalFile = File(downloadDir, rawFilename).canonicalFile
        if (!finalFile.path.startsWith(downloadDir.canonicalPath)) {
            Log.e(TAG, "Path traversal attempt blocked: ${start.filename}")
            return
        }

        val partFile = File(downloadDir, "$rawFilename.part")
        if (partFile.exists()) partFile.delete()

        try {
            val fos = FileOutputStream(partFile)
            activeTransfers[start.transferId] = fos
            transferFiles[start.transferId] = Pair(partFile, finalFile)
            incomingSizes[start.transferId] = start.size
            incomingBytes[start.transferId] = 0L

            _activeTransfer.value = ActiveTransferState(
                transferId = start.transferId,
                filename = rawFilename,
                bytesTransferred = 0L,
                totalBytes = start.size,
                isIncoming = true,
                percent = 0
            )

            Log.d(TAG, "Started receiving file: $rawFilename (${start.size} bytes)")
        } catch (e: Exception) {
            Log.e(TAG, "Error starting file receive: ${e.message}")
        }
    }

    private fun writeChunk(chunk: FileChunkPayload) {
        val fos = activeTransfers[chunk.transferId] ?: return
        try {
            val data = Base64.decode(chunk.dataBase64, Base64.NO_WRAP)
            fos.write(data)

            val current = (incomingBytes[chunk.transferId] ?: 0L) + data.size
            incomingBytes[chunk.transferId] = current
            val total = incomingSizes[chunk.transferId] ?: 0L
            val percent = if (total > 0) ((current.toDouble() / total) * 100).toInt().coerceIn(0, 100) else 0

            _activeTransfer.value = _activeTransfer.value?.copy(
                bytesTransferred = current,
                percent = percent
            )
        } catch (e: Exception) {
            Log.e(TAG, "Error writing chunk: ${e.message}")
        }
    }

    private fun finishReceiving(transferId: String, expectedTotal: Long = 0L, expectedSha256: String? = null) {
        val fos = activeTransfers.remove(transferId) ?: return
        val files = transferFiles.remove(transferId) ?: return
        val totalSize = if (expectedTotal > 0L) expectedTotal else (incomingSizes.remove(transferId) ?: 0L)
        val received = incomingBytes.remove(transferId) ?: 0L

        try {
            fos.flush()
            fos.close()

            val (partFile, finalFile) = files

            // 1. Verify size
            if (totalSize > 0L && partFile.length() != totalSize) {
                Log.e(TAG, "File size mismatch: expected $totalSize, actual ${partFile.length()}")
                partFile.delete()
                _activeTransfer.value = null
                return
            }

            // 2. Verify SHA-256 integrity if provided
            if (!expectedSha256.isNullOrEmpty()) {
                val md = MessageDigest.getInstance("SHA-256")
                partFile.inputStream().use { input ->
                    val buf = ByteArray(64 * 1024)
                    var r: Int
                    while (input.read(buf).also { r = it } != -1) {
                        md.update(buf, 0, r)
                    }
                }
                val actualSha = md.digest().joinToString("") { "%02x".format(it) }
                if (!actualSha.equals(expectedSha256, ignoreCase = true)) {
                    Log.e(TAG, "SHA-256 mismatch! Expected $expectedSha256, got $actualSha")
                    partFile.delete()
                    _activeTransfer.value = null
                    return
                }
                Log.i(TAG, "SHA-256 verified successfully: $actualSha")
            }

            // 3. Collision avoidance: never overwrite existing files
            val uniqueTarget = getUniqueFile(finalFile)
            partFile.renameTo(uniqueTarget)

            // Index in MediaStore immediately so Gallery and Photos apps know the file exists
            try {
                android.media.MediaScannerConnection.scanFile(
                    context,
                    arrayOf(uniqueTarget.absolutePath),
                    arrayOf(FileUtils.getMimeType(uniqueTarget.name)),
                    null
                )
            } catch (_: Exception) {}

            _activeTransfer.value = null

            // Record completed received transfer in persistent history
            val record = TransferRecord(
                id = transferId,
                name = uniqueTarget.name,
                sizeBytes = if (totalSize > 0) totalSize else uniqueTarget.length(),
                isIncoming = true,
                timestamp = System.currentTimeMillis()
            )
            deviceStore.addRecentTransfer(record)
            _recentTransfers.value = deviceStore.getRecentTransfers()

            Log.d(TAG, "File successfully received and recorded: ${finalFile.name}")

            // Show download notification with direct file opening and folder action
            val openPendingIntent = FileUtils.createOpenFilePendingIntent(context, finalFile, transferId.hashCode())
            val folderPendingIntent = FileUtils.createOpenFolderPendingIntent(context, transferId.hashCode() + 1)

            val notif = NotificationCompat.Builder(context, "nacmac_transfers")
                .setContentTitle("File Received from Mac")
                .setContentText("${finalFile.name} • Tap to open")
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentIntent(openPendingIntent)
                .addAction(android.R.drawable.ic_menu_agenda, "Open Folder", folderPendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
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
        incomingSizes.remove(transferId)
        incomingBytes.remove(transferId)
        _activeTransfer.value = null
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

            _activeTransfer.value = ActiveTransferState(
                transferId = transferId,
                filename = filename,
                bytesTransferred = 0L,
                totalBytes = fileSize,
                isIncoming = false,
                percent = 0
            )

            // 1. Send FILE_START sequentially
            val startPayload = FileStartPayload(transferId, filename, fileSize)
            connectionManager.sendEnvelopeOrdered(
                NacMacEnvelope(NacMacMessageType.FILE_START, startPayload.toJSON().toString())
            )

            // 2. Stream chunks (Optimized 256 KB buffer with sequential backpressure)
            val buffer = ByteArray(256 * 1024) // 256 KB high-throughput
            var bytesRead: Int
            var offset = 0L
            val md = MessageDigest.getInstance("SHA-256")

            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                val chunkData = if (bytesRead == buffer.size) buffer else buffer.copyOf(bytesRead)
                md.update(chunkData)
                val base64Data = Base64.encodeToString(chunkData, Base64.NO_WRAP)

                val chunkPayload = FileChunkPayload(transferId, offset, bytesRead, base64Data)
                connectionManager.sendEnvelopeOrdered(
                    NacMacEnvelope(NacMacMessageType.FILE_CHUNK, chunkPayload.toJSON().toString())
                )

                offset += bytesRead
                val percent = if (fileSize > 0) {
                    ((offset.toDouble() / fileSize) * 100).toInt().coerceIn(0, 100)
                } else {
                    0
                }

                _activeTransfer.value = _activeTransfer.value?.copy(
                    bytesTransferred = offset,
                    percent = percent
                )
                onProgress(percent)
                yield() // Cooperative yield without blocking thread execution
            }

            inputStream.close()

            // 3. Send FILE_END with SHA-256 digest
            val sha256Hex = md.digest().joinToString("") { "%02x".format(it) }
            val endPayload = FileEndPayload(transferId, offset, sha256Hex)
            connectionManager.sendEnvelopeOrdered(
                NacMacEnvelope(NacMacMessageType.FILE_END, endPayload.toJSON().toString())
            )

            _activeTransfer.value = null

            // Record completed sent transfer in persistent history
            val record = TransferRecord(
                id = transferId,
                name = filename,
                sizeBytes = offset,
                isIncoming = false,
                timestamp = System.currentTimeMillis()
            )
            deviceStore.addRecentTransfer(record)
            _recentTransfers.value = deviceStore.getRecentTransfers()

            onProgress(100)
            Log.d(TAG, "Finished sending and recorded $filename ($offset bytes)")

            // Show sent notification
            val folderPendingIntent = FileUtils.createOpenFolderPendingIntent(context, transferId.hashCode() + 1)
            val sentNotif = NotificationCompat.Builder(context, "nacmac_transfers")
                .setContentTitle("File Sent to Mac")
                .setContentText("$filename sent successfully")
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setContentIntent(folderPendingIntent)
                .setAutoCancel(true)
                .build()
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.notify(transferId.hashCode(), sentNotif)
        }
    }

    fun clearHistory() {
        deviceStore.clearRecentTransfers()
        _recentTransfers.value = emptyList()
    }
}
