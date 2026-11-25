import Cocoa
import FinderSync

@objc(FinderMenu)
final class FinderMenu: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    var apps: [URL] { (FIFinderSyncController.default().selectedItemURLs() ?? []).filter { $0.pathExtension == "app" } }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForItems, !apps.isEmpty else { return nil }
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Open in Full Screen", action: #selector(open), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        return menu
    }

    @objc func open(_ sender: Any?) {
        for url in apps {
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.abhishek.fullopen.open"), object: url.path, userInfo: nil, deliverImmediately: true)
        }
    }
}
