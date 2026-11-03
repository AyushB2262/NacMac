import Foundation

// MARK: - Protocol Message Types
public enum NacMacMessageType: String, Codable, Sendable {
    case pairRequest = "PAIR_REQUEST"
    case pairResponse = "PAIR_RESPONSE"
    case heartbeatPing = "HEARTBEAT_PING"
    case heartbeatPong = "HEARTBEAT_PONG"
    case notification = "NOTIFICATION"
    case notificationDismissed = "NOTIFICATION_DISMISSED"
    case notificationAction = "NOTIFICATION_ACTION"
    case clipboardSync = "CLIPBOARD_SYNC"
    case smsConversationsRequest = "SMS_CONVERSATIONS_REQUEST"
    case smsConversationsResponse = "SMS_CONVERSATIONS_RESPONSE"
    case smsMessagesRequest = "SMS_MESSAGES_REQUEST"
    case smsMessagesResponse = "SMS_MESSAGES_RESPONSE"
    case smsSend = "SMS_SEND"
    case smsSendStatus = "SMS_SEND_STATUS"
    case fileStart = "FILE_START"
    case fileChunk = "FILE_CHUNK"
    case fileEnd = "FILE_END"
    case fileCancel = "FILE_CANCEL"
    case fileAck = "FILE_ACK"
    case error = "ERROR"
}

// MARK: - Top-Level Protocol Envelope
public struct NacMacEnvelope: Codable, Sendable {
    public let type: NacMacMessageType
    public let payload: String // JSON-encoded string for flexible framing
    
    public init(type: NacMacMessageType, payload: String) {
        self.type = type
        self.payload = payload
    }
}

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
public struct NotificationActionInfo: Codable, Sendable {
    public let index: Int
    public let title: String
    public let isReply: Bool
    
    public init(index: Int, title: String, isReply: Bool = false) {
        self.index = index
        self.title = title
        self.isReply = isReply
    }
}

public struct NotificationPayload: Codable, Sendable {
    public let id: String
    public let packageName: String
    public let appName: String
    public let title: String
    public let body: String
    public let iconBase64: String?
    public let timestamp: Int64
    public let hasReplyAction: Bool
    public let filePath: String?
    public var deviceId: String?
    public var deviceName: String?
    public let actions: [NotificationActionInfo]?
    
    public init(id: String, packageName: String, appName: String, title: String, body: String, iconBase64: String? = nil, timestamp: Int64 = Int64(Date().timeIntervalSince1970), hasReplyAction: Bool = false, filePath: String? = nil, deviceId: String? = nil, deviceName: String? = nil, actions: [NotificationActionInfo]? = nil) {
        self.id = id
        self.packageName = packageName
        self.appName = appName
        self.title = title
        self.body = body
        self.iconBase64 = iconBase64
        self.timestamp = timestamp
        self.hasReplyAction = hasReplyAction
        self.filePath = filePath
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey {
        case id, packageName, appName, title, body, iconBase64, timestamp, hasReplyAction, filePath, deviceId, deviceName, actions
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
        self.filePath = try? container.decodeIfPresent(String.self, forKey: .filePath)
        self.deviceId = try? container.decodeIfPresent(String.self, forKey: .deviceId)
        self.deviceName = try? container.decodeIfPresent(String.self, forKey: .deviceName)
        self.actions = try? container.decodeIfPresent([NotificationActionInfo].self, forKey: .actions)
    }
}

public struct NotificationDismissPayload: Codable, Sendable {
    public let id: String
    public let deviceId: String?
    
    public init(id: String, deviceId: String? = nil) {
        self.id = id
        self.deviceId = deviceId
    }
}

public struct NotificationActionPayload: Codable, Sendable {
    public let notificationKey: String
    public let actionIndex: Int
    public let replyText: String?
    public let deviceId: String?
    
    public init(notificationKey: String, actionIndex: Int, replyText: String? = nil, deviceId: String? = nil) {
        self.notificationKey = notificationKey
        self.actionIndex = actionIndex
        self.replyText = replyText
        self.deviceId = deviceId
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

// MARK: - Clipboard Sync Payload
public struct ClipboardSyncPayload: Codable, Sendable {
    public let text: String
    public let timestamp: Int64
    public let sourceDeviceId: String
    public let hash: String
    
    public init(text: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000), sourceDeviceId: String, hash: String) {
        self.text = text
        self.timestamp = timestamp
        self.sourceDeviceId = sourceDeviceId
        self.hash = hash
    }
}

// MARK: - SMS / RCS Messaging Payloads
public struct SMSThreadItem: Codable, Sendable, Identifiable {
    public var id: Int64 { threadId }
    public let threadId: Int64
    public let address: String
    public let contactName: String?
    public let snippet: String
    public let timestamp: Int64
    public let unreadCount: Int
    
    public init(threadId: Int64, address: String, contactName: String? = nil, snippet: String, timestamp: Int64, unreadCount: Int = 0) {
        self.threadId = threadId
        self.address = address
        self.contactName = contactName
        self.snippet = snippet
        self.timestamp = timestamp
        self.unreadCount = unreadCount
    }
}

public struct SMSConversationsRequestPayload: Codable, Sendable {
    public let limit: Int
    
    public init(limit: Int = 50) {
        self.limit = limit
    }
}

public struct SMSConversationsResponsePayload: Codable, Sendable {
    public let threads: [SMSThreadItem]
    public let deviceId: String?
    
    public init(threads: [SMSThreadItem], deviceId: String? = nil) {
        self.threads = threads
        self.deviceId = deviceId
    }
}

public struct SMSMessageItem: Codable, Sendable, Identifiable {
    public var id: Int64 { messageId }
    public let messageId: Int64
    public let threadId: Int64
    public let address: String
    public let body: String
    public let timestamp: Int64
    public let isIncoming: Bool
    
    public init(messageId: Int64, threadId: Int64, address: String, body: String, timestamp: Int64, isIncoming: Bool) {
        self.messageId = messageId
        self.threadId = threadId
        self.address = address
        self.body = body
        self.timestamp = timestamp
        self.isIncoming = isIncoming
    }
}

public struct SMSMessagesRequestPayload: Codable, Sendable {
    public let threadId: Int64
    public let limit: Int
    
    public init(threadId: Int64, limit: Int = 100) {
        self.threadId = threadId
        self.limit = limit
    }
}

public struct SMSMessagesResponsePayload: Codable, Sendable {
    public let threadId: Int64
    public let messages: [SMSMessageItem]
    public let deviceId: String?
    
    public init(threadId: Int64, messages: [SMSMessageItem], deviceId: String? = nil) {
        self.threadId = threadId
        self.messages = messages
        self.deviceId = deviceId
    }
}

public struct SMSSendPayload: Codable, Sendable {
    public let recipient: String
    public let message: String
    public let threadId: Int64?
    
    public init(recipient: String, message: String, threadId: Int64? = nil) {
        self.recipient = recipient
        self.message = message
        self.threadId = threadId
    }
}

public struct SMSSendStatusPayload: Codable, Sendable {
    public let success: Bool
    public let message: String
    public let threadId: Int64?
    
    public init(success: Bool, message: String, threadId: Int64? = nil) {
        self.success = success
        self.message = message
        self.threadId = threadId
    }
}

