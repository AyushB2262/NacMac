import Foundation
@preconcurrency import UserNotifications
import AppKit

public final class NotificationManager: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    public static let shared = NotificationManager()
    
    private let cacheDir: URL
    private var registeredCategories = Set<UNNotificationCategory>()
    private let lock = NSLock()
    private var hasBundle: Bool {
        return Bundle.main.bundleIdentifier != nil
    }
    
    override private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.cacheDir = home.appendingPathComponent(".nacmac/icon_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        super.init()
        
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
    
    // UNUserNotificationCenterDelegate banner click action & inline reply
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionId = response.actionIdentifier
        
        if actionId.hasPrefix("ACTION_") {
            let indexStr = actionId.replacingOccurrences(of: "ACTION_", with: "")
            let actionIndex = Int(indexStr) ?? 0
            let replyText = (response as? UNTextInputNotificationResponse)?.userText
            let notifId = (userInfo["notificationId"] as? String) ?? response.notification.request.identifier
            let deviceId = userInfo["deviceId"] as? String
            
            sendNotificationAction(notificationKey: notifId, actionIndex: actionIndex, replyText: replyText, deviceId: deviceId)
            dismissNotification(id: notifId)
        } else if actionId == UNNotificationDefaultActionIdentifier {
            handleNotificationAction(userInfo: userInfo)
        } else if actionId == UNNotificationDismissActionIdentifier {
            let notifId = (userInfo["notificationId"] as? String) ?? response.notification.request.identifier
            let deviceId = userInfo["deviceId"] as? String
            dismissNotification(id: notifId)
            let dismissObj = NotificationDismissPayload(id: notifId, deviceId: deviceId)
            if let data = try? JSONEncoder().encode(dismissObj),
               let payloadStr = String(data: data, encoding: .utf8) {
                let envelope = NacMacEnvelope(type: .notificationDismissed, payload: payloadStr)
                NetworkServer.shared.sendEnvelope(envelope, to: deviceId)
            }
        }
        completionHandler()
    }
    
    public func sendNotificationAction(notificationKey: String, actionIndex: Int, replyText: String?, deviceId: String?) {
        let payload = NotificationActionPayload(
            notificationKey: notificationKey,
            actionIndex: actionIndex,
            replyText: replyText,
            deviceId: deviceId
        )
        if let data = try? JSONEncoder().encode(payload),
           let jsonStr = String(data: data, encoding: .utf8) {
            let envelope = NacMacEnvelope(type: .notificationAction, payload: jsonStr)
            NetworkServer.shared.sendEnvelope(envelope, to: deviceId)
            print("[NacMac-Notification] Sent action \(actionIndex) for \(notificationKey) to device \(deviceId ?? "all") (reply: \(replyText ?? "none"))")
            
            Task { @MainActor in
                let desc = replyText != nil ? "Sent reply: \"\(replyText!)\"" : "Triggered notification action \(actionIndex)"
                DashboardState.shared.addLog(desc, type: "info")
            }
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
        
        let resolvedDeviceName = payload.deviceName
            ?? payload.deviceId.flatMap { PairingManager.shared.getPairedDevice(androidId: $0)?.deviceName }
        let originTag = resolvedDeviceName.map { "via \($0)" }
        let bodyText = payload.body
        let appName = payload.appName
        let titleText = payload.title
        
        var effectivePayload = payload
        effectivePayload.deviceName = resolvedDeviceName
        Task { @MainActor in
            DashboardState.shared.addNotification(from: effectivePayload)
        }
        
        guard hasBundle else {
            let fallbackTitle = originTag != nil ? "\(displayTitle) (\(originTag!))" : displayTitle
            fallbackDisplay(title: fallbackTitle, body: bodyText, filePath: payload.filePath)
            print("[NacMac-Notification] Delivered native banner for: \(appName) - \(titleText)")
            return
        }
        
        let content = UNMutableNotificationContent()
        content.title = displayTitle
        if let origin = originTag {
            content.subtitle = origin
        }
        content.body = bodyText
        content.sound = .default
        content.threadIdentifier = payload.packageName
        
        var userInfoDict: [String: Any] = ["notificationId": payload.id]
        if let devId = payload.deviceId {
            userInfoDict["deviceId"] = devId
        }
        if let filePath = payload.filePath, !filePath.isEmpty {
            userInfoDict["filePath"] = filePath
        } else if payload.packageName == "com.nactore.nacmac.file" {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.appendingPathComponent("NacMac").path ?? ""
            userInfoDict["filePath"] = downloads
        }
        content.userInfo = userInfoDict
        
        // Dynamic Notification Actions & In-line reply
        var unActions: [UNNotificationAction] = []
        if let payloadActions = payload.actions, !payloadActions.isEmpty {
            for action in payloadActions {
                let actionId = "ACTION_\(action.index)"
                if action.isReply {
                    let replyAction = UNTextInputNotificationAction(
                        identifier: actionId,
                        title: action.title.isEmpty ? "Reply" : action.title,
                        options: [],
                        textInputButtonTitle: "Send",
                        textInputPlaceholder: "Type reply..."
                    )
                    unActions.append(replyAction)
                } else {
                    let btnAction = UNNotificationAction(
                        identifier: actionId,
                        title: action.title,
                        options: []
                    )
                    unActions.append(btnAction)
                }
            }
        } else if payload.hasReplyAction {
            let replyAction = UNTextInputNotificationAction(
                identifier: "ACTION_0",
                title: "Reply",
                options: [],
                textInputButtonTitle: "Send",
                textInputPlaceholder: "Type reply..."
            )
            unActions.append(replyAction)
        }
        
        if !unActions.isEmpty {
            let categoryId = "CATEGORY_\(payload.id)"
            let category = UNNotificationCategory(
                identifier: categoryId,
                actions: unActions,
                intentIdentifiers: [],
                options: [.customDismissAction]
            )
            lock.lock()
            // Bound registered categories to prevent IPC bloat to usernoted
            if registeredCategories.count >= 32, let oldest = registeredCategories.first {
                registeredCategories.remove(oldest)
            }
            registeredCategories.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(registeredCategories)
            lock.unlock()
            content.categoryIdentifier = categoryId
        }
        
        if let iconBase64 = payload.iconBase64,
           let iconData = Data(base64Encoded: iconBase64) {
            let iconURL = cacheDir.appendingPathComponent("\(payload.packageName).png")
            do {
                let existingSize = (try? FileManager.default.attributesOfItem(atPath: iconURL.path)[.size] as? Int) ?? -1
                if existingSize != iconData.count {
                    try iconData.write(to: iconURL)
                }
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
            lock.lock()
            let categoryId = "CATEGORY_\(id)"
            if let idx = registeredCategories.firstIndex(where: { $0.identifier == categoryId }) {
                registeredCategories.remove(at: idx)
                UNUserNotificationCenter.current().setNotificationCategories(registeredCategories)
            }
            lock.unlock()
        }
        print("[NacMac-Notification] Dismissed notification id: \(id)")
    }
    
    public func fallbackDisplay(title: String, body: String, filePath: String? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Safe execution via argv arguments: never parse title or body as AppleScript source
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e", "on run argv",
                "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                "-e", "end run",
                title,
                body
            ]
            try? process.run()
        }
    }
}
