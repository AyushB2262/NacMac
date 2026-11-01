import Foundation
import AppKit

public struct ActiveTransferProgress: Sendable {
    public let transferId: String
    public let filename: String
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double
    public let isReceiving: Bool
    
    public var percent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesTransferred) / Double(totalBytes) * 100.0
    }
}

public protocol FileTransferDelegate: AnyObject, Sendable {
    func transferDidProgress(_ progress: ActiveTransferProgress)
    func transferDidComplete(transferId: String, filename: String, isReceiving: Bool)
    func transferDidCancel(transferId: String, reason: String)
    func transferDidFail(transferId: String, error: String)
}

public final class FileTransferManager: @unchecked Sendable {
    public static let shared = FileTransferManager()
    
    public let downloadDirectory: URL
    public weak var delegate: FileTransferDelegate?
    
    // In-flight incoming transfers: transferId -> (fileHandle, meta, bytesReceived, startTime)
    private var incomingTransfers = [String: (handle: FileHandle, targetURL: URL, partURL: URL, totalBytes: Int64, receivedBytes: Int64, startTime: Date)]()
    
    // Outgoing transfer cancel flags: transferId -> isCancelled
    private var cancelledOutgoing = Set<String>()
    
    private let lock = NSLock()
    
    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.downloadDirectory = home.appendingPathComponent("Downloads/NacMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - Receiving Chunks from Android
    
    public func handleFileStart(_ payload: FileStartPayload) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let targetURL = downloadDirectory.appendingPathComponent(payload.filename)
        let partURL = downloadDirectory.appendingPathComponent("\(payload.filename).part")
        
        // Remove existing part file if any
        try? FileManager.default.removeItem(at: partURL)
        FileManager.default.createFile(atPath: partURL.path, contents: nil, attributes: nil)
        
        guard let handle = try? FileHandle(forWritingTo: partURL) else {
            print("[NacMac-File] Failed to open part file at \(partURL.path)")
            return false
        }
        
        incomingTransfers[payload.transferId] = (
            handle: handle,
            targetURL: targetURL,
            partURL: partURL,
            totalBytes: payload.size,
            receivedBytes: 0,
            startTime: Date()
        )
        print("[NacMac-File] Started receiving file: \(payload.filename) (\(payload.size) bytes)")
        return true
    }
    
    public func handleFileChunk(_ payload: FileChunkPayload) -> Bool {
        lock.lock()
        guard var entry = incomingTransfers[payload.transferId],
              let chunkData = Data(base64Encoded: payload.dataBase64) else {
            lock.unlock()
            return false
        }
        
        do {
            try entry.handle.seek(toOffset: UInt64(payload.offset))
            try entry.handle.write(contentsOf: chunkData)
            entry.receivedBytes += Int64(chunkData.count)
            incomingTransfers[payload.transferId] = entry
            lock.unlock()
            
            let elapsed = max(Date().timeIntervalSince(entry.startTime), 0.001)
            let speed = Double(entry.receivedBytes) / elapsed
            
            let progress = ActiveTransferProgress(
                transferId: payload.transferId,
                filename: entry.targetURL.lastPathComponent,
                bytesTransferred: entry.receivedBytes,
                totalBytes: entry.totalBytes,
                bytesPerSecond: speed,
                isReceiving: true
            )
            delegate?.transferDidProgress(progress)
            return true
        } catch {
            lock.unlock()
            print("[NacMac-File] Write chunk error: \(error)")
            return false
        }
    }
    
    public func handleFileEnd(_ payload: FileEndPayload) -> Bool {
        lock.lock()
        guard let entry = incomingTransfers.removeValue(forKey: payload.transferId) else {
            lock.unlock()
            return false
        }
        lock.unlock()
        
        try? entry.handle.close()
        
        // Finalize part file to destination
        try? FileManager.default.removeItem(at: entry.targetURL)
        do {
            try FileManager.default.moveItem(at: entry.partURL, to: entry.targetURL)
            print("[NacMac-File] Successfully completed file transfer: \(entry.targetURL.path)")
            
            delegate?.transferDidComplete(
                transferId: payload.transferId,
                filename: entry.targetURL.lastPathComponent,
                isReceiving: true
            )
            
            // Notification of file receipt
            let notif = NotificationPayload(
                id: UUID().uuidString,
                packageName: "com.nactore.nacmac.file",
                appName: "NacMac",
                title: "File Received",
                body: "\(entry.targetURL.lastPathComponent) saved to Downloads"
            )
            NotificationManager.shared.deliverNotification(notif)
            return true
        } catch {
            print("[NacMac-File] Failed to finalize file: \(error)")
            return false
        }
    }
    
    public func handleFileCancel(_ payload: FileCancelPayload) {
        lock.lock()
        if let entry = incomingTransfers.removeValue(forKey: payload.transferId) {
            try? entry.handle.close()
            try? FileManager.default.removeItem(at: entry.partURL)
        }
        cancelledOutgoing.insert(payload.transferId)
        lock.unlock()
        
        print("[NacMac-File] Transfer \(payload.transferId) cancelled: \(payload.reason)")
        delegate?.transferDidCancel(transferId: payload.transferId, reason: payload.reason)
    }
    
    public func cancelTransfer(transferId: String) {
        handleFileCancel(FileCancelPayload(transferId: transferId, reason: "Cancelled by Mac user"))
    }
    
    // MARK: - Sending Files to Android
    
    public func sendFile(at fileURL: URL, sendChunkHandler: @escaping @Sendable (NacMacEnvelope) -> Void) {
        let transferId = UUID().uuidString
        let filename = fileURL.lastPathComponent
        
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            print("[NacMac-File] Unable to read file at \(fileURL.path)")
            delegate?.transferDidFail(transferId: transferId, error: "Cannot read file")
            return
        }
        
        // 1. Send FILE_START
        let startPayload = FileStartPayload(transferId: transferId, filename: filename, size: size)
        if let data = try? JSONEncoder().encode(startPayload), let json = String(data: data, encoding: .utf8) {
            sendChunkHandler(NacMacEnvelope(type: .fileStart, payload: json))
        }
        
        let chunkSize = 256 * 1024 // High-throughput 256 KB chunks (optimized streaming)
        let startTime = Date()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var offset: Int64 = 0
            
            while offset < size {
                self.lock.lock()
                if self.cancelledOutgoing.contains(transferId) {
                    self.cancelledOutgoing.remove(transferId)
                    self.lock.unlock()
                    try? handle.close()
                    let cancelPayload = FileCancelPayload(transferId: transferId, reason: "Cancelled by sender")
                    if let d = try? JSONEncoder().encode(cancelPayload), let j = String(data: d, encoding: .utf8) {
                        sendChunkHandler(NacMacEnvelope(type: .fileCancel, payload: j))
                    }
                    return
                }
                self.lock.unlock()
                
                let toRead = Int(min(Int64(chunkSize), size - offset))
                let chunkData = handle.readData(ofLength: toRead)
                if chunkData.isEmpty { break }
                
                let chunkPayload = FileChunkPayload(
                    transferId: transferId,
                    offset: offset,
                    length: chunkData.count,
                    dataBase64: chunkData.base64EncodedString()
                )
                
                if let d = try? JSONEncoder().encode(chunkPayload), let j = String(data: d, encoding: .utf8) {
                    sendChunkHandler(NacMacEnvelope(type: .fileChunk, payload: j))
                }
                
                offset += Int64(chunkData.count)
                let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
                let speed = Double(offset) / elapsed
                
                let progress = ActiveTransferProgress(
                    transferId: transferId,
                    filename: filename,
                    bytesTransferred: offset,
                    totalBytes: size,
                    bytesPerSecond: speed,
                    isReceiving: false
                )
                self.delegate?.transferDidProgress(progress)
            }
            
            try? handle.close()
            
            // Send FILE_END
            let endPayload = FileEndPayload(transferId: transferId, totalBytes: size)
            if let d = try? JSONEncoder().encode(endPayload), let j = String(data: d, encoding: .utf8) {
                sendChunkHandler(NacMacEnvelope(type: .fileEnd, payload: j))
            }
            
            self.delegate?.transferDidComplete(transferId: transferId, filename: filename, isReceiving: false)
            print("[NacMac-File] Finished sending \(filename) (\(size) bytes)")
        }
    }
}
