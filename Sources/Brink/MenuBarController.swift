import AppKit
import SwiftUI
import Combine

/// The whole UI: one status item in the menu bar and a popover that is built
/// when clicked and thrown away when it closes. Between clicks Brink keeps no
/// windows or SwiftUI views alive, only the status item and the latest numbers.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let store: UsageStore
    private let accounts: AccountStore
    private let themeStore: ThemeStore
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var observer: AnyCancellable?

    init(store: UsageStore, accounts: AccountStore, themeStore: ThemeStore) {
        self.store = store
        self.accounts = accounts
        self.themeStore = themeStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.icon
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Brink"
        }

        observer = store.$snapshots
            .combineLatest(themeStore.$menuBarAccount)
            .sink { [weak self] snapshots, chosen in
                self?.updateButton(snapshots, chosen: chosen)
            }
    }

    // MARK: Status item

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Brink")
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "Brink")
        image?.isTemplate = true
        return image
    }()

    /// Title = the primary window (usually the current session) of the account
    /// the user picked; icon only when none is picked or it has no data yet.
    private func updateButton(_ snapshots: [ProviderSnapshot], chosen: String) {
        guard let button = statusItem.button else { return }
        let snap = snapshots.first { $0.id == chosen && !$0.isDemo }
        button.toolTip = snap.map { "Brink · \($0.displayName)" } ?? "Brink"
        guard let percent = snap?.primary?.usedPercent else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            return
        }
        button.imagePosition = .imageLeading
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0.5]
        if percent >= 90 { attributes[.foregroundColor] = NSColor.systemRed }
        button.attributedTitle = NSAttributedString(string: " \(Int(percent.rounded()))%", attributes: attributes)
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        let content = PopoverView(store: store, accounts: accounts, themeStore: themeStore)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = host
        self.popover = popover

        // An accessory app has to activate for text fields (rename, add account) to get focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        store.refreshIfStale()
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the hosting controller and its whole SwiftUI tree.
        popover?.contentViewController = nil
        popover = nil
    }
}
