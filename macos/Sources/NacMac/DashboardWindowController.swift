import AppKit
import SwiftUI

final class DashboardWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
public final class DashboardWindowController: NSObject, NSWindowDelegate {
    public static let shared = DashboardWindowController()
    
    private var window: NSWindow?
    
    override private init() {
        super.init()
    }
    
    public func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let hostingController = NSHostingController(rootView: DashboardView())
        
        let newWindow = DashboardWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        newWindow.title = "NacMac - Android Connectivity"
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.contentViewController = hostingController
        newWindow.delegate = self
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    public func windowWillClose(_ notification: Notification) {
        // Keep in background for quick re-opening from Menu Bar
    }
}
