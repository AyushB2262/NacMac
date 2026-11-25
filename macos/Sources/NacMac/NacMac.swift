import AppKit
import Foundation

@main
final class NacMacApp: NSObject, NSApplicationDelegate {
    static var isHeadless: Bool {
        return CommandLine.arguments.contains("--headless")
            || ProcessInfo.processInfo.environment["NACMAC_HEADLESS"] == "1"
    }

    static func main() {
        // Ensure logs flush immediately when stdout/stderr are piped in headless/CI runs
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        // Prevent macOS AppKit crash/window restoration dialogs across rapid restarts
        UserDefaults.standard.register(defaults: [
            "NSQuitAlwaysKeepsWindows": false,
            "ApplePersistenceIgnoreState": true
        ])

        let signalSources = makeSignalSources()
        withExtendedLifetime(signalSources) {
            if isHeadless {
                print("==================================================")
                print("NacMac macOS Daemon Starting (v1.2.0, Headless)")
                print("==================================================")
                _ = PairingManager.shared
                NetworkServer.shared.start()
                ClipboardSyncManager.shared.start()
                let addresses = PairingManager.shared.getLocalIPAddresses()
                print("Local Network IPs: \(addresses)")
                print("Listening for Android connections on port 52840")
                RunLoop.main.run()
                return
            }

            let app = NSApplication.shared
            let delegate = NacMacApp()
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        }
    }

    private static func makeSignalSources() -> [DispatchSourceSignal] {
        return [SIGTERM, SIGINT].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                ClipboardSyncManager.shared.stop()
                NetworkServer.shared.stop()
                print("NacMac received signal \(sig), exiting cleanly.")
                exit(0)
            }
            source.resume()
            return source
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("==================================================")
        print("NacMac macOS Client Starting (v1.2.0)")
        print("Dashboard Window & Menu Bar Drop Target Initializing")
        print("==================================================")

        // 0. Initialize Pairing Manager & write active_qr.json immediately
        _ = PairingManager.shared

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
