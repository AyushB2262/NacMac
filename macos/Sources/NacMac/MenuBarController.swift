import AppKit
import Foundation

// MARK: - Drag & Drop Aware Status Bar Custom View
@MainActor
final class StatusItemView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    var isConnected: Bool = false {
        didSet { needsDisplay = true }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let symbolName = isConnected ? "iphone.badge.checkmark" : "iphone.gen3"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "NacMac")?.withSymbolConfiguration(config) {
            image.isTemplate = true
            let imgRect = NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
            image.draw(in: imgRect)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
    
    // NSDraggingDestination
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !items.isEmpty else {
            return false
        }
        onDropFiles?(items)
        return true
    }
}

// MARK: - Menu Bar Controller
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate, NetworkServerDelegate, FileTransferDelegate {
    public static let shared = MenuBarController()
    
    private var statusItem: NSStatusItem!
    private var statusView: StatusItemView!
    private let menu = NSMenu()
    
    private var statusMenuItem: NSMenuItem!
    private var transferMenuItem: NSMenuItem!
    private var qrWindow: NSWindow?
    
    override private init() {
        super.init()
    }
    
    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        
        let button = statusItem.button
        button?.imagePosition = .imageOnly
        
        statusView = StatusItemView(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        statusView.onDropFiles = { [weak self] urls in
            self?.handleDroppedFiles(urls)
        }
        statusView.onClick = { [weak self] in
            guard let self = self else { return }
            self.statusItem.menu = self.menu
            self.statusItem.button?.performClick(nil)
            self.statusItem.menu = nil
        }
        
        if let btn = button {
            btn.addSubview(statusView)
        }
        
        buildMenu()
        
        NetworkServer.shared.delegate = self
        FileTransferManager.shared.delegate = self
    }
    
    private func buildMenu() {
        menu.removeAllItems()
        
        statusMenuItem = NSMenuItem(title: "Status: Standby (Port 52840)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        transferMenuItem = NSMenuItem(title: "No active transfers", action: nil, keyEquivalent: "")
        transferMenuItem.isEnabled = false
        menu.addItem(transferMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let dashboardItem = NSMenuItem(title: "Open NacMac Dashboard...", action: #selector(openDashboard), keyEquivalent: "")
        dashboardItem.target = self
        menu.addItem(dashboardItem)
        
        let qrItem = NSMenuItem(title: "Pair New Phone (Show QR)...", action: #selector(showPairingWindow), keyEquivalent: "")
        qrItem.target = self
        menu.addItem(qrItem)
        
        let sendItem = NSMenuItem(title: "Send File to Phone...", action: #selector(selectAndSendFile), keyEquivalent: "")
        sendItem.target = self
        menu.addItem(sendItem)
        
        let openFolderItem = NSMenuItem(title: "Open Downloads Folder", action: #selector(openDownloadsFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let unpairItem = NSMenuItem(title: "Unpair Current Device", action: #selector(unpairDevice), keyEquivalent: "")
        unpairItem.target = self
        menu.addItem(unpairItem)
        
        let quitItem = NSMenuItem(title: "Quit NacMac", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    // MARK: - Actions
    
    @objc func openDashboard() {
        DashboardWindowController.shared.show()
    }
    
    @objc func showPairingWindow() {
        if let existing = qrWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let qrJson = PairingManager.shared.generateQRJSONString()
        guard let qrImage = PairingManager.shared.generateQRImage(from: qrJson) else { return }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "NacMac Pairing"
        window.isReleasedWhenClosed = false
        
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        
        let imageView = NSImageView(frame: NSRect(x: 45, y: 130, width: 250, height: 250))
        imageView.image = qrImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(imageView)
        
        let label = NSTextField(labelWithString: "Scan this code with the NacMac companion app on your Android device.")
        label.frame = NSRect(x: 20, y: 70, width: 300, height: 45)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        contentView.addSubview(label)
        
        let ipLabel = NSTextField(labelWithString: "IP: \(PairingManager.shared.getLocalIPAddresses().first ?? "127.0.0.1"):52840")
        ipLabel.frame = NSRect(x: 20, y: 35, width: 300, height: 25)
        ipLabel.alignment = .center
        ipLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        contentView.addSubview(ipLabel)
        
        window.contentView = contentView
        self.qrWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func selectAndSendFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            NetworkServer.shared.sendFile(at: url)
        }
    }
    
    @objc func openDownloadsFolder() {
        let url = FileTransferManager.shared.downloadDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
    
    @objc func unpairDevice() {
        PairingManager.shared.unpair()
        statusMenuItem.title = "Status: Unpaired (Ready to pair)"
        statusView.isConnected = false
    }
    
    @objc private func quitApp() {
        NetworkServer.shared.stop()
        NSApplication.shared.terminate(nil)
    }
    
    private func handleDroppedFiles(_ urls: [URL]) {
        for url in urls {
            print("[LMM-UI] File dropped onto Menu Bar: \(url.lastPathComponent)")
            NetworkServer.shared.sendFile(at: url)
        }
    }
    
    // MARK: - NetworkServerDelegate
    
    nonisolated public func connectionStateChanged(to state: ConnectionState) {
        Task { @MainActor in
            switch state {
            case .disconnected:
                self.statusMenuItem.title = "Status: Disconnected"
                self.statusView.isConnected = false
                DashboardState.shared.isConnected = false
            case .listening(let port):
                if let paired = PairingManager.shared.getPairedDevice() {
                    self.statusMenuItem.title = "Status: Reconnecting to \(paired.deviceName)..."
                    DashboardState.shared.connectedDeviceName = paired.deviceName
                } else {
                    self.statusMenuItem.title = "Status: Standby (Port \(port))"
                }
                self.statusView.isConnected = false
                DashboardState.shared.isConnected = false
            case .connected(let deviceName, _):
                self.statusMenuItem.title = "Status: Connected to \(deviceName)"
                self.statusView.isConnected = true
                self.qrWindow?.close()
                DashboardState.shared.isConnected = true
                DashboardState.shared.connectedDeviceName = deviceName
            }
        }
    }
    
    nonisolated public func errorOccurred(_ message: String) {
        print("[LMM-UI] Network error: \(message)")
    }
    
    // MARK: - FileTransferDelegate
    
    nonisolated public func transferDidProgress(_ progress: ActiveTransferProgress) {
        Task { @MainActor in
            let dir = progress.isReceiving ? "↓ Receiving" : "↑ Sending"
            let mbps = progress.bytesPerSecond / (1024 * 1024)
            self.transferMenuItem.title = "\(dir) \(progress.filename): \(Int(progress.percent))% (\(String(format: "%.1f", mbps)) MB/s)"
            DashboardState.shared.activeTransfer = progress
        }
    }
    
    nonisolated public func transferDidComplete(transferId: String, filename: String, isReceiving: Bool) {
        Task { @MainActor in
            let dir = isReceiving ? "Received" : "Sent"
            self.transferMenuItem.title = "✓ \(dir): \(filename)"
            DashboardState.shared.activeTransfer = nil
            DashboardState.shared.completedTransfers.insert(
                CompletedTransfer(name: filename, sizeString: "Verified", direction: dir),
                at: 0
            )
        }
    }
    
    nonisolated public func transferDidCancel(transferId: String, reason: String) {
        Task { @MainActor in
            self.transferMenuItem.title = "✕ Transfer cancelled: \(reason)"
        }
    }
    
    nonisolated public func transferDidFail(transferId: String, error: String) {
        Task { @MainActor in
            self.transferMenuItem.title = "⚠ Transfer failed: \(error)"
        }
    }
}
