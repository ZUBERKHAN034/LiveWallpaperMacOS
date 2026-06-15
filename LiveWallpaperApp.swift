/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

let sharedEngine = WallpaperEngine.shared()

@main
struct LiveWallpaperApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
            Settings { EmptyView() }
    }
        
}


class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!
    
    let engine = sharedEngine

    func applicationDidFinishLaunching(_ notification: Notification) {
        
        NSApp.setActivationPolicy(.accessory)

        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "play.desktopcomputer", accessibilityDescription: "Live Wallpaper")
        }

        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: NSLocalizedString("Show window", comment: ""), action: #selector(showWindow), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: NSLocalizedString("Hide window", comment: ""), action: #selector(hideWindow), keyEquivalent: "h"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: NSLocalizedString("Quit", comment: ""), action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // One-time lock-screen onboarding hint
        NotificationCenter.default.addObserver(
            forName: AerialCatalogManager.didSyncNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.maybeShowAerialOnboarding()
        }

        // Create main window with ContentView
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView,.borderless],
            backing: .buffered,
            defer: false
        )
        //hide titlebar
        //window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified
        
        window.center()
        window.contentView = NSHostingView(rootView: ContentView())
        window.title = "LiveWallpaper"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        
        if !hasAccessibilityAccess() {
            requestAccessibilityAccess()
        }

        
        if !isLoginItemEnabled() {
            setLoginItem(enabled: true)
        }
        

        
    }

    // Show the config window
    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
    }

    // Hide the window without quitting the app
    @objc func hideWindow() {
        window.orderOut(nil)
    }

    // Quit the app completely
    @objc func quit() {
        
        engine?.terminateApplication()
        NSApp.terminate(nil)
    }

    private func maybeShowAerialOnboarding() {
        guard !AerialCatalogBridge.hasShownOnboarding else { return }
        if AXIsProcessTrusted() { return }
        AerialCatalogBridge.markOnboardingShown()

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Lock Screen Ready", comment: "")
            alert.informativeText = NSLocalizedString(
                "Your wallpaper is also ready for the lock screen — open System Settings → Wallpaper, pick the LiveWallpaper category, and select your video once to activate it.",
                comment: ""
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
        }
    }
}

// MARK: Permission Access

func hasAccessibilityAccess() -> Bool {
    return AXIsProcessTrusted()
}

func requestAccessibilityAccess() {
    let options: [String: Bool] = ["AXTrustedCheckOptionPrompt": true]
    AXIsProcessTrustedWithOptions(options as CFDictionary)
}

func isLoginItemEnabled() -> Bool {
    return UserDefaults.standard.bool(forKey: UserDefaultsKeys.launchAtLogin)
}


func setLoginItem(enabled: Bool) {
    guard let bundleId = Bundle.main.bundleIdentifier else { return }

    if SMLoginItemSetEnabled(bundleId as CFString, enabled) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.launchAtLogin)
    } else {
        print("Failed to update login items")
    }
}


// MARK: - Lock Screen Automation (C shim via bridging header)

func applyLockScreenAutomation(tileName: String, completion: @escaping (Bool) -> Void) {
    guard AXIsProcessTrusted() else { completion(false); return }
    guard let u = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else {
        completion(false); return
    }
    NSWorkspace.shared.open(u)
    let tn = tileName
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        guard let sp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) else {
            completion(false); return
        }
        let pid = sp.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        if !lsaFindAndPress(app: app, desc: "LiveWallpaper", timeout: 8) { completion(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let ok = lsaFindAndPress(app: app, desc: tn, timeout: 5)
            completion(ok)
        }
    }
}

private func lsaFindAndPress(app: AXUIElement, desc: String, timeout: Double) -> Bool {
    let deadline = Date().timeIntervalSince1970 + timeout
    while Date().timeIntervalSince1970 < deadline {
        var windowsVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsVal) == .success {
            if let arr = windowsVal as? [AXUIElement] {
                for win in arr {
                    var titleVal: CFTypeRef?
                    if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleVal) == .success {
                        if let title = titleVal as? String, title.localizedCaseInsensitiveContains("wallpaper") {
                            if let btn = findButton(in: win, desc: desc) {
                                return AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success
                            }
                        }
                    }
                }
            }
        }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.3))
    }
    return false
}

private func findButton(in root: AXUIElement, desc: String) -> AXUIElement? {
    var queue = [root]
    while !queue.isEmpty {
        let cur = queue.removeFirst()
        var roleVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &roleVal) == .success {
            if let role = roleVal as? String, role == (kAXButtonRole as String) {
                var descVal: CFTypeRef?
                if AXUIElementCopyAttributeValue(cur, kAXDescriptionAttribute as CFString, &descVal) == .success {
                    if let d = descVal as? String, d.localizedCaseInsensitiveContains(desc) {
                        return cur
                    }
                }
            }
        }
        var kidsVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(cur, kAXChildrenAttribute as CFString, &kidsVal) == .success {
            if let kids = kidsVal as? [AXUIElement] {
                queue.append(contentsOf: kids)
            }
        }
    }
    return nil
}


