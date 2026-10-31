import Foundation
import CoreImage
import AppKit

public final class PairingManager: @unchecked Sendable {
    public static let shared = PairingManager()
    
    private let storageURL: URL
    private let qrPayloadURL: URL
    private var pairedDevice: PairedDeviceRecord?
    private var activeSecret: String
    public let macId: String
    public let macName: String
    public let defaultPort: Int = 52840
    
    private let lock = NSLock()
    
    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".nacmac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageURL = dir.appendingPathComponent("paired_device.json")
        self.qrPayloadURL = dir.appendingPathComponent("active_qr.json")
        
        // Migrate legacy .lmm if present
        let legacyDir = home.appendingPathComponent(".lmm", isDirectory: true)
        let legacyStorage = legacyDir.appendingPathComponent("paired_device.json")
        if !FileManager.default.fileExists(atPath: self.storageURL.path) && FileManager.default.fileExists(atPath: legacyStorage.path) {
            try? FileManager.default.copyItem(at: legacyStorage, to: self.storageURL)
        }
        
        self.macId = Host.current().name ?? UUID().uuidString
        self.macName = Host.current().localizedName ?? "Mac"
        self.activeSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        
        loadPairedDevice()
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
        
        // Either matches current pairing secret or we are already paired with this device
        if req.authSecret == activeSecret || (pairedDevice != nil && pairedDevice?.androidId == req.androidId && pairedDevice?.secret == req.authSecret) {
            let record = PairedDeviceRecord(androidId: req.androidId, deviceName: req.deviceName, secret: req.authSecret)
            self.pairedDevice = record
            savePairedDevice(record)
            return true
        }
        return false
    }
    
    public func isDeviceTrusted(androidId: String, secret: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let paired = pairedDevice else { return false }
        return paired.androidId == androidId && paired.secret == secret
    }
    
    public func getPairedDevice() -> PairedDeviceRecord? {
        lock.lock()
        defer { lock.unlock() }
        return pairedDevice
    }
    
    public func unpair() {
        lock.lock()
        defer { lock.unlock() }
        pairedDevice = nil
        try? FileManager.default.removeItem(at: storageURL)
        try? FileManager.default.removeItem(at: qrPayloadURL)
        let home = FileManager.default.homeDirectoryForCurrentUser
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".lmm/paired_device.json"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent(".lmm/active_qr.json"))
        activeSecret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        saveActiveQRPayload()
    }
    
    private func savePairedDevice(_ record: PairedDeviceRecord) {
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: storageURL)
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
    
    private func loadPairedDevice() {
        guard let data = try? Data(contentsOf: storageURL),
              let record = try? JSONDecoder().decode(PairedDeviceRecord.self, from: data) else {
            return
        }
        self.pairedDevice = record
        self.activeSecret = record.secret
    }
}
