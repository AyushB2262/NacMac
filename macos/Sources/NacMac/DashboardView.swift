import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Dashboard Observable State
@MainActor
final class DashboardState: ObservableObject {
    static let shared = DashboardState()
    
    @Published var selectedTab: String = "Devices"
    @Published var isConnected: Bool = false
    @Published var connectedDeviceName: String = "No Paired Device"
    @Published var pairedPath: String = "~/.nacmac/paired_devices.json"
    @Published var autoConnect: Bool = true
    @Published var localIP: String = "127.0.0.1"
    @Published var port: Int = 52840
    @Published var qrCodeImage: NSImage? = nil
    
    // Multi-Device Lists
    @Published var connectedDevices: [ConnectedDeviceInfo] = []
    @Published var pairedDevices: [PairedDeviceRecord] = []
    @Published var targetSendDevice: String = "ALL" // "ALL" or specific deviceId
    
    // SMS Hub State
    @Published var smsThreads: [SMSThreadItem] = []
    @Published var selectedSMSDeviceId: String? = nil
    @Published var selectedThreadId: Int64? = nil
    @Published var threadMessages: [SMSMessageItem] = []
    @Published var smsSearchText: String = ""
    @Published var isSmsLoading: Bool = false
    @Published var smsStatusMessage: String = ""
    
    // Transfer Queue
    @Published var activeTransfer: ActiveTransferProgress? = nil
    @Published var completedTransfers: [CompletedTransfer] = []
    
    // Notifications
    @Published var notifications: [MirroredNotifItem] = []
    
    // Activity Logs
    @Published var activityLogs: [ActivityLogEntry] = [
        ActivityLogEntry(message: "NacMac service daemon started on port 52840", type: "info"),
        ActivityLogEntry(message: "mDNS Bonjour service _nacmac._tcp published", type: "info")
    ]
    
    private init() {
        refreshState()
    }
    
    func refreshState() {
        let addresses = PairingManager.shared.getLocalIPAddresses()
        self.localIP = addresses.first ?? "127.0.0.1"
        self.port = Int(NetworkServer.shared.port.rawValue)
        
        let qrStr = PairingManager.shared.generateQRJSONString()
        self.qrCodeImage = PairingManager.shared.generateQRImage(from: qrStr)
        
        self.pairedDevices = PairingManager.shared.getPairedDevices()
        self.connectedDevices = NetworkServer.shared.getConnectedDevices()
        
        if !connectedDevices.isEmpty {
            self.isConnected = true
            if connectedDevices.count == 1 {
                self.connectedDeviceName = connectedDevices[0].deviceName
            } else {
                self.connectedDeviceName = "\(connectedDevices.count) Devices Connected"
            }
        } else if let firstPaired = pairedDevices.first {
            self.connectedDeviceName = firstPaired.deviceName
            self.isConnected = false
        } else {
            self.connectedDeviceName = "No Device Paired"
            self.isConnected = false
        }
    }
    
    func disconnect(deviceId: String? = nil) {
        if let devId = deviceId {
            NetworkServer.shared.disconnectPeer(deviceId: devId)
            PairingManager.shared.unpair(androidId: devId)
            addLog("Device \(devId) disconnected and unpaired.", type: "warning")
        } else {
            PairingManager.shared.unpair()
            NetworkServer.shared.disconnectPeer()
            self.connectedDeviceName = "No Device Paired"
            self.isConnected = false
            addLog("All devices unpaired and sockets disconnected.", type: "warning")
        }
        refreshState()
    }
    
    func dismissNotification(id: String) {
        let notifItem = notifications.first { $0.id == id }
        notifications.removeAll { $0.id == id }
        NotificationManager.shared.dismissNotification(id: id)
        let dismissObj = NotificationDismissPayload(id: id, deviceId: notifItem?.deviceId)
        if let data = try? JSONEncoder().encode(dismissObj),
           let payloadStr = String(data: data, encoding: .utf8) {
            let envelope = NacMacEnvelope(type: .notificationDismissed, payload: payloadStr)
            NetworkServer.shared.sendEnvelope(envelope, to: notifItem?.deviceId)
        }
        addLog("Dismissed notification: \(id)", type: "info")
    }
    
    func sendNotificationAction(notificationKey: String, actionIndex: Int, replyText: String?, deviceId: String?) {
        NotificationManager.shared.sendNotificationAction(
            notificationKey: notificationKey,
            actionIndex: actionIndex,
            replyText: replyText,
            deviceId: deviceId
        )
    }
    
    func addNotification(from payload: NotificationPayload) {
        let isFile = payload.packageName == "com.nactore.nacmac.file" || payload.filePath != nil
        let item = MirroredNotifItem(
            id: payload.id,
            app: payload.appName,
            sender: payload.title,
            body: payload.body,
            icon: isFile ? "doc.fill" : (payload.packageName.contains("whatsapp") ? "message.fill" : "bell.fill"),
            canReply: payload.hasReplyAction || (payload.actions?.contains { $0.isReply } == true),
            filePath: payload.filePath,
            originDevice: payload.deviceName,
            deviceId: payload.deviceId,
            actions: payload.actions
        )
        notifications.removeAll { $0.id == payload.id }
        notifications.insert(item, at: 0)
        let originMsg = payload.deviceName != nil ? " (via \(payload.deviceName!))" : ""
        addLog("Received notification from \(payload.appName): \(payload.title)\(originMsg)", type: "success")
    }
    
    func sendFile(at url: URL) {
        let target = (targetSendDevice == "ALL" ? nil : targetSendDevice)
        NetworkServer.shared.sendFile(at: url, to: target)
        let name = url.lastPathComponent
        completedTransfers.insert(CompletedTransfer(name: name, sizeString: "Ready", direction: "Sent", filePath: url.path), at: 0)
        let targetMsg = target != nil ? " to selected device" : " to all online phones"
        addLog("Initiated file transfer: \(name)\(targetMsg)", type: "info")
    }
    
    // MARK: - SMS Messaging Actions
    
    func requestSMSConversations() {
        var target = (targetSendDevice == "ALL" ? nil : targetSendDevice)
        if target == nil {
            target = connectedDevices.first?.deviceId
        }
        guard let resolvedTarget = target else {
            isSmsLoading = false
            return
        }
        let req = SMSConversationsRequestPayload(limit: 50)
        if let data = try? JSONEncoder().encode(req),
           let str = String(data: data, encoding: .utf8) {
            isSmsLoading = true
            NetworkServer.shared.sendEnvelope(NacMacEnvelope(type: .smsConversationsRequest, payload: str), to: resolvedTarget)
        }
    }
    
    func selectSMSThread(threadId: Int64, toDevice: String? = nil) {
        self.selectedThreadId = threadId
        let target = toDevice ?? selectedSMSDeviceId ?? (targetSendDevice == "ALL" ? nil : targetSendDevice)
        guard let resolvedTarget = target ?? connectedDevices.first?.deviceId else { return }
        let req = SMSMessagesRequestPayload(threadId: threadId, limit: 100)
        if let data = try? JSONEncoder().encode(req),
           let str = String(data: data, encoding: .utf8) {
            NetworkServer.shared.sendEnvelope(NacMacEnvelope(type: .smsMessagesRequest, payload: str), to: resolvedTarget)
        }
    }
    
    func sendSMS(recipient: String, message: String, threadId: Int64? = nil) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var target = (targetSendDevice == "ALL" ? nil : targetSendDevice)
        if target == nil {
            target = selectedSMSDeviceId ?? connectedDevices.first?.deviceId
        }
        guard let resolvedTarget = target else {
            addLog("No connected phone to send SMS", type: "warning")
            return
        }
        let req = SMSSendPayload(recipient: recipient, message: message, threadId: threadId)
        if let data = try? JSONEncoder().encode(req),
           let str = String(data: data, encoding: .utf8) {
            NetworkServer.shared.sendEnvelope(NacMacEnvelope(type: .smsSend, payload: str), to: resolvedTarget)
            let optimistic = SMSMessageItem(
                messageId: Int64(Date().timeIntervalSince1970 * 1000),
                threadId: threadId ?? 0,
                address: recipient,
                body: message,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                isIncoming: false
            )
            self.threadMessages.append(optimistic)
            addLog("Sent SMS to \(recipient)", type: "info")
        }
    }
    
    func handleSMSConversations(_ resp: SMSConversationsResponsePayload) {
        self.smsThreads = resp.threads
        self.isSmsLoading = false
        if let devId = resp.deviceId {
            self.selectedSMSDeviceId = devId
        }
        if self.selectedThreadId == nil, let first = resp.threads.first {
            selectSMSThread(threadId: first.threadId, toDevice: resp.deviceId)
        }
    }
    
    func handleSMSMessages(_ resp: SMSMessagesResponsePayload) {
        if self.selectedThreadId == resp.threadId {
            self.threadMessages = resp.messages
        }
    }
    
    func handleSMSSendStatus(_ status: SMSSendStatusPayload) {
        self.smsStatusMessage = status.message
        if status.success, let tid = status.threadId {
            selectSMSThread(threadId: tid, toDevice: selectedSMSDeviceId)
        }
    }
    
    func addLog(_ message: String, type: String = "info") {
        let entry = ActivityLogEntry(message: message, type: type)
        activityLogs.insert(entry, at: 0)
    }
}

struct CompletedTransfer: Identifiable {
    let id = UUID()
    let name: String
    let sizeString: String
    let direction: String
    let filePath: String?
    
    init(name: String, sizeString: String, direction: String, filePath: String? = nil) {
        self.name = name
        self.sizeString = sizeString
        self.direction = direction
        self.filePath = filePath
    }
}

struct MirroredNotifItem: Identifiable {
    let id: String
    let app: String
    let sender: String
    let body: String
    let icon: String
    let canReply: Bool
    let filePath: String?
    let originDevice: String?
    let deviceId: String?
    let actions: [NotificationActionInfo]?
    
    init(id: String, app: String, sender: String, body: String, icon: String, canReply: Bool, filePath: String? = nil, originDevice: String? = nil, deviceId: String? = nil, actions: [NotificationActionInfo]? = nil) {
        self.id = id
        self.app = app
        self.sender = sender
        self.body = body
        self.icon = icon
        self.canReply = canReply
        self.filePath = filePath
        self.originDevice = originDevice
        self.deviceId = deviceId
        self.actions = actions
    }
}

struct ActivityLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let type: String
    
    var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Main Dashboard View
public struct DashboardView: View {
    public static let nacmacOrange = Color(red: 234/255.0, green: 88/255.0, blue: 12/255.0)

    @AppStorage("nacmac_theme_appearance") private var appearanceMode: String = "dark"
    @StateObject private var state = DashboardState.shared
    @State private var isTargeted: Bool = false
    @State private var isShowingLargeQR: Bool = false
    @State private var messageInputText: String = ""
    
    public init() {}
    
    public var body: some View {
        HStack(spacing: 0) {
            // MARK: - Left Sidebar
            sidebarView
                .frame(width: 200)
                .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // MARK: - Main Content Switcher
            VStack(alignment: .leading, spacing: 0) {
                switch state.selectedTab {
                case "Messages":
                    messagesView
                case "File Hub":
                    fileHubView
                case "Notifications":
                    notificationsView
                case "Activity Log":
                    activityLogView
                case "Settings":
                    settingsView
                default:
                    devicesDashboardView
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: state.selectedTab)
        }
        .frame(minWidth: 960, minHeight: 640)
        .overlay {
            if isShowingLargeQR, let qr = state.qrCodeImage {
                ZStack {
                    Color.black.opacity(0.55)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                                isShowingLargeQR = false
                            }
                        }
                    
                    VStack(spacing: 0) {
                        Image(nsImage: qr)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 320, height: 320)
                            .padding(22)
                            .background(Color.white)
                            .cornerRadius(18)
                            .shadow(color: Color.black.opacity(0.35), radius: 28, x: 0, y: 12)
                    }
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .onTapGesture {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                            isShowingLargeQR = false
                        }
                    }
                }
            }
        }
        .onAppear {
            state.refreshState()
        }
        .preferredColorScheme(appearanceMode == "dark" ? .dark : (appearanceMode == "light" ? .light : nil))
        .tint(DashboardView.nacmacOrange)
        .accentColor(DashboardView.nacmacOrange)
    }
    
    // MARK: - Sidebar
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer().frame(height: 24)
            
            HStack(spacing: 10) {
                if let logoImg = Bundle.main.url(forResource: "nacmac-logo", withExtension: "png").flatMap({ NSImage(contentsOf: $0) })
                    ?? NSImage(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/nacmac-logo.png")) {
                    Image(nsImage: logoImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                        .cornerRadius(6)
                }
                Text("NacMac")
                    .font(.system(size: 15, weight: .bold))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            
            sidebarButton(title: "Devices", icon: "iphone", id: "Devices")
            sidebarButton(title: "Messages", icon: "bubble.left.and.bubble.right", id: "Messages")
            sidebarButton(title: "File Hub", icon: "folder", id: "File Hub")
            sidebarButton(title: "Notifications", icon: "bell", id: "Notifications")
            sidebarButton(title: "Activity Log", icon: "list.bullet", id: "Activity Log")
            sidebarButton(title: "Settings", icon: "gearshape", id: "Settings")
            
            Spacer()
            
            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    appearanceMode = (appearanceMode == "dark") ? "light" : "dark"
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: appearanceMode == "dark" ? "sun.max.fill" : "moon.stars.fill")
                        .foregroundColor(DashboardView.nacmacOrange)
                        .font(.system(size: 13))
                    Text(appearanceMode == "dark" ? "Light Mode" : "Dark Mode")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Button(action: {
                if let url = URL(string: "https://nactore.com") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                    Text("How it works")
                        .font(.system(size: 13, weight: .regular))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            
            Spacer().frame(height: 12)
        }
    }
    
    private func sidebarButton(title: String, icon: String, id: String) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                state.selectedTab = id
                if id == "Messages" && state.smsThreads.isEmpty && !state.connectedDevices.isEmpty {
                    state.requestSMSConversations()
                }
            }
        }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: state.selectedTab == id ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(state.selectedTab == id ? Color.accentColor.opacity(0.15) : Color.clear)
            .cornerRadius(8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(state.selectedTab == id ? .accentColor : .primary)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: state.selectedTab)
    }
    
    // MARK: - Main Tab: Devices (Image #2)
    private var devicesDashboardView: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerView
            
            HStack(alignment: .top, spacing: 16) {
                myDevicesCard
                pairNewDeviceCard
            }
            
            HStack(alignment: .top, spacing: 16) {
                fileDropCard
                transferQueueCard
            }
            
            nativeMirroringSection
            
            Spacer(minLength: 8)
            
            footerView
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
    
    // MARK: - Header
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("NacMac")
                .font(.system(size: 22, weight: .bold, design: .default))
                .tracking(-0.35)
            Text("Android Connectivity")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - My Devices Card
    private var myDevicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("My Devices (\(state.connectedDevices.count) Online)")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                Spacer()
                if !state.connectedDevices.isEmpty || !state.pairedDevices.isEmpty {
                    Button(action: {
                        state.disconnect()
                    }) {
                        Text("Disconnect All")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            if state.connectedDevices.isEmpty && state.pairedDevices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Paired Device")
                            .font(.system(size: 14, weight: .bold))
                        Text("Scan QR code to pair your first phone")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
            } else {
                VStack(spacing: 8) {
                    // Online connected devices
                    ForEach(state.connectedDevices) { dev in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: 26))
                                .foregroundColor(DashboardView.nacmacOrange)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("\(dev.deviceName) - Online")
                                        .font(.system(size: 13, weight: .bold))
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                }
                                Text("\(dev.ip) • ID: \(dev.deviceId)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                state.disconnect(deviceId: dev.deviceId)
                            }) {
                                Text("Disconnect")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }
                    
                    // Offline paired devices
                    ForEach(state.pairedDevices.filter { p in !state.connectedDevices.contains { $0.deviceId == p.androidId } }, id: \.androidId) { paired in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone.slash")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("\(paired.deviceName) - Offline")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.secondary)
                                    Circle()
                                        .fill(Color.secondary)
                                        .frame(width: 7, height: 7)
                                }
                                Text("ID: \(paired.androidId)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                state.disconnect(deviceId: paired.androidId)
                            }) {
                                Text("Unpair")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Pair New Device Card
    private var pairNewDeviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair New Device")
                .font(.system(size: 14, weight: .semibold))
                .tracking(-0.2)
            
            HStack(spacing: 14) {
                if let qr = state.qrCodeImage {
                    Image(nsImage: qr)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 68, height: 68)
                        .padding(4)
                        .background(Color.white)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                                isShowingLargeQR = true
                            }
                        }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 68, height: 68)
                        .cornerRadius(8)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Auto-Connect")
                            .font(.system(size: 13, weight: .medium))
                        Toggle("", isOn: $state.autoConnect)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    
                    Text("Background reconnection active")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Text("mDNS / Bonjour")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DashboardView.nacmacOrange.opacity(0.15))
                        .foregroundColor(DashboardView.nacmacOrange)
                        .cornerRadius(4)
                }
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(appearanceMode == "dark" ? 0.22 : 0.04), radius: 8, x: 0, y: 3)
        }
        .frame(width: 320)
    }
    
    // MARK: - File Transfer Hub Drop Card
    private var fileDropCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("File Transfer & Progress Hub")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                Spacer()
                if state.connectedDevices.count > 1 {
                    HStack(spacing: 4) {
                        Text("Target:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Picker("", selection: $state.targetSendDevice) {
                            Text("Send to All").tag("ALL")
                            ForEach(state.connectedDevices) { dev in
                                Text(dev.deviceName).tag(dev.deviceId)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                }
            }
            
            Button(action: {
                selectFileManually()
            }) {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.secondary)
                    
                    Text("Drag & Drop Files Here")
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text(state.connectedDevices.count > 1 ? "Routes to: \(state.targetSendDevice == "ALL" ? "All Online Phones" : "Selected Phone")" : "Direct Wi-Fi transfer")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 28)
                .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isTargeted ? Color.accentColor : Color.gray.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
            }
            .buttonStyle(.plain)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url {
                            DispatchQueue.main.async {
                                state.sendFile(at: url)
                            }
                        }
                    }
                }
                return true
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Transfer Queue Card
    private var transferQueueCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transfer Queue")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                
                Spacer()
                
                Button(action: {
                    let dir = FileTransferManager.shared.downloadDirectory
                    NSWorkspace.shared.open(dir)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text("Open Downloads")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DashboardView.nacmacOrange.opacity(0.12))
                    .foregroundColor(DashboardView.nacmacOrange)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                if state.activeTransfer == nil && state.completedTransfers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.system(size: 26))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No Active Transfers")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("Drop files above to stream directly to Android")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    if let active = state.activeTransfer {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(active.filename) (\(String(format: "%.1f", Double(active.totalBytes) / (1024 * 1024))) MB)")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text("\(Int(active.percent))%")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            
                            ProgressView(value: active.percent, total: 100)
                                .progressViewStyle(.linear)
                            
                            HStack {
                                Text("Active speed:")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                let mbps = active.bytesPerSecond / (1024 * 1024)
                                Text("\(String(format: "%.1f", mbps)) MB/s")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                        Divider()
                    }
                    
                    ForEach(state.completedTransfers) { item in
                        Button(action: {
                            if let path = item.filePath, FileManager.default.fileExists(atPath: path) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } else {
                                NSWorkspace.shared.open(FileTransferManager.shared.downloadDirectory)
                            }
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: item.direction == "Received" ? "arrow.down.doc.fill" : "arrow.up.doc.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 14))
                                
                                Text("\(item.name) (\(item.sizeString)) - \(item.direction)")
                                    .font(.system(size: 12, weight: .regular))
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Image(systemName: "folder")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 11))
                                
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 14))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to reveal in Finder")
                    }
                }
                
                Spacer()
                
                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        Text("Integrity Check: SHA-256 Verified")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(6)
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(appearanceMode == "dark" ? 0.22 : 0.04), radius: 8, x: 0, y: 3)
        }
        .frame(width: 320)
    }
    
    // MARK: - Native Mirroring Section
    private var nativeMirroringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Native Mirroring Section")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                Spacer()
                if !state.notifications.isEmpty {
                    Button("Clear All") {
                        state.notifications.removeAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
            }
            
            if state.notifications.isEmpty {
                HStack {
                    Spacer()
                    Text("No active notifications from phone")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 16)
                    Spacer()
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(appearanceMode == "dark" ? 0.22 : 0.04), radius: 8, x: 0, y: 3)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(state.notifications) { notif in
                            Button(action: {
                                if let path = notif.filePath, FileManager.default.fileExists(atPath: path) {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                } else if notif.app == "NacMac" && (notif.sender.contains("File") || notif.body.contains("saved to Downloads")) {
                                    NSWorkspace.shared.open(FileTransferManager.shared.downloadDirectory)
                                }
                            }) {
                                HStack(alignment: .top, spacing: 10) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(DashboardView.nacmacOrange.opacity(0.15))
                                            .frame(width: 34, height: 34)
                                        Image(systemName: notif.icon)
                                            .foregroundColor(DashboardView.nacmacOrange)
                                            .font(.system(size: 15))
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(notif.app)
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                            Spacer()
                                            Button(action: {
                                                state.dismissNotification(id: notif.id)
                                            }) {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundColor(.secondary)
                                                    .padding(4)
                                                    .background(Color.gray.opacity(0.15))
                                                    .clipShape(Circle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        
                                        if !notif.sender.isEmpty && notif.sender != notif.app {
                                            Text(notif.sender)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                        }
                                        
                                        Text(notif.body)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(10)
                                .frame(width: 260)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(appearanceMode == "dark" ? 0.22 : 0.04), radius: 8, x: 0, y: 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
    
    // MARK: - Footer View
    private var footerView: some View {
        HStack {
            Button(action: {
                if let url = URL(string: "https://nactore.com") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Local Peer-to-Peer Encryption with SHA-256")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 4)
    }
    
    // MARK: - Tab: File Hub
    private var fileHubView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("File Hub")
                        .font(.system(size: 20, weight: .bold))
                    Text("Bidirectional chunked transfer engine")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: {
                    let url = FileTransferManager.shared.downloadDirectory
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                }) {
                    Label("Open Downloads Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
            
            fileDropCard
                .frame(height: 180)
            
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Transferred Files History")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    if !state.completedTransfers.isEmpty {
                        Button("Clear History") {
                            state.completedTransfers.removeAll()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }
                }
                
                List {
                    ForEach(state.completedTransfers) { item in
                        Button(action: {
                            if let path = item.filePath, FileManager.default.fileExists(atPath: path) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } else {
                                NSWorkspace.shared.open(FileTransferManager.shared.downloadDirectory)
                            }
                        }) {
                            HStack {
                                Image(systemName: item.direction == "Received" ? "arrow.down.doc.fill" : "arrow.up.doc.fill")
                                    .foregroundColor(DashboardView.nacmacOrange)
                                Text(item.name)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(item.sizeString)
                                    .foregroundColor(.secondary)
                                Text(item.direction)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(DashboardView.nacmacOrange.opacity(0.12))
                                    .foregroundColor(DashboardView.nacmacOrange)
                                    .cornerRadius(4)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Click to reveal in Finder")
                    }
                }
                .listStyle(.inset)
                .cornerRadius(10)
            }
            
            Spacer()
        }
        .padding(24)
    }
    
    // MARK: - Tab: Notifications
    private var notificationsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mirrored Notifications")
                        .font(.system(size: 20, weight: .bold))
                    Text("Real-time notifications forwarded from Android companion")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !state.notifications.isEmpty {
                    Button("Dismiss All") {
                        state.notifications.removeAll()
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            List {
                ForEach(state.notifications) { notif in
                    Button(action: {
                        if let path = notif.filePath, FileManager.default.fileExists(atPath: path) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } else if notif.app == "NacMac" && (notif.sender.contains("File") || notif.body.contains("saved to Downloads")) {
                            NSWorkspace.shared.open(FileTransferManager.shared.downloadDirectory)
                        }
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: notif.icon)
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(DashboardView.nacmacOrange)
                                .cornerRadius(8)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notif.app)
                                    .font(.system(size: 13, weight: .bold))
                                Text("\(notif.sender): \(notif.body)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if notif.filePath != nil {
                                Image(systemName: "folder")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 13))
                            }
                            Button("Dismiss") {
                                state.dismissNotification(id: notif.id)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to view in Finder")
                }
            }
            .listStyle(.inset)
            .cornerRadius(10)
            
            Spacer()
        }
        .padding(24)
    }
    
    // MARK: - Tab: Activity Log
    private var activityLogView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity & Diagnostics")
                        .font(.system(size: 20, weight: .bold))
                    Text("Live protocol framing, mDNS, and socket telemetry")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Clear Log") {
                    state.activityLogs.removeAll()
                }
                .buttonStyle(.bordered)
            }
            
            List {
                ForEach(state.activityLogs) { log in
                    HStack(spacing: 8) {
                        Text(log.timeString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        Circle()
                            .fill(log.type == "warning" ? Color.orange : (log.type == "success" ? Color.green : Color.blue))
                            .frame(width: 6, height: 6)
                        Text(log.message)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            .cornerRadius(10)
            
            Spacer()
        }
        .padding(24)
    }
    
    // MARK: - Tab: Settings
    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings")
                    .font(.system(size: 20, weight: .bold))
                Text("Network configuration and pairing credentials")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Form {
                Section(header: Text("Appearance & Theme").font(.headline)) {
                    Picker("Theme Mode:", selection: $appearanceMode) {
                        Text("Dark Mode").tag("dark")
                        Text("Light Mode").tag("light")
                        Text("Follow System").tag("system")
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Network Configuration").font(.headline)) {
                    HStack {
                        Text("Service Port:")
                        Spacer()
                        Text("\(state.port)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Active Interface:")
                        Spacer()
                        Text("\(state.localIP)")
                            .foregroundColor(.secondary)
                    }
                    Toggle("Auto-reconnect via mDNS / Bonjour", isOn: $state.autoConnect)
                }
                
                Section(header: Text("Security & Storage").font(.headline)) {
                    HStack {
                        Text("Paired Keys Storage:")
                        Spacer()
                        Text("~/.nacmac/paired_device.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Button("Reset All Pairing Keys & Disconnect") {
                        state.disconnect()
                    }
                    .foregroundColor(.red)
                }
            }
            .formStyle(.grouped)
            
            Spacer()
        }
        .padding(24)
    }
    
    // MARK: - Messages Tab View (SMS / RCS Messaging Hub)
    private var messagesView: some View {
        HStack(spacing: 0) {
            // Left Pane: Conversation Threads
            VStack(spacing: 0) {
                // Header with search & refresh
                HStack {
                    Text("Messages")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Button(action: {
                        state.requestSMSConversations()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh SMS from Phone")
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 8)
                
                // Device selector if multi-device
                if state.connectedDevices.count > 1 {
                    HStack {
                        Text("Phone:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Picker("", selection: $state.targetSendDevice) {
                            ForEach(state.connectedDevices) { dev in
                                Text(dev.deviceName).tag(dev.deviceId)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: state.targetSendDevice) { _ in
                            state.requestSMSConversations()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
                
                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    TextField("Search conversations...", text: $state.smsSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(NSColor.textBackgroundColor).opacity(0.6))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                
                Divider()
                
                // Threads list
                if state.smsThreads.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(state.isSmsLoading ? "Loading messages..." : "No SMS threads synced yet")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button(action: {
                            state.requestSMSConversations()
                        }) {
                            Text("Sync from Phone")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    let filteredThreads = state.smsSearchText.isEmpty
                        ? state.smsThreads
                        : state.smsThreads.filter {
                            ($0.contactName?.localizedCaseInsensitiveContains(state.smsSearchText) == true) ||
                            $0.address.localizedCaseInsensitiveContains(state.smsSearchText) ||
                            $0.snippet.localizedCaseInsensitiveContains(state.smsSearchText)
                        }
                    
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredThreads) { thread in
                                Button(action: {
                                    state.selectSMSThread(threadId: thread.threadId)
                                }) {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(DashboardView.nacmacOrange.opacity(0.2))
                                            .frame(width: 36, height: 36)
                                            .overlay(
                                                Text(String((thread.contactName ?? thread.address).prefix(1)).uppercased())
                                                    .font(.system(size: 14, weight: .bold))
                                                    .foregroundColor(DashboardView.nacmacOrange)
                                            )
                                        
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(thread.contactName ?? thread.address)
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .lineLimit(1)
                                                Spacer()
                                                Text(formatSMSTime(thread.timestamp))
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            Text(thread.snippet)
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(state.selectedThreadId == thread.threadId ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .cornerRadius(8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 6)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(width: 280)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
            
            Divider()
            
            // Right Pane: Active Thread Chat Bubbles & Composer
            VStack(spacing: 0) {
                if let threadId = state.selectedThreadId,
                   let activeThread = state.smsThreads.first(where: { $0.threadId == threadId }) {
                    // Chat header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activeThread.contactName ?? activeThread.address)
                                .font(.system(size: 14, weight: .bold))
                            if activeThread.contactName != nil {
                                Text(activeThread.address)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
                    
                    Divider()
                    
                    // Messages bubble scroll
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(state.threadMessages) { msg in
                                    HStack {
                                        if !msg.isIncoming {
                                            Spacer(minLength: 40)
                                        }
                                        VStack(alignment: msg.isIncoming ? .leading : .trailing, spacing: 2) {
                                            Text(msg.body)
                                                .font(.system(size: 13))
                                                .foregroundColor(msg.isIncoming ? .primary : .white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(msg.isIncoming ? Color(NSColor.controlBackgroundColor) : DashboardView.nacmacOrange)
                                                .cornerRadius(14)
                                            
                                            Text(formatSMSTime(msg.timestamp))
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                                .padding(.horizontal, 4)
                                        }
                                        if msg.isIncoming {
                                            Spacer(minLength: 40)
                                        }
                                    }
                                    .id(msg.id)
                                }
                            }
                            .padding(16)
                        }
                        .onChange(of: state.threadMessages.count) { _ in
                            if let last = state.threadMessages.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Message Composer bar
                    HStack(spacing: 10) {
                        TextField("Text Message (SMS)...", text: $messageInputText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .onSubmit {
                                let txt = messageInputText
                                messageInputText = ""
                                state.sendSMS(recipient: activeThread.address, message: txt, threadId: activeThread.threadId)
                            }
                        
                        Button(action: {
                            let txt = messageInputText
                            messageInputText = ""
                            state.sendSMS(recipient: activeThread.address, message: txt, threadId: activeThread.threadId)
                        }) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(messageInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : DashboardView.nacmacOrange)
                        }
                        .buttonStyle(.plain)
                        .disabled(messageInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(NSColor.controlBackgroundColor))
                } else {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "message")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Select a conversation to view messages")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    
    private func formatSMSTime(_ ts: Int64) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts > 1_000_000_000_000 ? ts / 1000 : ts))
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }
    
    private func selectFileManually() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.sendFile(at: url)
        }
    }
}
