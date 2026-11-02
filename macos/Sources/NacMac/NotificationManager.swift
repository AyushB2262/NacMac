import Foundation
@preconcurrency import UserNotifications
import AppKit

public final class NotificationManager: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    public static let shared = NotificationManager()
    
    private let cacheDir: URL
    private var hasBundle: Bool {
        return Bundle.main.bundleIdentifier != nil
    }
    
    override private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.cacheDir = home.appendingPathComponent(".nacmac/icon_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        super.init()
        
        NSUserNotificationCenter.default.delegate = self
        if hasBundle {
            UNUserNotificationCenter.current().delegate = self
            requestAuthorization()
        }
    }
    
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Ensure notification banners appear even when NacMac is the frontmost app
        completionHandler([.banner, .sound, .badge, .list])
    }
    
    // UNUserNotificationCenterDelegate banner click action
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        handleNotificationAction(userInfo: userInfo)
        completionHandler()
    }
    
    // NSUserNotificationCenterDelegate to display banner even when active
    @available(macOS, deprecated: 11.0, message: "Legacy fallback")
    public func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    @available(macOS, deprecated: 11.0, message: "Legacy fallback")
    public func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if let userInfo = notification.userInfo {
            handleNotificationAction(userInfo: userInfo)
        }
    }

    private func handleNotificationAction(userInfo: [AnyHashable: Any]) {
        if let filePath = userInfo["filePath"] as? String, !filePath.isEmpty {
            let fileURL = URL(fileURLWithPath: filePath)
            if FileManager.default.fileExists(atPath: filePath) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return
            } else {
                let folder = fileURL.hasDirectoryPath ? fileURL : fileURL.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: folder.path) {
                    NSWorkspace.shared.open(folder)
                    return
                }
            }
        }

        // Fallback: open NacMac Downloads directory
        if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            let nacmacDir = downloads.appendingPathComponent("NacMac")
            if FileManager.default.fileExists(atPath: nacmacDir.path) {
                NSWorkspace.shared.open(nacmacDir)
            } else {
                NSWorkspace.shared.open(downloads)
            }
        }
    }
    
    public func requestAuthorization() {
        guard hasBundle else {
            print("[NacMac-Notification] Running outside .app bundle. Standing by.")
            return
        }
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[NacMac-Notification] Auth error: \(error.localizedDescription)")
            } else {
                print("[NacMac-Notification] Authorized: \(granted)")
            }
        }
    }
    
    public func deliverNotification(_ payload: NotificationPayload) {
        let displayTitle = (!payload.title.isEmpty && payload.title != payload.appName)
            ? "\(payload.title) (\(payload.appName))"
            : payload.appName
        
        let bodyText = payload.body
        let appName = payload.appName
        let titleText = payload.title
        
        Task { @MainActor in
            DashboardState.shared.addNotification(from: payload)
        }
        
        guard hasBundle else {
            fallbackDisplay(title: displayTitle, body: bodyText, filePath: payload.filePath)
            print("[NacMac-Notification] Delivered native banner for: \(appName) - \(titleText)")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = displayTitle
        content.body = bodyText
        content.sound = .default
        content.threadIdentifier = payload.packageName
        if let filePath = payload.filePath, !filePath.isEmpty {
            content.userInfo = ["filePath": filePath]
        } else if payload.packageName == "com.nactore.nacmac.file" {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.appendingPathComponent("NacMac").path ?? ""
            content.userInfo = ["filePath": downloads]
        }
        
        if let iconBase64 = payload.iconBase64,
           let iconData = Data(base64Encoded: iconBase64) {
            let iconURL = cacheDir.appendingPathComponent("\(payload.packageName).png")
            do {
                try iconData.write(to: iconURL)
                let attachment = try UNNotificationAttachment(identifier: "icon-\(payload.id)", url: iconURL, options: nil)
                content.attachments = [attachment]
            } catch {
                print("[NacMac-Notification] Failed to write icon attachment: \(error)")
            }
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: payload.id, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                print("[NacMac-Notification] Failed to deliver via UN: \(error.localizedDescription)")
                self?.fallbackDisplay(title: displayTitle, body: bodyText)
            } else {
                print("[NacMac-Notification] Delivered native banner for: \(appName) - \(titleText)")
            }
        }
    }
    
    public func dismissNotification(id: String) {
        if hasBundle {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
        print("[NacMac-Notification] Dismissed notification id: \(id)")
    }
    
    @available(macOS, deprecated: 11.0, message: "Legacy fallback")
    public func fallbackDisplay(title: String, body: String, filePath: String? = nil) {
        DispatchQueue.main.async {
            let notif = NSUserNotification()
            notif.title = title
            notif.informativeText = body
            notif.soundName = NSUserNotificationDefaultSoundName
            if let filePath = filePath {
                notif.userInfo = ["filePath": filePath]
            }
            NSUserNotificationCenter.default.deliver(notif)
        }
    }
}
