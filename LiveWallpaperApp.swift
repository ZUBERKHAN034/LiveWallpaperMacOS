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
@preconcurrency import ApplicationServices
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

nonisolated(unsafe) func applyLockScreenAutomation(tileName: String, completion: @escaping (Bool) -> Void) {
    guard AXIsProcessTrusted() else { completion(false); return }
    DispatchQueue.main.async {
        completion(lsaRun(tileName: tileName))
    }
}

nonisolated(unsafe) func lsaRun(tileName: String) -> Bool {
    guard let u = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { return false }
    NSWorkspace.shared.open(u)
    guard let w = lsaWin(8) else { return false }
    guard let c = lsaBtn(w, "LiveWallpaper") else { return false }
    guard AXShimPerformAction(c, "AXPress" as CFString) else { return false }
    Thread.sleep(forTimeInterval: 1)
    guard let w2 = lsaWin(5) else { return false }
    guard let t = lsaBtn(w2, tileName) else { return false }
    guard AXShimPerformAction(t, "AXPress" as CFString) else { return false }
    return true
}

nonisolated(unsafe) func lsaWin(_ to: TimeInterval) -> AXUIElement? {
    let e = Date().addingTimeInterval(to)
    while Date() < e {
        if let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) {
            let r = AXShimCreateApplication(a.processIdentifier)
            if let list = lsaCast(AXShimCopyAttr(r, "AXWindows" as CFString)) as? [AXUIElement] {
                for w in list {
                    if let s = lsaCast(AXShimCopyAttr(w, "AXTitle" as CFString)) as? String,
                       s.localizedCaseInsensitiveContains("wallpaper") { return w }
                }
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return nil
}

nonisolated(unsafe) func lsaBtn(_ p: AXUIElement, _ n: String) -> AXUIElement? {
    var q: [AXUIElement] = [p]
    while !q.isEmpty {
        let x = q.removeFirst()
        if let r = lsaCast(AXShimCopyAttr(x, "AXRole" as CFString)) as? String, r == "AXButton",
           let d = lsaCast(AXShimCopyAttr(x, "AXDescription" as CFString)) as? String,
           d.localizedCaseInsensitiveContains(n) { return x }
        if let k = lsaCast(AXShimCopyAttr(x, "AXChildren" as CFString)) as? [AXUIElement] {
            q.append(contentsOf: k)
        }
    }
    return nil
}

nonisolated(unsafe) private func lsaCast(_ v: CFTypeRef?) -> CFTypeRef? { return v }


