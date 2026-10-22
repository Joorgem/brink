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
            .combineLatest(themeStore.$showPercentInMenuBar)
            .sink { [weak self] snapshots, showPercent in
                self?.updateButton(snapshots, showPercent: showPercent)
            }
    }

    // MARK: Status item

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Brink")
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "Brink")
        image?.isTemplate = true
        return image
    }()

    /// Title = the highest primary window across accounts with real data, so the
    /// account closest to its limit is what you see without opening anything.
    private func updateButton(_ snapshots: [ProviderSnapshot], showPercent: Bool) {
        guard let button = statusItem.button else { return }
        let highest = snapshots
            .filter { !$0.isDemo }
            .compactMap { $0.primary?.usedPercent }
            .max()
        guard showPercent, let highest else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            return
        }
        button.imagePosition = .imageLeading
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 0.5]
        if highest >= 90 { attributes[.foregroundColor] = NSColor.systemRed }
        button.attributedTitle = NSAttributedString(string: " \(Int(highest.rounded()))%", attributes: attributes)
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
