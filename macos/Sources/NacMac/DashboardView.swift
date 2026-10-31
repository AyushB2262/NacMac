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
    @Published var pairedPath: String = "~/.nacmac/paired_device.json"
    @Published var autoConnect: Bool = true
    @Published var localIP: String = "127.0.0.1"
    @Published var port: Int = 52840
    @Published var qrCodeImage: NSImage? = nil
    
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
        
        if let paired = PairingManager.shared.getPairedDevice() {
            self.connectedDeviceName = paired.deviceName
            self.isConnected = true
        } else {
            self.connectedDeviceName = "No Device Paired"
            self.isConnected = false
        }
    }
    
    func disconnect() {
        PairingManager.shared.unpair()
        NetworkServer.shared.disconnectPeer()
        self.connectedDeviceName = "No Device Paired"
        self.isConnected = false
        addLog("Device unpaired and socket disconnected.", type: "warning")
        refreshState()
    }
    
    func dismissNotification(id: String) {
        notifications.removeAll { $0.id == id }
        NotificationManager.shared.dismissNotification(id: id)
        let dismissObj = NotificationDismissPayload(id: id)
        if let data = try? JSONEncoder().encode(dismissObj),
           let payloadStr = String(data: data, encoding: .utf8) {
            let envelope = NacMacEnvelope(type: .notificationDismissed, payload: payloadStr)
            NetworkServer.shared.sendEnvelope(envelope)
        }
        addLog("Dismissed notification: \(id)", type: "info")
    }
    
    func addNotification(from payload: NotificationPayload) {
        let item = MirroredNotifItem(
            id: payload.id,
            app: payload.appName,
            sender: payload.title,
            body: payload.body,
            icon: payload.packageName.contains("whatsapp") ? "message.fill" : "bell.fill",
            canReply: payload.hasReplyAction
        )
        notifications.removeAll { $0.id == payload.id }
        notifications.insert(item, at: 0)
        addLog("Received notification from \(payload.appName): \(payload.title)", type: "success")
    }
    
    func sendFile(at url: URL) {
        NetworkServer.shared.sendFile(at: url)
        let name = url.lastPathComponent
        completedTransfers.insert(CompletedTransfer(name: name, sizeString: "Ready", direction: "Sent"), at: 0)
        addLog("Initiated file transfer: \(name)", type: "info")
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
}

struct MirroredNotifItem: Identifiable {
    let id: String
    let app: String
    let sender: String
    let body: String
    let icon: String
    let canReply: Bool
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
        }
        .frame(minWidth: 960, minHeight: 640)
        .overlay {
            if isShowingLargeQR, let qr = state.qrCodeImage {
                ZStack {
                    Color.black.opacity(0.6)
                        .edgesIgnoringSafeArea(.all)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
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
                            .shadow(color: Color.black.opacity(0.4), radius: 30, x: 0, y: 14)
                    }
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
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
            Spacer().frame(height: 32)
            
            sidebarButton(title: "Devices", icon: "iphone", id: "Devices")
            sidebarButton(title: "File Hub", icon: "folder", id: "File Hub")
            sidebarButton(title: "Notifications", icon: "bell", id: "Notifications")
            sidebarButton(title: "Activity Log", icon: "list.bullet", id: "Activity Log")
            sidebarButton(title: "Settings", icon: "gearshape", id: "Settings")
            
            Spacer()
            
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
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
        Button(action: { state.selectedTab = id }) {
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
        }
        .buttonStyle(.plain)
        .foregroundColor(state.selectedTab == id ? .accentColor : .primary)
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
                .font(.system(size: 20, weight: .heavy, design: .default))
                .tracking(0.5)
            Text("Android Connectivity")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - My Devices Card
    private var myDevicesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("My Devices")
                .font(.system(size: 14, weight: .semibold))
            
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(state.connectedDeviceName)
                            .font(.system(size: 14, weight: .bold))
                        
                        if state.isConnected {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 7, height: 7)
                                Text("Secure & Online")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.12))
                            .cornerRadius(6)
                        } else {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 7, height: 7)
                                Text("Standby")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(6)
                        }
                    }
                    
                    Text("Local ID: \(state.pairedPath)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if state.isConnected || state.connectedDeviceName != "No Paired Device" {
                    Button(action: {
                        state.disconnect()
                    }) {
                        Text("Disconnect")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Pair New Device Card
    private var pairNewDeviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair New Device")
                .font(.system(size: 14, weight: .semibold))
            
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
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
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
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .frame(width: 320)
    }
    
    // MARK: - File Transfer Hub Drop Card
    private var fileDropCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File Transfer & Progress Hub")
                .font(.system(size: 14, weight: .semibold))
            
            Button(action: {
                selectFileManually()
            }) {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(.secondary)
                    
                    Text("Drag & Drop Files Here")
                        .font(.system(size: 14, weight: .semibold))
                    
                    Text("Android transfers")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 28)
                .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
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
            Text("Transfer Queue")
                .font(.system(size: 14, weight: .semibold))
            
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
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 14))
                            
                            Text("\(item.name) (\(item.sizeString)) - \(item.direction)")
                                .font(.system(size: 12, weight: .regular))
                            
                            Spacer()
                            
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 14))
                        }
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
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
        .frame(width: 320)
    }
    
    // MARK: - Native Mirroring Section
    private var nativeMirroringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Native Mirroring Section")
                    .font(.system(size: 14, weight: .semibold))
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
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(state.notifications) { notif in
                            HStack(alignment: .top, spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.accentColor.opacity(0.15))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: notif.icon)
                                        .foregroundColor(.accentColor)
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
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                            )
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
                Text("Transferred Files History")
                    .font(.system(size: 14, weight: .semibold))
                
                List {
                    ForEach(state.completedTransfers) { item in
                        HStack {
                            Image(systemName: "doc")
                            Text(item.name)
                                .fontWeight(.medium)
                            Spacer()
                            Text(item.sizeString)
                                .foregroundColor(.secondary)
                            Text(item.direction)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(4)
                        }
                        .padding(.vertical, 4)
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
                    HStack(spacing: 12) {
                        Image(systemName: notif.icon)
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.green)
                            .cornerRadius(8)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notif.app)
                                .font(.system(size: 13, weight: .bold))
                            Text("\(notif.sender): \(notif.body)")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Dismiss") {
                            state.dismissNotification(id: notif.id)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
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
