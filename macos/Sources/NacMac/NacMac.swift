import AppKit
import Foundation

@main
final class NacMacApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = NacMacApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("==================================================")
        print("NacMac macOS Client Starting (v1.1.0)")
        print("Dashboard Window & Menu Bar Drop Target Initializing")
        print("==================================================")
        
        // 1. Setup Standard macOS Application Menu Bar (NacMac, File, Edit, View, Window, Help)
        AppMenuController.shared.setup()
        
        // 2. Setup Menu Bar Icon & Context Menu
        MenuBarController.shared.setup()
        
        // 3. Request Notification Permissions
        NotificationManager.shared.requestAuthorization()
        
        // 4. Start Local Network Server & Bonjour Advertising
        NetworkServer.shared.start()
        
        // 5. Start Universal Clipboard Sync Monitor
        ClipboardSyncManager.shared.start()
        
        // 6. Open Desktop Dashboard Window
        DashboardWindowController.shared.show()
        
        let addresses = PairingManager.shared.getLocalIPAddresses()
        print("Local Network IPs: \(addresses)")
        print("Listening for Android connections on port 52840")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardSyncManager.shared.stop()
        NetworkServer.shared.stop()
        print("NacMac terminated cleanly.")
    }
}
