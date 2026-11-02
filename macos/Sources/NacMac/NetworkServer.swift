import Foundation
import Network

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case listening(port: UInt16)
    case connected(deviceName: String, ip: String)
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
    private var activeConnection: NWConnection?
    private var isConnectionAuthenticated: Bool = false
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
            self?.stopHeartbeat()
            self?.activeConnection?.cancel()
            self?.activeConnection = nil
            self?.listener?.cancel()
            self?.listener = nil
            self?.netService?.stop()
            self?.netService = nil
            self?.updateState(.disconnected)
        }
    }
    
    public func disconnectPeer() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopHeartbeat()
            self.activeConnection?.cancel()
            self.activeConnection = nil
            self.handleDisconnection()
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
                    self.updateState(.listening(port: self.port.rawValue))
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
            
            // If already connected, cancel old connection or prioritize new reconnect
            if let active = self.activeConnection {
                print("[NacMac-Network] Replacing existing connection with incoming reconnect")
                active.cancel()
            }
            
            self.activeConnection = conn
            self.isConnectionAuthenticated = false
            
            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    let remoteEndpoint = conn.endpoint
                    print("[NacMac-Network] Inbound socket connected from \(remoteEndpoint)")
                    self.readNextMessage(from: conn)
                    self.startHeartbeat()
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
    
    private func handleDisconnection(for conn: NWConnection? = nil) {
        guard let active = self.activeConnection else {
            // No active connection or server is already stopped; ignore redundant/stale disconnections
            return
        }
        if let conn = conn, conn !== active {
            // Disconnection was from a superseded or stale connection; do not affect active connection.
            return
        }
        stopHeartbeat()
        activeConnection = nil
        isConnectionAuthenticated = false
        print("[NacMac-Network] Peer disconnected. Standing by for auto-reconnect...")
        updateState(.listening(port: port.rawValue))
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
            guard length > 0 && length < 100 * 1024 * 1024 else { // sanity cap 100MB
                print("[NacMac-Network] Invalid message length: \(length)")
                self.handleDisconnection(for: conn)
                return
            }
            
            self.readPayload(from: conn, length: Int(length))
        }
    }
    
    private func readPayload(from conn: NWConnection, length: Int) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                print("[NacMac-Network] Read payload error: \(error)")
                self.handleDisconnection(for: conn)
                return
            }
            
            if let payloadData = data, payloadData.count == length {
                self.processInboundData(payloadData)
            }
            
            if !isComplete {
                self.readNextMessage(from: conn)
            } else {
                self.handleDisconnection(for: conn)
            }
        }
    }
    
    // MARK: - Message Dispatching
    
    private func processInboundData(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(NacMacEnvelope.self, from: data) else {
            print("[NacMac-Network] Failed to decode envelope")
            return
        }
        
        switch envelope.type {
        case .pairRequest:
            handlePairRequest(envelope.payload)
            
        case .heartbeatPing:
            sendEnvelope(NacMacEnvelope(type: .heartbeatPong, payload: "{}"))
            
        case .heartbeatPong:
            // Heartbeat acknowledged
            break
            
        case .notification:
            guard isConnectionAuthenticated else {
                print("[NacMac-Security] Blocked unauthorized .notification from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8) {
                do {
                    let notif = try JSONDecoder().decode(NotificationPayload.self, from: payloadData)
                    NotificationManager.shared.deliverNotification(notif)
                } catch {
                    print("[NacMac-Notification] Error decoding notification payload: \(error)")
                }
            }
            
        case .notificationDismissed:
            guard isConnectionAuthenticated else {
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
            
        case .fileStart:
            guard isConnectionAuthenticated else {
                print("[NacMac-Security] Blocked unauthorized .fileStart from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8),
               let start = try? JSONDecoder().decode(FileStartPayload.self, from: payloadData) {
                _ = FileTransferManager.shared.handleFileStart(start)
            }
            
        case .fileChunk:
            guard isConnectionAuthenticated else {
                print("[NacMac-Security] Blocked unauthorized .fileChunk from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8),
               let chunk = try? JSONDecoder().decode(FileChunkPayload.self, from: payloadData) {
                _ = FileTransferManager.shared.handleFileChunk(chunk)
            }
            
        case .fileEnd:
            guard isConnectionAuthenticated else {
                print("[NacMac-Security] Blocked unauthorized .fileEnd from unauthenticated connection")
                return
            }
            if let payloadData = envelope.payload.data(using: .utf8),
               let end = try? JSONDecoder().decode(FileEndPayload.self, from: payloadData) {
                _ = FileTransferManager.shared.handleFileEnd(end)
            }
            
        case .fileCancel:
            guard isConnectionAuthenticated else {
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
    
    private func handlePairRequest(_ payloadString: String) {
        guard let data = payloadString.data(using: .utf8),
              let req = try? JSONDecoder().decode(PairRequestPayload.self, from: data) else {
            return
        }
        
        let success = PairingManager.shared.validatePairRequest(req)
        self.isConnectionAuthenticated = success
        let resp = PairResponsePayload(
            success: success,
            macName: PairingManager.shared.macName,
            message: success ? "Pairing verified" : "Invalid secret key"
        )
        
        if let respData = try? JSONEncoder().encode(resp), let respJson = String(data: respData, encoding: .utf8) {
            sendEnvelope(NacMacEnvelope(type: .pairResponse, payload: respJson))
        }
        
        if success {
            print("[NacMac-Network] Successfully paired with: \(req.deviceName) (\(req.androidId))")
            updateState(.connected(deviceName: req.deviceName, ip: "Remote Peer"))
        } else {
            print("[NacMac-Security] Authentication failed for: \(req.deviceName) (\(req.androidId))")
        }
    }
    
    // MARK: - Outbound Transmission
    
    public func sendEnvelope(_ envelope: NacMacEnvelope) {
        queue.async { [weak self] in
            guard let self = self, let conn = self.activeConnection else { return }
            guard let payloadData = try? JSONEncoder().encode(envelope) else { return }
            
            var length = UInt32(payloadData.count).bigEndian
            var packet = Data(bytes: &length, count: 4)
            packet.append(payloadData)
            
            conn.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    print("[NacMac-Network] Send error: \(error)")
                }
            })
        }
    }
    
    public func sendFile(at url: URL) {
        FileTransferManager.shared.sendFile(at: url) { [weak self] envelope in
            self?.sendEnvelope(envelope)
        }
    }
    
    // MARK: - Heartbeat Keepalive
    
    private func startHeartbeat() {
        stopHeartbeat()
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
    
    private func updateState(_ state: ConnectionState) {
        currentState = state
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.connectionStateChanged(to: state)
        }
    }
}
