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

func selectFirstLiveWallpaperTile() async -> Bool {
    guard AXIsProcessTrusted() else { return false }
    guard let u = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else {
        return false
    }
    let settingsWasOpen = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.systempreferences" }
    NSWorkspace.shared.open(u)

    var app: AXUIElement? = nil
    for _ in 0..<40 {
        if let sp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) {
            app = AXUIElementCreateApplication(sp.processIdentifier)
            break
        }
        try? await Task.sleep(for: .milliseconds(250))
    }
    guard let app = app else { return false }

    // Poll for "LiveWallpaper" section header → tile
    let deadline = Date().timeIntervalSince1970 + 15
    while Date().timeIntervalSince1970 < deadline {
        if let tile = findFirstTileInLiveWallpaperSection(app) {
            guard AXUIElementPerformAction(tile, kAXPressAction as CFString) == .success else { return false }
            if !settingsWasOpen {
                try? await Task.sleep(for: .seconds(1))
                closeSettingsWindow(app: app)
            }
            return true
        }
        try? await Task.sleep(for: .milliseconds(500))
    }
    if !settingsWasOpen { closeSettingsWindow(app: app) }
    return false
}

private func findFirstTileInLiveWallpaperSection(_ root: AXUIElement) -> AXUIElement? {
    var queue = [(root, false)]
    while !queue.isEmpty {
        let (cur, inLW) = queue.removeFirst()

        if inLW {
            // We're inside the LiveWallpaper section's tile grid — search for the first button
            var roleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &roleVal)
            if (roleVal as? String) == (kAXButtonRole as String) { return cur }

            // Breadth-first through children
            var kidsVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(cur, kAXChildrenAttribute as CFString, &kidsVal) == .success {
                if let kids = kidsVal as? [AXUIElement] {
                    queue.append(contentsOf: kids.map { ($0, true) })
                }
            }
            continue
        }

        // Search for AXStaticText with value='LiveWallpaper' → next sibling is the tile container
        var kidsVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(cur, kAXChildrenAttribute as CFString, &kidsVal) == .success {
            if let kids = kidsVal as? [AXUIElement] {
                for i in 0..<kids.count {
                    var valueVal: CFTypeRef?, roleVal: CFTypeRef?
                    AXUIElementCopyAttributeValue(kids[i], kAXValueAttribute as CFString, &valueVal)
                    AXUIElementCopyAttributeValue(kids[i], kAXRoleAttribute as CFString, &roleVal)
                    if let role = roleVal as? String, role == "AXStaticText",
                       let value = valueVal as? String, value.localizedCaseInsensitiveContains("lifewallpaper") {
                        // Next sibling after the label is the ScrollArea containing tiles
                        if i + 1 < kids.count {
                            queue.append((kids[i + 1], true))
                        }
                    }
                }
                queue.append(contentsOf: kids.map { ($0, false) })
            }
        }
    }
    return nil
}

private func closeSettingsWindow(app: AXUIElement) {
    var windowsVal: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsVal) == .success,
          let windows = windowsVal as? [AXUIElement],
          let win = windows.first else { return }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, kAXChildrenAttribute as CFString, &children) == .success,
          let kids = children as? [AXUIElement] else { return }
    for kid in kids {
        var srVal: CFTypeRef?
        AXUIElementCopyAttributeValue(kid, kAXSubroleAttribute as CFString, &srVal)
        if let sr = srVal as? String, sr == (kAXCloseButtonSubrole as String) {
            AXUIElementPerformAction(kid, kAXPressAction as CFString)
            return
        }
    }
}

func applyLockScreenAutomation(tileName: String, completion: @escaping (Bool) -> Void) {
    Task { @MainActor in
        let ok = await selectFirstLiveWallpaperTile()
        completion(ok)
    }
}


