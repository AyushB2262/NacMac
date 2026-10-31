# NacMac Reverse-Engineering & Continuity Bridge (NacMac-REA)

This repository contains the complete reverse-engineering analysis, technical specifications, and working implementation of **Version 0.2** of the privacy-first Continuity Bridge between Android and macOS.

---

## 📦 Production Builds (Version 0.2)

- **macOS Installer (DMG):** [NacMac-v0.2.dmg](file:///Users/ayush/LMM-REA/NacMac-v0.2.dmg)
  - Features the full native desktop **Dashboard Window** + interactive Menu Bar utility.
  - Mount the DMG and drag `NacMac.app` into `/Applications`.
- **Android Companion (APK):** [NacMac-v0.2.apk](file:///Users/ayush/LMM-REA/NacMac-v0.2.apk)
  - Updated card-based Material UI matching reference specifications.
  - Install via `adb install -r NacMac-v0.2.apk` or download onto your device.

---

## 1. Project Components

```
/Users/ayush/LMM-REA/
├── NacMac-v0.2.dmg                       # Production macOS disk image installer
├── NacMac-v0.2.apk                       # Production Android companion application
│
├── macos/                                # Native macOS Dashboard + Menu Bar Client (Swift 6 / AppKit / SwiftUI)
│   ├── NacMac.app                        # Packaged standalone macOS application bundle
│   ├── package_app.sh                    # Automated release build & bundle script
│   ├── package_dmg.sh                    # DMG disk image packager
│   ├── Package.swift                     # Swift Package Manager configuration
│   └── Sources/NacMac/
│       ├── NacMac.swift                  # Application lifecycle & NSApplicationDelegate
│       ├── DashboardWindowController.swift# NSWindowController hosting native SwiftUI Dashboard
│       ├── DashboardView.swift           # Native macOS Dashboard (Devices, Transfer Queue, Mirroring)
│       ├── MenuBarController.swift       # NSStatusItem, context menu & drag-and-drop target
│       ├── NetworkServer.swift           # Bonjour advertiser & length-prefixed TCP socket server
│       ├── PairingManager.swift          # QR generator, crypto handshake & trust storage
│       ├── NotificationManager.swift     # UNUserNotificationCenter native banner dispatcher
│       ├── FileTransferManager.swift     # Streaming chunked file receiver/sender with cancel
│       └── Models.swift                  # Framing envelopes & protocol data structures
│
├── android/                              # Android Companion App (Kotlin / Jetpack / Material 3)
│   ├── app/src/main/
│   │   ├── AndroidManifest.xml           # Service declarations, network & storage permissions
│   │   ├── java/com/nactore/nacmac/
│   │   │   ├── ui/MainActivity.kt        # Pairing dialog, live connection card, file sender
│   │   │   ├── service/
│   │   │   │   ├── NacMacBackgroundService.kt       # Persistent foreground service & Wi-Fi watcher
│   │   │   │   └── NacMacNotificationListener.kt    # Intercepts & dispatches phone notifications
│   │   │   ├── network/
│   │   │   │   ├── ConnectionManager.kt          # TCP socket, heartbeat keepalive, auto-reconnect
│   │   │   │   └── DiscoveryClient.kt            # mDNS service discovery + direct TCP probe
│   │   │   ├── transfer/FileTransferWorker.kt    # Dual-direction chunk streaming to Downloads
│   │   │   ├── data/DeviceStore.kt               # Persisted pairing credentials
│   │   │   └── model/Protocol.kt                 # Wire protocol definitions
│   │   └── res/                          # Layouts, themes, and UI resources
│   └── build.gradle.kts                  # Gradle build system
│
├── tests/
│   └── test_e2e_continuity.py            # Automated end-to-end integration & protocol test suite
│
├── NACMAC_FEATURE_CATALOG.md          # Comprehensive catalog of all NacMac features
├── REVERSE_ENGINEERING_ANALYSIS.md       # Deep technical analysis of network & OS hooks
└── V0.1_NACMAC_SPECIFICATION_AND_ROADMAP.md     # Engineering specification for Version 0.1
```

---

## 2. Version 0.1 Implemented Deliverables

| Deliverable | Implementation Details | Verification Status |
| :--- | :--- | :--- |
| **1. Pairing & Auto-Reconnect** | • QR code generation on Mac encoding local IP, port `52840`, and ephemeral secret.<br>• One-time pairing handshake (`PAIR_REQUEST` / `PAIR_RESPONSE`).<br>• Persistent trust storage (`~/.nacmac/paired_device.json`).<br>• Zero-touch auto-reconnect upon Wi-Fi connection, wake from sleep, or reboot. | **VERIFIED** (Automated Test 1 & 6) |
| **2. Bidirectional File Transfer** | • Drag & drop any file or folder onto the macOS Menu Bar icon (`NSDraggingDestination`).<br>• Streaming 64 KB binary chunks with live speed (MB/s) and progress calculation.<br>• Mid-transfer cancellation support with automatic `.part` file cleanup.<br>• Recipient verifies byte-for-byte SHA-256 integrity and saves to `Downloads/NacMac`. | **VERIFIED** (Automated Test 4 & 5) |
| **3. Notification Mirroring** | • Android `NotificationListenerService` captures phone notifications and app icons.<br>• Payloads forwarded over local TCP socket to macOS.<br>• Mac dispatches native notification banners via `UserNotifications` / native notification scripting.<br>• Dismissals synced dynamically between devices. | **VERIFIED** (Automated Test 3) |

---

## 3. Running & Verifying

### Run the Automated End-to-End Test Suite
To verify the complete protocol handshake, heartbeat, notification mirroring, file transfer with SHA-256 integrity, cancellation, and auto-reconnect resiliency:
```bash
python3 /Users/ayush/LMM-REA/tests/test_e2e_continuity.py
```

### Launch the macOS Menu Bar App
You can launch the compiled native macOS app directly:
```bash
open /Users/ayush/LMM-REA/macos/NacMac.app
```
*(Or run `/Users/ayush/LMM-REA/macos/.build/release/NacMac` from terminal).*
The app will appear in your top-right macOS Menu Bar with a phone icon. Click it to view the pairing QR code, check connection status, or drag-and-drop files directly onto it to share with Android.
