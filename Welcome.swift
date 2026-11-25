import Combine
import FinderSync
import SwiftUI

struct HoldKey: Identifiable {
    let id, symbol, name, note: String
    let cg: CGEventFlags

    // Control is missing on purpose: Control-click is a right-click.
    static let all = [
        HoldKey(id: "shift", symbol: "⇧", name: "Shift", note: "Works everywhere. Some apps won't reopen their last windows.", cg: .maskShift),
        HoldKey(id: "option", symbol: "⌥", name: "Option", note: "In the Dock, Option also hides the app you were in.", cg: .maskAlternate),
        HoldKey(id: "command", symbol: "⌘", name: "Command", note: "Not for the Dock: Command-click there shows the app in Finder.", cg: .maskCommand),
        HoldKey(id: "fn", symbol: "fn", name: "Fn", note: "Needs an Apple keyboard.", cg: .maskSecondaryFn),
    ]
    static func find(_ id: String) -> HoldKey { all.first { $0.id == id } ?? all[0] }
    static var current: HoldKey { find(UserDefaults.standard.string(forKey: "holdKey") ?? "shift") }
}

// Not @State: in the macOS 27 SDK that is a macro whose plugin ships only with full Xcode.
final class WelcomeState: ObservableObject {
    @Published var held = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var finderOn = FIFinderSyncController.isExtensionEnabled
}

struct Welcome: View {
    @AppStorage("holdKey") var holdKey = "shift"
    @StateObject var state = WelcomeState()
    let done: () -> Void
    let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        let key = HoldKey.find(holdKey)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open any app in full screen").font(.title.bold())
                Text("Two ways. Takes a minute to set up.").foregroundStyle(.secondary)
            }
            row {
                Text(key.symbol).font(.system(size: 26, weight: .medium))
                    .frame(width: 56, height: 56)
                    .foregroundStyle(state.held ? .white : .primary)
                    .background(RoundedRectangle(cornerRadius: 12).fill(state.held ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)))
                    .accessibilityLabel("\(key.name) key")
            } text: {
                Text("Hold \(key.name) while opening an app").font(.headline)
                Text("Keep holding until it appears. Press it now to try: the key lights up.").foregroundStyle(.secondary)
                Picker("Key", selection: $holdKey) {
                    ForEach(HoldKey.all) { Text($0.name).tag($0.id) }
                }.pickerStyle(.segmented).labelsHidden().padding(.top, 4)
                Text(key.note).font(.callout).foregroundStyle(.secondary)
            }
            row {
                Image(systemName: "cursorarrow.click.2").font(.system(size: 24))
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            } text: {
                Text("Or right-click the app").font(.headline)
                Text("Open in Full Screen is the first option. In the Dock, the usual choices are under More Dock Options, or Option-right-click.").foregroundStyle(.secondary)
                if !state.finderOn {
                    Button("Add to Finder's menu…") { FIFinderSyncController.showExtensionManagementInterface() }.padding(.top, 4)
                }
            }
            row {
                Image(systemName: state.trusted ? "checkmark.circle.fill" : "lock.fill").font(.system(size: 24))
                    .foregroundStyle(state.trusted ? .green : .orange)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            } text: {
                Text(state.trusted ? "Accessibility is on" : "Allow Accessibility").font(.headline)
                Text("Used to see which app you clicked and to make its window full screen. Nothing leaves your Mac.").foregroundStyle(.secondary)
                if !state.trusted {
                    Button("Allow…") {
                        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                    }.padding(.top, 4)
                }
            }
            HStack {
                Text("Reopen this from the menu bar icon.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(28)
        .frame(width: 500)
        .onReceive(tick) { _ in
            state.held = CGEventSource.flagsState(.combinedSessionState).contains(key.cg)
            state.trusted = AXIsProcessTrusted()
            state.finderOn = FIFinderSyncController.isExtensionEnabled
        }
    }

    func row(@ViewBuilder icon: () -> some View, @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 16) {
            icon()
            VStack(alignment: .leading, spacing: 4) { text() }
        }
    }
}
