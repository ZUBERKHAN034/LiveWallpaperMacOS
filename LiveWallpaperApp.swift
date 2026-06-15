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


// MARK: - Lock Screen Automation

func applyLockScreenAutomation(tileName: String, completion: @escaping (Bool) -> Void) {
    guard AXIsProcessTrusted() else { completion(false); return }
    guard let u = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else {
        completion(false); return
    }
    NSWorkspace.shared.open(u)
    let tn = tileName
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        var pid: pid_t = -1
        for _ in 0..<20 {
            if let p = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.systempreferences"
            })?.processIdentifier { pid = p; break }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
        }
        guard pid != -1 else { completion(false); return }
        let app = AXUIElementCreateApplication(pid)
        guard lsaFindAndPress(app: app, desc: "LiveWallpaper", timeout: 10) else {
            completion(false); return
        }
        lsaLog("step1 OK, scheduling step2 after 2s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let ok = lsaFindAndPress(app: app, desc: tn, timeout: 10)
            completion(ok)
        }
    }
}

private func lsaLog(_ msg: String) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lsa_debug.log")
    let line = "[LSA] \(msg)\n"
    if let fh = try? FileHandle(forWritingTo: url) {
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(line.utf8))
        try? fh.close()
    } else {
        try? Data(line.utf8).write(to: url, options: .atomic)
    }
}

private func lsaFindAndPress(app: AXUIElement, desc: String, timeout: Double) -> Bool {
    let deadline = Date().timeIntervalSince1970 + timeout
    var its = 0
    while Date().timeIntervalSince1970 < deadline {
        its += 1
        if let btn = findButton(in: app, desc: desc) {
            var dVal: CFTypeRef?, tVal: CFTypeRef?, rVal: CFTypeRef?
            AXUIElementCopyAttributeValue(btn, kAXDescriptionAttribute as CFString, &dVal)
            AXUIElementCopyAttributeValue(btn, kAXTitleAttribute as CFString, &tVal)
            AXUIElementCopyAttributeValue(btn, kAXRoleAttribute as CFString, &rVal)
            let d = (dVal as? String) ?? "?"
            let t = (tVal as? String) ?? "?"
            let r = (rVal as? String) ?? "?"
            lsaLog("PRESS '\(desc)' matched desc='\(d)' title='\(t)' role='\(r)' iter=\(its)")
            return AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success
        }
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
    }
    lsaLog("TIMEOUT '\(desc)' after \(its) iters")
    return false
}

private func findButton(in root: AXUIElement, desc: String) -> AXUIElement? {
    var queue = [root]
    var allButtons: [String] = []
    while !queue.isEmpty {
        let cur = queue.removeFirst()
        var roleVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &roleVal) == .success {
            if let role = roleVal as? String, role == (kAXButtonRole as String) {
                var descVal: CFTypeRef?, titleVal: CFTypeRef?
                AXUIElementCopyAttributeValue(cur, kAXDescriptionAttribute as CFString, &descVal)
                AXUIElementCopyAttributeValue(cur, kAXTitleAttribute as CFString, &titleVal)
                let d = (descVal as? String) ?? ""
                let t = (titleVal as? String) ?? ""
                allButtons.append("desc='\(d)' title='\(t)'")
                if d.localizedCaseInsensitiveContains(desc) || t.localizedCaseInsensitiveContains(desc) {
                    return cur
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
    lsaLog("scanned \(allButtons.count) buttons for '\(desc)': \(allButtons.joined(separator: " | "))")
    return nil
}


