import Foundation
import CoreImage
import AppKit

public final class PairingManager: @unchecked Sendable {
    public static let shared = PairingManager()
    
    private let multiStorageURL: URL
    private let legacyStorageURL: URL
    private let qrPayloadURL: URL
    private var pairedDevices: [PairedDeviceRecord] = []
    private var activeSecret: String
    public let macId: String
    public let macName: String
    public let defaultPort: Int = 52840
    
    private let lock = NSLock()
    
    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".nacmac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.multiStorageURL = dir.appendingPathComponent("paired_devices.json")
        self.legacyStorageURL = dir.appendingPathComponent("paired_device.json")
        self.qrPayloadURL = dir.appendingPathComponent("active_qr.json")
        
        // Migrate legacy .lmm if present
        let legacyDir = home.appendingPathComponent(".lmm", isDirectory: true)
        let legacyStorage = legacyDir.appendingPathComponent("paired_device.json")
        if !FileManager.default.fileExists(atPath: self.legacyStorageURL.path) && FileManager.default.fileExists(atPath: legacyStorage.path) {
            try? FileManager.default.copyItem(at: legacyStorage, to: self.legacyStorageURL)
        }
        
        self.macId = Host.current().name ?? UUID().uuidString
        self.macName = Host.current().localizedName ?? "Mac"
        self.activeSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        
        loadPairedDevices()
        saveActiveQRPayload()
    }
    
    public func getLocalIPAddresses() -> [String] {
        var addresses = [String]()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return ["127.0.0.1"] }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            
            // Filter loopback and check for IPv4
            if (flags & (IFF_UP|IFF_RUNNING)) != 0 && (flags & IFF_LOOPBACK) == 0 {
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                                   &hostname, socklen_t(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = hostname.withUnsafeBufferPointer { ptr in
                            ptr.baseAddress != nil ? String(cString: ptr.baseAddress!) : ""
                        }
                        if !ip.isEmpty {
                            addresses.append(ip)
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        if !addresses.contains("10.0.2.2") {
            addresses.append("10.0.2.2") // Android Emulator AVD host bridge
        }
        return addresses.isEmpty ? ["127.0.0.1", "10.0.2.2"] : addresses
    }
    
    public func generateQRPayload() -> PairingQRPayload {
        lock.lock()
        defer { lock.unlock() }
        
        let ips = getLocalIPAddresses()
        let payload = PairingQRPayload(
            macId: macId,
            macName: macName,
            ips: ips,
            port: defaultPort,
            secret: activeSecret
        )
        return payload
    }
    
    public func generateQRJSONString() -> String {
        let payload = generateQRPayload()
        if let data = try? JSONEncoder().encode(payload), let str = String(data: data, encoding: .utf8) {
            saveActiveQRPayload()
            return str
        }
        return ""
    }
    
    public func generateQRImage(from text: String) -> NSImage? {
        guard let data = text.data(using: .utf8) else { return nil }
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        
        guard let ciImage = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)
        
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
    
    public func validatePairRequest(_ req: PairRequestPayload) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let matchesActiveSecret = (req.authSecret == activeSecret)
        let matchedIndex = pairedDevices.firstIndex(where: { $0.androidId == req.androidId && $0.secret == req.authSecret })
        
        if matchesActiveSecret || matchedIndex != nil {
            let record = PairedDeviceRecord(androidId: req.androidId, deviceName: req.deviceName, secret: req.authSecret)
            if let idx = pairedDevices.firstIndex(where: { $0.androidId == req.androidId }) {
                pairedDevices[idx] = record
            } else {
                pairedDevices.append(record)
            }
            savePairedDevices()
            return true
        }
        return false
    }
    
    public func isDeviceTrusted(androidId: String, secret: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pairedDevices.contains(where: { $0.androidId == androidId && $0.secret == secret })
    }
    
    public func getPairedDevice() -> PairedDeviceRecord? {
        lock.lock()
        defer { lock.unlock() }
        return pairedDevices.last
    }

    public func getPairedDevice(androidId: String) -> PairedDeviceRecord? {
        lock.lock()
        defer { lock.unlock() }
        return pairedDevices.first(where: { $0.androidId == androidId })
    }

    public func getPairedDevices() -> [PairedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return pairedDevices
    }
    
    public func unpair(androidId: String) {
        lock.lock()
        defer { lock.unlock() }
        pairedDevices.removeAll { $0.androidId == androidId }
        savePairedDevices()
    }

    public func unpair() {
        lock.lock()
        defer { lock.unlock() }
        pairedDevices.removeAll()
        try? FileManager.default.removeItem(at: multiStorageURL)
        try? FileManager.default.removeItem(at: legacyStorageURL)
        try? FileManager.default.removeItem(at: qrPayloadURL)
        let home = FileManager.default.homeDirectoryForCurrentUser
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".lmm/paired_device.json"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".lmm/active_qr.json"))
        activeSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        saveActiveQRPayload()
    }
    
    private func savePairedDevices() {
        if let data = try? JSONEncoder().encode(pairedDevices) {
            try? data.write(to: multiStorageURL)
        }
        // Save latest record to legacy file for backward compatibility with existing tests
        if let last = pairedDevices.last, let legacyData = try? JSONEncoder().encode(last) {
            try? legacyData.write(to: legacyStorageURL)
        } else if pairedDevices.isEmpty {
            try? FileManager.default.removeItem(at: legacyStorageURL)
        }
    }
    
    private func saveActiveQRPayload() {
        let payload = PairingQRPayload(
            macId: macId,
            macName: macName,
            ips: getLocalIPAddresses(),
            port: defaultPort,
            secret: activeSecret
        )
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: qrPayloadURL)
        }
    }
    
    private func loadPairedDevices() {
        if let multiData = try? Data(contentsOf: multiStorageURL),
           let records = try? JSONDecoder().decode([PairedDeviceRecord].self, from: multiData) {
            self.pairedDevices = records
            if let last = records.last {
                self.activeSecret = last.secret
            }
            return
        }

        // Fallback to legacy single-device JSON
        if let legacyData = try? Data(contentsOf: legacyStorageURL) {
            if let record = try? JSONDecoder().decode(PairedDeviceRecord.self, from: legacyData) {
                self.pairedDevices = [record]
                self.activeSecret = record.secret
                savePairedDevices()
            } else if let records = try? JSONDecoder().decode([PairedDeviceRecord].self, from: legacyData) {
                self.pairedDevices = records
                if let last = records.last {
                    self.activeSecret = last.secret
                }
                savePairedDevices()
            }
        }
    }
}
