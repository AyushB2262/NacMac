import Foundation
import Network

public struct ConnectedDeviceInfo: Equatable, Sendable, Identifiable {
    public var id: String { deviceId }
    public let deviceId: String
    public let deviceName: String
    public let ip: String
    public let connectedAt: Date
    
    public init(deviceId: String, deviceName: String, ip: String, connectedAt: Date = Date()) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.ip = ip
        self.connectedAt = connectedAt
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case listening(port: UInt16)
    case connected(deviceName: String, ip: String)
    case multiConnected(devices: [ConnectedDeviceInfo])
}

public protocol NetworkServerDelegate: AnyObject, Sendable {
    func connectionStateChanged(to state: ConnectionState)
    func errorOccurred(_ message: String)
}

public final class NetworkServer: @unchecked Sendable {
    public static let shared = NetworkServer()
    
    public weak var delegate: NetworkServerDelegate?
    public private(set) var currentState: ConnectionState = .disconnected
    
    private var listener: NWListener?
    private var activeConnections: [String: NWConnection] = [:]
    private var connectionDevices: [ObjectIdentifier: String] = [:]
    private var deviceNames: [String: String] = [:]
    private var deviceEndpoints: [String: String] = [:]
    private var authenticatedDevices = Set<String>()
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]
    
    private var netService: NetService?
    private let queue = DispatchQueue(label: "com.nactore.nacmac.network.server", qos: .userInitiated)
    
    private var heartbeatTimer: DispatchSourceTimer?
    public let port: NWEndpoint.Port = 52840
    
    private init() {}
    
    // MARK: - Server Lifecycle
    
    public func start() {
        queue.async { [weak self] in
            self?.setupListener()
            self?.advertiseBonjour()
        }
    }
    
    public func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopHeartbeat()
            for (_, conn) in self.activeConnections {
                conn.cancel()
            }
            self.activeConnections.removeAll()
            self.connectionDevices.removeAll()
            self.authenticatedDevices.removeAll()
            self.deviceNames.removeAll()
            self.deviceEndpoints.removeAll()
            for (_, conn) in self.pendingConnections {
                conn.cancel()
            }
            self.pendingConnections.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.netService?.stop()
            self.netService = nil
            self.updateState(.disconnected)
        }
    }
    
    public func disconnectPeer(deviceId: String? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let targetId = deviceId {
                if let conn = self.activeConnections.removeValue(forKey: targetId) {
                    let connId = ObjectIdentifier(conn)
                    self.connectionDevices.removeValue(forKey: connId)
                    self.authenticatedDevices.remove(targetId)
                    self.deviceNames.removeValue(forKey: targetId)
                    self.deviceEndpoints.removeValue(forKey: targetId)
                    conn.cancel()
                }
            } else {
                self.stopHeartbeat()
                for (_, conn) in self.activeConnections {
                    conn.cancel()
                }
                self.activeConnections.removeAll()
                self.connectionDevices.removeAll()
                self.authenticatedDevices.removeAll()
                self.deviceNames.removeAll()
                self.deviceEndpoints.removeAll()
                for (_, conn) in self.pendingConnections {
                    conn.cancel()
                }
                self.pendingConnections.removeAll()
            }
            self.refreshConnectionState()
        }
    }
    
    public func getConnectedDevices() -> [ConnectedDeviceInfo] {
        queue.sync {
            return activeConnections.keys.map { id in
                ConnectedDeviceInfo(
                    deviceId: id,
                    deviceName: deviceNames[id] ?? "Android Device",
                    ip: deviceEndpoints[id] ?? "Local Wi-Fi"
                )
            }
        }
    }
    
    private func setupListener() {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 10
            
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            
            let listener = try NWListener(using: params, on: port)
            self.listener = listener
            
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    print("[NacMac-Network] Server listening on port \(self.port)")
                    self.refreshConnectionState()
                case .failed(let error):
                    print("[NacMac-Network] Server listener failed: \(error)")
                    self.delegate?.errorOccurred("Listener failed: \(error.localizedDescription)")
                    self.updateState(.disconnected)
                case .cancelled:
                    self.updateState(.disconnected)
                default:
                    break
                }
            }
            
            listener.newConnectionHandler = { [weak self] newConn in
                self?.handleNewConnection(newConn)
            }
            
            listener.start(queue: queue)
        } catch {
            print("[NacMac-Network] Failed to initialize listener: \(error)")
            self.delegate?.errorOccurred(error.localizedDescription)
        }
    }
    
    // MARK: - Bonjour Service Advertising
    
    private func advertiseBonjour() {
        let name = Host.current().localizedName ?? "NacMac"
        netService = NetService(domain: "local.", type: "_nacmac._tcp.", name: name, port: Int32(port.rawValue))
        
        let txtDict: [String: Data] = [
            "macId": PairingManager.shared.macId.data(using: .utf8) ?? Data(),
            "proto": "1.0".data(using: .utf8) ?? Data()
        ]
        let recordData = NetService.data(fromTXTRecord: txtDict)
        netService?.setTXTRecord(recordData)
        netService?.publish()
        print("[NacMac-Network] Bonjour service published: _nacmac._tcp on port \(port)")
    }
    
    // MARK: - Handling Inbound Connections
    
    private func handleNewConnection(_ conn: NWConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let connId = ObjectIdentifier(conn)
            if self.pendingConnections.count >= 8 {
                print("[NacMac-Network] Max pending connection limit reached (8), rejecting")
                conn.cancel()
                return
            }
            self.pendingConnections[connId] = conn
            
            // 5-second unauthenticated drop timeout
            self.queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self else { return }
                if self.pendingConnections[connId] != nil {
                    print("[NacMac-Network] Pending connection authentication timeout, closing")
                    self.handleDisconnection(for: conn)
                }
            }
            
            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    let remoteEndpoint = conn.endpoint
                    print("[NacMac-Network] Inbound socket connected from \(remoteEndpoint)")
                    self.readNextMessage(from: conn)
                case .failed(let err):
                    print("[NacMac-Network] Connection failed: \(err)")
                    self.handleDisconnection(for: conn)
                case .cancelled:
                    self.handleDisconnection(for: conn)
                default:
                    break
                }
            }
            
            conn.start(queue: self.queue)
        }
    }
    
    private func handleDisconnection(for conn: NWConnection) {
        let connId = ObjectIdentifier(conn)
        pendingConnections.removeValue(forKey: connId)
        
        if let deviceId = connectionDevices.removeValue(forKey: connId) {
            if activeConnections[deviceId] === conn {
                activeConnections.removeValue(forKey: deviceId)
                authenticatedDevices.remove(deviceId)
                deviceNames.removeValue(forKey: deviceId)
                deviceEndpoints.removeValue(forKey: deviceId)
                print("[NacMac-Network] Device disconnected: \(deviceId). Standing by for auto-reconnect...")
            }
        }
        
        conn.cancel()
        if activeConnections.isEmpty {
            stopHeartbeat()
        }
        refreshConnectionState()
    }
    
    // MARK: - Length-Prefixed Message Framing
    
    private func readNextMessage(from conn: NWConnection) {
        // Read 4-byte big-endian payload length header
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[NacMac-Network] Read header error: \(error)")
                self.handleDisconnection(for: conn)
                return
            }
            
            if isComplete && (data == nil || data?.isEmpty == true) {
                self.handleDisconnection(for: conn)
                return
            }
            
            guard let headerData = data, headerData.count == 4 else {
                self.handleDisconnection(for: conn)
                return
            }
            
            let length = UInt32(bigEndian: headerData.withUnsafeBytes { $0.load(as: UInt32.self) })
            let isAuthenticated = (self.connectionDevices[ObjectIdentifier(conn)] != nil)
            let maxAllowedLength: UInt32 = isAuthenticated ? (100 * 1024 * 1024) : (64 * 1024)
            guard length > 0 && length <= maxAllowedLength else {
                print("[NacMac-Network] Invalid message length: \(length) (auth: \(isAuthenticated))")
                self.handleDisconnection(for: conn)
                return
            }
            
            self.readPayload(from: conn, targetLength: Int(length), accumulated: Data())
        }
    }
    
    private func readPayload(from conn: NWConnection, targetLength: Int, accumulated: Data) {
        let remaining = targetLength - accumulated.count
        guard remaining > 0 else {
            processInboundData(accumulated, from: conn)
            readNextMessage(from: conn)
            return
        }
        
        conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[NacMac-Network] Read payload error: \(error)")
                self.handleDisconnection(for: conn)
                return
            }
            
            var currentData = accumulated
            if let chunk = data, !chunk.isEmpty {
                currentData.append(chunk)
            }
            
            if currentData.count == targetLength {
                self.processInboundData(currentData, from: conn)
                if !isComplete {
                    self.readNextMessage(from: conn)
                } else {
                    self.handleDisconnection(for: conn)
                }
            } else if isComplete {
                print("[NacMac-Network] Connection closed prematurely (received \(currentData.count) of \(targetLength) bytes)")
                self.handleDisconnection(for: conn)
            } else {
                // Continue streaming remaining bytes for this frame
                self.readPayload(from: conn, targetLength: targetLength, accumulated: currentData)
            }
        }
    }
    
    // MARK: - Message Dispatching
    
    private func processInboundData(_ data: Data, from conn: NWConnection) {
        guard let envelope = try? JSONDecoder().decode(NacMacEnvelope.self, from: data) else {
            print("[NacMac-Network] Failed to decode envelope")
            return
        }
        
        let connId = ObjectIdentifier(conn)
        let deviceId = connectionDevices[connId]
        let isAuth = (deviceId != nil && authenticatedDevices.contains(deviceId!))
        
        switch envelope.type {
        case .pairRequest:
            handlePairRequest(envelope.payload, from: conn)
            
        case .heartbeatPing:
            sendEnvelopeToConnection(NacMacEnvelope(type: .heartbeatPong, payload: "{}"), conn: conn)
            
        case .heartbeatPong:
            // Heartbeat acknowledged
            break
            
        case .clipboardSync:
            guard isAuth else {
                print("[NacMac-Security] Blocked unauthorized .clipboardSync")
                return
            }
            ClipboardSyncManager.shared.handleIncoming(envelope.payload)
            
        case .notification:
            guard isAuth else {
                print("[NacMac-Security] Blocked unauthorized .notification from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8) {
                do {
                    var notif = try JSONDecoder().decode(NotificationPayload.self, from: payloadData)
                    notif.deviceId = deviceId
                    notif.deviceName = deviceId.flatMap { self.deviceNames[$0] }
                    NotificationManager.shared.deliverNotification(notif)
                } catch {
                    print("[NacMac-Notification] Error decoding notification payload: \(error)")
                }
            }
            
        case .notificationDismissed:
            guard isAuth else {
                print("[NacMac-Security] Blocked unauthorized .notificationDismissed from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8) {
                do {
                    let dismiss = try JSONDecoder().decode(NotificationDismissPayload.self, from: payloadData)
                    NotificationManager.shared.dismissNotification(id: dismiss.id)
                } catch {
                    print("[NacMac-Notification] Error decoding dismiss payload: \(error)")
                }
            }
            
        case .notificationAction:
            guard isAuth else {
                print("[NacMac-Security] Blocked unauthorized .notificationAction")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8),
               let action = try? JSONDecoder().decode(NotificationActionPayload.self, from: payloadData) {
                print("[NacMac-Notification] Received notification action from device: \(action.notificationKey)")
            }
            
        case .smsConversationsResponse:
            guard isAuth else { return }
            if let payloadData = envelope.payload.data(using: .utf8),
               let resp = try? JSONDecoder().decode(SMSConversationsResponsePayload.self, from: payloadData) {
                let effectiveResp = resp.deviceId != nil ? resp : SMSConversationsResponsePayload(threads: resp.threads, deviceId: deviceId)
                Task { @MainActor in
                    DashboardState.shared.handleSMSConversations(effectiveResp)
                }
            }
            
        case .smsMessagesResponse:
            guard isAuth else { return }
            if let payloadData = envelope.payload.data(using: .utf8),
               let resp = try? JSONDecoder().decode(SMSMessagesResponsePayload.self, from: payloadData) {
                Task { @MainActor in
                    DashboardState.shared.handleSMSMessages(resp)
                }
            }
            
        case .smsSendStatus:
            guard isAuth else { return }
            if let payloadData = envelope.payload.data(using: .utf8),
               let status = try? JSONDecoder().decode(SMSSendStatusPayload.self, from: payloadData) {
                Task { @MainActor in
                    DashboardState.shared.handleSMSSendStatus(status)
                }
            }
            
        case .fileStart:
            guard isAuth else {
                print("[NacMac-Security] Blocked unauthorized .fileStart from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8),
               let start = try? JSONDecoder().decode(FileStartPayload.self, from: payloadData) {
                _ = FileTransferManager.shared.handleFileStart(start)
            }
            
        case .fileChunk:
            guard isAuth else {
                print("[NacMac-Security] Blocked unauthorized .fileChunk from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8),
               let chunk = try? JSONDecoder().decode(FileChunkPayload.self, from: payloadData) {
                _ = FileTransferManager.shared.handleFileChunk(chunk)
            }
            
        case .fileEnd:
            guard isAuth else {
                print("[NacMac-Security] Blocked unauthorized .fileEnd from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8),
               let end = try? JSONDecoder().decode(FileEndPayload.self, from: payloadData) {
                _ = FileTransferManager.shared.handleFileEnd(end)
            }
            
        case .fileCancel:
            guard isAuth else {
                print("[NacMac-Security] Blocked unauthorized .fileCancel from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8),
               let cancel = try? JSONDecoder().decode(FileCancelPayload.self, from: payloadData) {
                FileTransferManager.shared.handleFileCancel(cancel)
            }
            
        default:
            print("[NacMac-Network] Received unhandled message type: \(envelope.type)")
        }
    }
    
    private func handlePairRequest(_ payloadString: String, from conn: NWConnection) {
        guard let data = payloadString.data(using: .utf8),
              let req = try? JSONDecoder().decode(PairRequestPayload.self, from: data) else {
            return
        }
        
        let success = PairingManager.shared.validatePairRequest(req)
        let resp = PairResponsePayload(
            success: success,
            macName: PairingManager.shared.macName,
            message: success ? "Pairing verified" : "Invalid secret key",
            macId: PairingManager.shared.macId
        )
        
        if let respData = try? JSONEncoder().encode(resp), let respJson = String(data: respData, encoding: .utf8) {
            sendEnvelopeToConnection(NacMacEnvelope(type: .pairResponse, payload: respJson), conn: conn)
        }
        
        if success {
            let connId = ObjectIdentifier(conn)
            pendingConnections.removeValue(forKey: connId)
            
            // If already connected with an older connection for this androidId, replace it
            if let oldConn = activeConnections[req.androidId], oldConn !== conn {
                print("[NacMac-Network] Replacing existing connection for device: \(req.androidId)")
                let oldId = ObjectIdentifier(oldConn)
                connectionDevices.removeValue(forKey: oldId)
                oldConn.cancel()
            }
            
            activeConnections[req.androidId] = conn
            connectionDevices[connId] = req.androidId
            deviceNames[req.androidId] = req.deviceName
            deviceEndpoints[req.androidId] = endpointToString(conn.endpoint)
            authenticatedDevices.insert(req.androidId)
            
            print("[NacMac-Network] Successfully paired with: \(req.deviceName) (\(req.androidId))")
            refreshConnectionState()
            startHeartbeat()
        } else {
            print("[NacMac-Security] Authentication failed for: \(req.deviceName) (\(req.androidId))")
        }
    }
    
    // MARK: - Outbound Transmission
    
    public func sendEnvelope(_ envelope: NacMacEnvelope, to deviceId: String? = nil, completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            if let targetId = deviceId {
                if let conn = self.activeConnections[targetId] {
                    self.sendEnvelopeToConnection(envelope, conn: conn, completion: completion)
                } else {
                    print("[NacMac-Network] Target device not connected: \(targetId)")
                    completion?()
                }
            } else {
                guard !self.activeConnections.isEmpty else {
                    completion?()
                    return
                }
                let group = DispatchGroup()
                for conn in self.activeConnections.values {
                    group.enter()
                    self.sendEnvelopeToConnection(envelope, conn: conn) {
                        group.leave()
                    }
                }
                if let comp = completion {
                    group.notify(queue: self.queue, execute: comp)
                }
            }
        }
    }
    
    public func broadcastEnvelope(_ envelope: NacMacEnvelope, excluding excludedDeviceId: String? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            for (id, conn) in self.activeConnections {
                if let excluded = excludedDeviceId, id == excluded {
                    continue
                }
                self.sendEnvelopeToConnection(envelope, conn: conn)
            }
        }
    }
    
    private func sendEnvelopeToConnection(_ envelope: NacMacEnvelope, conn: NWConnection, completion: (@Sendable () -> Void)? = nil) {
        guard let payloadData = try? JSONEncoder().encode(envelope) else {
            completion?()
            return
        }
        
        var length = UInt32(payloadData.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(payloadData)
        
        conn.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                print("[NacMac-Network] Send error: \(error)")
            }
            completion?()
        })
    }
    
    public func sendFile(at url: URL, to deviceId: String? = nil) {
        FileTransferManager.shared.sendFile(at: url) { [weak self] envelope, chunkCompleted in
            self?.sendEnvelope(envelope, to: deviceId, completion: chunkCompleted)
        }
    }
    
    // MARK: - Heartbeat Keepalive
    
    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.sendEnvelope(NacMacEnvelope(type: .heartbeatPing, payload: "{}"))
        }
        timer.resume()
        heartbeatTimer = timer
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
    
    private func endpointToString(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return "\(endpoint)"
        }
    }
    
    private func refreshConnectionState() {
        let devices = activeConnections.keys.map { id in
            ConnectedDeviceInfo(
                deviceId: id,
                deviceName: deviceNames[id] ?? "Android Device",
                ip: deviceEndpoints[id] ?? "Local Wi-Fi"
            )
        }
        
        if devices.isEmpty {
            updateState(.listening(port: port.rawValue))
        } else if devices.count == 1, let first = devices.first {
            updateState(.connected(deviceName: first.deviceName, ip: first.ip))
        } else {
            updateState(.multiConnected(devices: devices))
        }
    }
    
    private func updateState(_ state: ConnectionState) {
        currentState = state
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.connectionStateChanged(to: state)
        }
    }
}
