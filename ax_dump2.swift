import AppKit
import ApplicationServices
import Foundation

let outPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/ax_dump2.txt").path

func log(_ msg: String) {
    print(msg)
    fflush(stdout)
    if let fh = FileHandle(forWritingAtPath: outPath) {
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data((msg + "\n").utf8))
        try? fh.close()
    } else {
        try? (msg + "\n").data(using: .utf8)?.write(to: URL(fileURLWithPath: outPath), options: .atomic)
    }
}

guard AXIsProcessTrusted() else {
    log("AX not trusted — run again")
    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary)
    exit(1)
}
log("AX trusted ✓")

guard let u = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") else { exit(1) }
NSWorkspace.shared.open(u)

var rootElem: AXUIElement? = nil
let deadline = Date().timeIntervalSince1970 + 10
while Date().timeIntervalSince1970 < deadline {
    if let sp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) {
        let app = AXUIElementCreateApplication(sp.processIdentifier)
        var windowsVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsVal) == .success,
           let windows = windowsVal as? [AXUIElement], windows.count > 0 {
            rootElem = windows[0]
            var titleVal: CFTypeRef?
            AXUIElementCopyAttributeValue(rootElem!, kAXTitleAttribute as CFString, &titleVal)
            log("Found window: '\(titleVal as? String ?? "")'")
            break
        }
    }
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.2))
}
guard let root = rootElem else { log("FAILED: no window"); exit(1) }

// Collect all attributes of an element
func attrs(_ elem: AXUIElement) -> [String:String] {
    var result = [String:String]()
    for attr in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                 kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute] {
        var val: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, attr as CFString, &val) == .success {
            let key = (attr as CFString as String)
            if key == "AXRole" { result["role"] = val as? String ?? "" }
            else if key == "AXSubrole" { result["subrole"] = val as? String ?? "" }
            else if key == "AXTitle" { result["title"] = val as? String ?? "" }
            else if key == "AXDescription" { result["desc"] = val as? String ?? "" }
            else if key == "AXValue" { result["value"] = val as? String ?? "" }
            else if key == "AXIdentifier" { result["id"] = val as? String ?? "" }
        }
    }
    return result
}

func fmt(_ a: [String:String]) -> String {
    var parts: [String] = []
    if let r = a["role"], !r.isEmpty { parts.append(r) }
    if let s = a["subrole"], !s.isEmpty { parts.append(s) }
    if let t = a["title"], !t.isEmpty { parts.append("title='\(t)'") }
    if let d = a["desc"], !d.isEmpty { parts.append("desc='\(d)'") }
    if let v = a["value"], !v.isEmpty, v.count < 60 { parts.append("value='\(v)'") }
    if let i = a["id"], !i.isEmpty { parts.append("id='\(i)'") }
    return parts.joined(separator: " ")
}

let MATCH_TERMS = ["LiveWallpaper", "livewallpaper", "live wallpaper"]

// Phase 1: Find matches
log("\n=== PHASE 1: Find 'LiveWallpaper' elements ===")

func findMatches(_ elem: AXUIElement, _ ancestors: [(AXUIElement, [String:String])]) {
    let a = attrs(elem)
    let combined = "\(a["title"] ?? "") \(a["desc"] ?? "") \(a["value"] ?? "")"
    let matched = MATCH_TERMS.contains(where: { combined.localizedCaseInsensitiveContains($0) })

    if matched {
        log("\n--- MATCH: \(fmt(a)) ---")
        log("ANCESTORS:")
        for (i, anc) in ancestors.enumerated() {
            log("  [\(i)] \(fmt(anc.1))")
        }

        // Dump children
        var kidsVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &kidsVal) == .success,
           let kids = kidsVal as? [AXUIElement] {
            log("CHILDREN (\(kids.count)):")
            for (i, kid) in kids.enumerated() {
                let ka = attrs(kid)
                let pressable = (ka["role"] == "AXButton" || ka["role"] == "AXGroup" || ka["role"] == "AXMenuButton") ? " [PRESSABLE]" : ""
                log("  [\(i)] \(fmt(ka))\(pressable)")
            }
        } else {
            log("CHILDREN: none")
        }
    }

    var kidsVal: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &kidsVal) == .success,
       let kids = kidsVal as? [AXUIElement] {
        var newAncestors = ancestors
        newAncestors.append((elem, a))
        for kid in kids {
            findMatches(kid, newAncestors)
        }
    }
}

findMatches(root, [])

// Phase 2: Find the "LiveWallpaper" section header → find its parent → dump parent children
log("\n=== PHASE 2: 'LiveWallpaper' label → sibling tile grid ===")

func findLWAndDumpSiblings(_ elem: AXUIElement) {
    let a = attrs(elem)
    if a["title"] == "LiveWallpaper" || a["desc"] == "LiveWallpaper" || a["value"] == "LiveWallpaper" {
        log("\nFound exact 'LiveWallpaper': \(fmt(a))")
    }

    var kidsVal: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &kidsVal) == .success,
       let kids = kidsVal as? [AXUIElement] {
        for i in 0..<kids.count {
            let ka = attrs(kids[i])
            if ka["title"] == "LiveWallpaper" || ka["desc"] == "LiveWallpaper" || ka["value"] == "LiveWallpaper" {
                log("\nFOUND LiveWallpaper child[\(i)]: \(fmt(ka))")

                // Look at next sibling — that's our tile grid
                if i + 1 < kids.count {
                    log("NEXT SIBLING (expected tile grid):")
                    let next = kids[i + 1]
                    let na = attrs(next)
                    log("  child[\(i+1)]: \(fmt(na))")

                    // Dump grandkids
                    var gkids: CFTypeRef?
                    if AXUIElementCopyAttributeValue(next, kAXChildrenAttribute as CFString, &gkids) == .success,
                       let gk = gkids as? [AXUIElement] {
                        log("  GRANDKIDS (\(gk.count)):")
                        for (j, g) in gk.enumerated() {
                            let ga = attrs(g)
                            log("    [\(j)] \(fmt(ga))")
                            // Dump great-grandkids too
                            var ggkids: CFTypeRef?
                            if AXUIElementCopyAttributeValue(g, kAXChildrenAttribute as CFString, &ggkids) == .success,
                               let ggk = ggkids as? [AXUIElement] {
                                for (k, gg) in ggk.enumerated() {
                                    let gga = attrs(gg)
                                    let pressable = (gga["role"] == "AXButton") ? " [CLICKABLE TILE]" : ""
                                    log("      [\(k)] \(fmt(gga))\(pressable)")
                                }
                            }
                        }
                    }
                }
            }
        }
        for kid in kids { findLWAndDumpSiblings(kid) }
    }
}

findLWAndDumpSiblings(root)

// Phase 3: ScrollArea siblings — find the LiveWallpaper header text, then the next ScrollArea sibling
log("\n=== PHASE 3: Sibling pairs (StaticText+ScrollArea) in content ===")

func findStatixTextPlusNext(_ elem: AXUIElement) {
    var kidsVal: CFTypeRef?
    if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &kidsVal) == .success,
       let kids = kidsVal as? [AXUIElement] {
        for i in 0..<kids.count {
            let a = attrs(kids[i])
            let combined = "\(a["title"] ?? "") \(a["desc"] ?? "") \(a["value"] ?? "")"
            if combined.localizedCaseInsensitiveContains("lifewallpaper") {
                log("\nLABEL child[\(i)]: \(fmt(a))")
                if i + 1 < kids.count {
                    let next = kids[i + 1]
                    let na = attrs(next)
                    log("NEXT child[\(i+1)]: \(fmt(na))")
                    var gkids: CFTypeRef?
                    if AXUIElementCopyAttributeValue(next, kAXChildrenAttribute as CFString, &gkids) == .success,
                       let gk = gkids as? [AXUIElement] {
                        for (j, g) in gk.enumerated() {
                            let ga = attrs(g)
                            log("  grandkid[\(j)]: \(fmt(ga))")
                            var ggkids: CFTypeRef?
                            if AXUIElementCopyAttributeValue(g, kAXChildrenAttribute as CFString, &ggkids) == .success,
                               let ggk = ggkids as? [AXUIElement] {
                                for (k, gg) in ggk.enumerated() {
                                    let gga = attrs(gg)
                                    log("    tile[\(k)]: \(fmt(gga))")
                                }
                            }
                        }
                    }
                }
            }
        }
        for kid in kids { findStatixTextPlusNext(kid) }
    }
}

findStatixTextPlusNext(root)

log("\n=== DUMP COMPLETE ===")
log("Full output: \(outPath)")
