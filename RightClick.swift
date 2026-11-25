import AppKit
import os

let log = Logger(subsystem: "com.abhishek.fullopen", category: "rightclick")

func axGet(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, attribute as CFString, &v)
    return v
}

// MARK: Which app is under the cursor?

/// Finder is absent on purpose: it has its own extension in FinderMenu/.
let launchers: Set = ["com.apple.dock", "com.apple.Spotlight", "com.apple.apps.launcher",
                          "com.raycast.macos", "com.runningwithcrayons.Alfred"]

func installedApps() -> [String: URL] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser.path
    var found: [String: URL] = [:]
    for dir in ["/System/Library/CoreServices/Applications", "/System/Applications", "/System/Applications/Utilities",
                "/System/Cryptexes/App/System/Applications", "/Applications", "/Applications/Utilities", home + "/Applications"] {
        for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where file.hasSuffix(".app") {
            let url = URL(fileURLWithPath: dir + "/" + file)
            for name in [file, fm.displayName(atPath: url.path)] { found[plainName(name)] = url }
        }
    }
    return found
}

func plainName(_ s: String) -> String {
    (s.hasSuffix(".app") ? String(s.dropLast(4)) : s).trimmingCharacters(in: .whitespaces).lowercased()
}

/// Launchers label rows "Safari" or "Safari, Application".
func matchApp(_ label: String, in apps: [String: URL]) -> URL? {
    apps[plainName(label)] ?? label.firstIndex(of: ",").flatMap { apps[plainName(String(label[..<$0]))] }
}

func appURL(_ e: AXUIElement) -> URL? {
    guard let v = axGet(e, kAXURLAttribute) else { return nil }
    let url = (v as? URL) ?? (v as? String).flatMap(URL.init(string:))
    guard let file = (url as NSURL?)?.filePathURL, file.pathExtension == "app" else { return nil }
    return file
}

struct Hit { let url: URL; let owner: String; let element: AXUIElement }

func appUnder(_ p: CGPoint) -> Hit? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.2)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success, let hit else { return nil }
    var pid: pid_t = 0
    AXUIElementGetPid(hit, &pid)
    guard let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
          launchers.contains(owner) else { return nil }

    let apps = installedApps()
    // The whole lookup runs while the click waits, so it must end quickly.
    let deadline = Date().addingTimeInterval(0.3)
    var level: AXUIElement? = hit
    for _ in 0..<5 {
        guard let e = level, Date() < deadline else { break }
        var matches: Set<URL> = []
        var queue = [(e, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 25, Date() < deadline {
            let (node, depth) = queue.removeFirst()
            seen += 1
            if let url = appURL(node) {
                matches.insert(url)
            } else {
                for a in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                    if let s = axGet(node, a) as? String, let url = matchApp(s, in: apps) { matches.insert(url) }
                }
            }
            if depth < 3, let kids = axGet(node, kAXChildrenAttribute) as? [AXUIElement] {
                queue += kids.map { ($0, depth + 1) }
            }
        }
        if matches.count > 1 { break } // climbed into a list of several apps
        if let url = matches.first {
            log.info("right-click in \(owner, privacy: .public): \(url.lastPathComponent, privacy: .public)")
            return Hit(url: url, owner: owner, element: hit)
        }
        level = axGet(e, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    let role = axGet(hit, kAXRoleAttribute) as? String ?? "?"
    log.info("right-click in \(owner, privacy: .public): no app, role \(role, privacy: .public)")
    return nil
}

// MARK: The menu

/// Where the menu's top-left corner goes, in Cocoa coordinates, so it clears the Dock icon.
func menuOrigin(icon: CGRect, menu: CGSize, dock: String) -> CGPoint {
    switch dock {
    case "left": return CGPoint(x: icon.maxX + 8, y: icon.midY + menu.height / 2)
    case "right": return CGPoint(x: icon.minX - 8 - menu.width, y: icon.midY + menu.height / 2)
    default: return CGPoint(x: icon.midX - menu.width / 2, y: icon.maxY + 8 + menu.height)
    }
}

func flip(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - r.maxY, width: r.width, height: r.height)
}

func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = axGet(e, kAXPositionAttribute), let s = axGet(e, kAXSizeAttribute) else { return nil }
    var r = CGRect.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &r.origin), AXValueGetValue(s as! AXValue, .cgSize, &r.size) else { return nil }
    return r
}

final class ActionItem: NSMenuItem {
    let run: () -> Void
    init(_ title: String, symbol: String? = nil, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { run() }
}

final class RightClick {
    let open: (URL) -> Void
    var tap: CFMachPort?
    var swallowUp: CGEventType? // tap thread only
    var current: NSMenu?

    init(open: @escaping (URL) -> Void) { self.open = open }

    /// Needs Accessibility. Runs on its own thread so a busy main thread never delays clicks.
    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.rightMouseDown, .rightMouseUp, .leftMouseDown, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, me in
            Unmanaged<RightClick>.fromOpaque(me!).takeUnretainedValue().swallows(type, event)
                ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return log.error("event tap refused") }
        Thread.detachNewThread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CFRunLoopRun()
        }
    }

    /// True when FullOpen's menu replaces the click. Option-right-click always passes through.
    func swallows(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            swallowUp = nil
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .rightMouseUp, .leftMouseUp:
            defer { if type == swallowUp { swallowUp = nil } }
            return type == swallowUp
        default:
            let secondary = type == .rightMouseDown || event.flags.contains(.maskControl)
            guard secondary, !event.flags.contains(.maskAlternate), let hit = appUnder(event.location) else { return false }
            swallowUp = type == .rightMouseDown ? .rightMouseUp : .leftMouseUp
            let p = event.location
            onMain([.commonModes]) { self.show(hit, at: p) }
            return true
        }
    }

    func menu(for hit: Hit) -> NSMenu {
        let id = Bundle(url: hit.url)?.bundleIdentifier
        let running = id.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem("Open in Full Screen", symbol: "arrow.up.left.and.arrow.down.right") { self.open(hit.url) })
        menu.addItem(ActionItem(running == nil ? "Open" : "Show") {
            NSWorkspace.shared.openApplication(at: hit.url, configuration: .init())
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hit.url]) })
        if let running {
            menu.addItem(ActionItem("Hide") { running.hide() })
            if id != "com.apple.finder" { menu.addItem(ActionItem("Quit") { running.terminate() }) }
        }
        if hit.owner == "com.apple.dock" {
            menu.addItem(.separator())
            menu.addItem(ActionItem("More Dock Options…") {
                // Blocks while the Dock's menu is open, so keep it off the main thread.
                DispatchQueue.global().async { AXUIElementPerformAction(hit.element, kAXShowMenuAction as CFString) }
            })
        }
        return menu
    }

    /// Not the main queue: that stays blocked while a menu is open.
    func onMain(_ modes: [CFRunLoopMode], _ work: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), modes.map(\.rawValue) as CFArray, work)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    func show(_ hit: Hit, at p: CGPoint) {
        // The click never reached the open menu, so close it here and reopen once it is gone.
        if let current {
            current.cancelTrackingWithoutAnimation()
            return onMain([.defaultMode]) { self.show(hit, at: p) }
        }
        let menu = menu(for: hit)
        var origin = flip(CGRect(origin: p, size: .zero)).origin
        if hit.owner == "com.apple.dock", let icon = axFrame(hit.element) {
            let dock = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
            origin = menuOrigin(icon: flip(icon), menu: menu.size, dock: dock)
        }
        current = menu
        menu.popUp(positioning: nil, at: origin, in: nil)
        current = nil
    }
}
