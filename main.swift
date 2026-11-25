import AppKit
import ServiceManagement
import SwiftUI

func wantsFullScreen(_ id: String?, held: Bool, always: [String]) -> Bool {
    held || (id.map(always.contains) ?? false)
}

if CommandLine.arguments.contains("--check") {
    precondition(wantsFullScreen("a", held: true, always: []))
    precondition(wantsFullScreen("a", held: false, always: ["a"]))
    precondition(!wantsFullScreen("a", held: false, always: ["b"]))
    precondition(!wantsFullScreen(nil, held: false, always: ["a"]))
    let safari = URL(fileURLWithPath: "/Applications/Safari.app")
    precondition(matchApp("Safari", in: ["safari": safari]) == safari)
    precondition(matchApp("Safari.app, Application", in: ["safari": safari]) == safari)
    precondition(matchApp("Safari notes", in: ["safari": safari]) == nil)
    precondition(matchApp("Safari — Application", in: ["safari": safari]) == safari)
    let list = CGRect(x: 0, y: 0, width: 640, height: 447), line = CGRect(x: 40, y: 100, width: 80, height: 20)
    precondition(sameRow(line, container: list, cursor: CGPoint(x: 500, y: 105)))
    precondition(!sameRow(line, container: list, cursor: CGPoint(x: 500, y: 160)))
    precondition(sameRow(line, container: CGRect(x: 0, y: 60, width: 90, height: 110), cursor: CGPoint(x: 40, y: 70)))
    precondition(!sameRow(nil, container: nil, cursor: .zero))
    precondition(installedApps()["safari"] != nil && installedApps()["chess"] != nil)
    let icon = CGRect(x: 400, y: 10, width: 60, height: 60), size = CGSize(width: 200, height: 150)
    precondition(menuOrigin(icon: icon, menu: size, dock: "bottom") == CGPoint(x: 330, y: 228))
    precondition(menuOrigin(icon: icon, menu: size, dock: "left") == CGPoint(x: 468, y: 115))
    precondition(menuOrigin(icon: icon, menu: size, dock: "right") == CGPoint(x: 192, y: 115))
    print("ok")
    exit(0)
}

final class Delegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var heldLaunches: Set<pid_t> = []
    lazy var rightClick = RightClick { [unowned self] in openApp($0) }
    var welcome: NSWindow?
    var always: [String] {
        get { UserDefaults.standard.stringArray(forKey: "always") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "always") }
    }
    var keyDown: Bool { CGEventSource.flagsState(.combinedSessionState).contains(HoldKey.current.cg) }

    func applicationDidFinishLaunching(_ n: Notification) {
        status.button?.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right",
                                       accessibilityDescription: "FullOpen")
        status.menu = NSMenu()
        status.menu?.delegate = self
        NSApp.servicesProvider = self
        // Check the key at will-launch too, so it can be released while a slow app loads.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main) { [self] n in
            if keyDown, let app = launched(n) { heldLaunches.insert(app.processIdentifier) }
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [self] n in
            guard let app = launched(n) else { return }
            let held = heldLaunches.remove(app.processIdentifier) != nil || keyDown
            if app.activationPolicy == .regular,
               wantsFullScreen(app.bundleIdentifier, held: held, always: always) { fullScreen(app) }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(finderMenu), name: .init("com.abhishek.fullopen.open"), object: nil,
            suspensionBehavior: .deliverImmediately)
        // The permission can be granted at any time, so keep checking until it is.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] t in
            if AXIsProcessTrusted() { rightClick.start(); t.invalidate() }
        }
        if !UserDefaults.standard.bool(forKey: "welcomed") || !AXIsProcessTrusted() { showWelcome() }
    }

    func launched(_ n: Notification) -> NSRunningApplication? {
        n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    /// Retries until the app has a real window and reports it as full screen.
    // shortcut: gives up after 20s; raise it if slow apps miss.
    func fullScreen(_ app: NSRunningApplication) {
        let deadline = Date().addingTimeInterval(20)
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { t in
            if app.isTerminated || Date() > deadline { return t.invalidate() }
            guard let windows = axGet(ax, kAXWindowsAttribute) as? [AXUIElement],
                  let w = windows.first(where: { axGet($0, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole })
            else { return }
            if axGet(w, "AXFullScreen") as? Bool == true { return t.invalidate() }
            AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanTrue)
        }
    }

    /// Finder right-click service.
    @objc func openFullScreen(_ pb: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        urls.filter { $0.pathExtension == "app" }.forEach(openApp)
    }

    /// From the FinderMenu extension. Any process can post this, so accept only real app bundles.
    @objc func finderMenu(_ n: Notification) {
        guard let path = n.object as? String, path.hasSuffix(".app"), Bundle(path: path)?.bundleIdentifier != nil else { return }
        openApp(URL(fileURLWithPath: path))
    }

    func openApp(_ url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { app, error in
            if let error { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
            if let app { DispatchQueue.main.async { self.fullScreen(app) } }
        }
    }

    @objc func showWelcome() {
        UserDefaults.standard.set(true, forKey: "welcomed")
        NSApp.activate(ignoringOtherApps: true)
        if welcome == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Welcome { [unowned self] in welcome?.close() }))
            w.styleMask = [.titled, .closable]
            w.title = "FullOpen"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setContentSize(w.contentViewController!.view.fittingSize)
            w.center()
            welcome = w
        }
        welcome?.makeKeyAndOrderFront(nil)
    }

    // Drop the window so its key and permission polling stops.
    func windowWillClose(_ n: Notification) { welcome = nil }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !AXIsProcessTrusted() { add(menu, "Allow Accessibility…", #selector(showWelcome)) }
        menu.addItem(.init(title: "Hold \(HoldKey.current.name) while opening an app", action: nil, keyEquivalent: ""))
        add(menu, "How It Works and Settings…", #selector(showWelcome))
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Always Full Screen"))
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
        let rows = Set(running + always).map { id in
            (id, NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                .map { FileManager.default.displayName(atPath: $0.path) } ?? id)
        }
        for (id, name) in rows.sorted(by: { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }) {
            let item = add(menu, name, #selector(toggleAlways))
            item.representedObject = id
            item.state = always.contains(id) ? .on : .off
        }
        menu.addItem(.separator())
        add(menu, "Launch at Login", #selector(toggleLogin)).state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.init(title: "Quit FullOpen", action: #selector(NSApplication.terminate), keyEquivalent: "q"))
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc func toggleAlways(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        always = always.contains(id) ? always.filter { $0 != id } : always + [id]
    }

    @objc func toggleLogin() {
        do {
            let s = SMAppService.mainApp
            try s.status == .enabled ? s.unregister() : s.register()
        } catch { NSApp.presentError(error) }
    }
}

let delegate = Delegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
