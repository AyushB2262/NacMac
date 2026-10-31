import AppKit
import Foundation

@MainActor
public final class AppMenuController: NSObject {
    public static let shared = AppMenuController()
    
    override private init() {
        super.init()
    }
    
    public func setup() {
        let mainMenu = NSMenu()
        
        // MARK: - 1. Application Menu ("NacMac")
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "NacMac")
        appMenuItem.submenu = appMenu
        
        let appName = "NacMac"
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        
        let servicesMenu = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())
        
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        
        // MARK: - 2. File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        
        let openDashItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        openDashItem.target = self
        fileMenu.addItem(openDashItem)
        
        let pairItem = NSMenuItem(title: "Pair New Phone...", action: #selector(showPairing), keyEquivalent: "p")
        pairItem.target = self
        fileMenu.addItem(pairItem)
        
        let sendFileItem = NSMenuItem(title: "Send File to Phone...", action: #selector(selectAndSendFile), keyEquivalent: "s")
        sendFileItem.target = self
        fileMenu.addItem(sendFileItem)
        
        let openDownloadsItem = NSMenuItem(title: "Open Downloads Folder", action: #selector(openDownloads), keyEquivalent: "o")
        openDownloadsItem.target = self
        fileMenu.addItem(openDownloadsItem)
        
        fileMenu.addItem(NSMenuItem.separator())
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(closeItem)
        
        // MARK: - 3. Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        // MARK: - 4. View Menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        
        let toggleThemeItem = NSMenuItem(title: "Toggle Dark / Light Mode", action: #selector(toggleTheme), keyEquivalent: "t")
        toggleThemeItem.target = self
        viewMenu.addItem(toggleThemeItem)
        
        // MARK: - 5. Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        
        // MARK: - 6. Help Menu
        let helpMenuItem = NSMenuItem()
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenuItem.submenu = helpMenu
        
        let helpItem = NSMenuItem(title: "NacMac Help", action: #selector(openHelp), keyEquivalent: "?")
        helpItem.target = self
        helpMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        
        NSApp.mainMenu = mainMenu
    }
    
    @objc private func openSettings() {
        DashboardState.shared.selectedTab = "Settings"
        DashboardWindowController.shared.show()
    }
    
    @objc private func openDashboard() {
        DashboardState.shared.selectedTab = "Devices"
        DashboardWindowController.shared.show()
    }
    
    @objc private func showPairing() {
        MenuBarController.shared.showPairingWindow()
    }
    
    @objc private func selectAndSendFile() {
        MenuBarController.shared.selectAndSendFile()
    }
    
    @objc private func openDownloads() {
        let downloads = FileTransferManager.shared.downloadDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: downloads.path)
    }
    
    @objc private func toggleTheme() {
        let current = UserDefaults.standard.string(forKey: "nacmac_theme_appearance") ?? "dark"
        let next = (current == "dark") ? "light" : "dark"
        UserDefaults.standard.set(next, forKey: "nacmac_theme_appearance")
    }
    
    @objc private func openHelp() {
        if let url = URL(string: "https://nactore.com") {
            NSWorkspace.shared.open(url)
        }
    }
}
