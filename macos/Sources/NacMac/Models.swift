import Foundation

// MARK: - Protocol Message Types
public enum NacMacMessageType: String, Codable, Sendable {
    case pairRequest = "PAIR_REQUEST"
    case pairResponse = "PAIR_RESPONSE"
    case heartbeatPing = "HEARTBEAT_PING"
    case heartbeatPong = "HEARTBEAT_PONG"
    case notification = "NOTIFICATION"
    case notificationDismissed = "NOTIFICATION_DISMISSED"
    case fileStart = "FILE_START"
    case fileChunk = "FILE_CHUNK"
    case fileEnd = "FILE_END"
    case fileCancel = "FILE_CANCEL"
    case fileAck = "FILE_ACK"
    case error = "ERROR"
}

public typealias LMMMessageType = NacMacMessageType

// MARK: - Top-Level Protocol Envelope
public struct NacMacEnvelope: Codable, Sendable {
    public let type: NacMacMessageType
    public let payload: String // JSON-encoded string for flexible framing
    
    public init(type: NacMacMessageType, payload: String) {
        self.type = type
        self.payload = payload
    }
}

public typealias LMMEnvelope = NacMacEnvelope

// MARK: - Pairing Payloads
public struct PairingQRPayload: Codable, Sendable {
    public let v: Int
    public let macId: String
    public let macName: String
    public let ips: [String]
    public let port: Int
    public let secret: String
    public let timestamp: Int64
    
    public init(v: Int = 1, macId: String, macName: String, ips: [String], port: Int, secret: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.v = v
        self.macId = macId
        self.macName = macName
        self.ips = ips
        self.port = port
        self.secret = secret
        self.timestamp = timestamp
    }
}

public struct PairRequestPayload: Codable, Sendable {
    public let androidId: String
    public let deviceName: String
    public let authSecret: String
    
    public init(androidId: String, deviceName: String, authSecret: String) {
        self.androidId = androidId
        self.deviceName = deviceName
        self.authSecret = authSecret
    }
}

public struct PairResponsePayload: Codable, Sendable {
    public let success: Bool
    public let macName: String
    public let message: String
    
    public init(success: Bool, macName: String, message: String) {
        self.success = success
        self.macName = macName
        self.message = message
    }
}

// MARK: - Notification Payloads
public struct NotificationPayload: Codable, Sendable {
    public let id: String
    public let packageName: String
    public let appName: String
    public let title: String
    public let body: String
    public let iconBase64: String?
    public let timestamp: Int64
    public let hasReplyAction: Bool
    
    public init(id: String, packageName: String, appName: String, title: String, body: String, iconBase64: String? = nil, timestamp: Int64 = Int64(Date().timeIntervalSince1970), hasReplyAction: Bool = false) {
        self.id = id
        self.packageName = packageName
        self.appName = appName
        self.title = title
        self.body = body
        self.iconBase64 = iconBase64
        self.timestamp = timestamp
        self.hasReplyAction = hasReplyAction
    }

    private enum CodingKeys: String, CodingKey {
        case id, packageName, appName, title, body, iconBase64, timestamp, hasReplyAction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.packageName = (try? container.decodeIfPresent(String.self, forKey: .packageName)) ?? ""
        self.appName = (try? container.decodeIfPresent(String.self, forKey: .appName)) ?? "Android"
        self.title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        self.body = (try? container.decodeIfPresent(String.self, forKey: .body)) ?? ""
        self.iconBase64 = try? container.decodeIfPresent(String.self, forKey: .iconBase64)
        self.timestamp = (try? container.decodeIfPresent(Int64.self, forKey: .timestamp)) ?? Int64(Date().timeIntervalSince1970)
        self.hasReplyAction = (try? container.decodeIfPresent(Bool.self, forKey: .hasReplyAction)) ?? false
    }
}

public struct NotificationDismissPayload: Codable, Sendable {
    public let id: String
    
    public init(id: String) {
        self.id = id
    }
}

// MARK: - File Transfer Payloads
public struct FileStartPayload: Codable, Sendable {
    public let transferId: String
    public let filename: String
    public let size: Int64
    public let sha256: String?
    
    public init(transferId: String, filename: String, size: Int64, sha256: String? = nil) {
        self.transferId = transferId
        self.filename = filename
        self.size = size
        self.sha256 = sha256
    }
}

public struct FileChunkPayload: Codable, Sendable {
    public let transferId: String
    public let offset: Int64
    public let length: Int
    public let dataBase64: String
    
    public init(transferId: String, offset: Int64, length: Int, dataBase64: String) {
        self.transferId = transferId
        self.offset = offset
        self.length = length
        self.dataBase64 = dataBase64
    }
}

public struct FileEndPayload: Codable, Sendable {
    public let transferId: String
    public let totalBytes: Int64
    
    public init(transferId: String, totalBytes: Int64) {
        self.transferId = transferId
        self.totalBytes = totalBytes
    }
}

public struct FileCancelPayload: Codable, Sendable {
    public let transferId: String
    public let reason: String
    
    public init(transferId: String, reason: String = "User cancelled") {
        self.transferId = transferId
        self.reason = reason
    }
}

public struct FileAckPayload: Codable, Sendable {
    public let transferId: String
    public let success: Bool
    public let message: String
    
    public init(transferId: String, success: Bool, message: String) {
        self.transferId = transferId
        self.success = success
        self.message = message
    }
}

// MARK: - Paired Device Storage Record
public struct PairedDeviceRecord: Codable, Sendable {
    public let androidId: String
    public let deviceName: String
    public let secret: String
    public let pairedAt: Date
    
    public init(androidId: String, deviceName: String, secret: String, pairedAt: Date = Date()) {
        self.androidId = androidId
        self.deviceName = deviceName
        self.secret = secret
        self.pairedAt = pairedAt
    }
}
