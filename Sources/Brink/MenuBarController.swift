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
            .combineLatest(themeStore.$menuBarAccount, themeStore.$menuBarMetric)
            .sink { [weak self] snapshots, chosen, metric in
                self?.updateButton(snapshots, chosen: chosen, metric: metric)
            }
    }

    // MARK: Status item

    private static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "Brink")
            ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "Brink")
        image?.isTemplate = true
        return image
    }()

    /// Title = the limit(s) the user picked for the chosen account: "73%" for
    /// one, "5h 73%  7d 12%" for both. Icon only when nothing is picked or there
    /// is no data yet.
    private func updateButton(_ snapshots: [ProviderSnapshot], chosen: String,
                              metric: ThemeStore.MenuBarMetric) {
        guard let button = statusItem.button else { return }
        let snap = snapshots.first { $0.id == chosen && !$0.isDemo }
        let parts: [(tag: String, window: UsageWindow)]
        switch metric {
        case .session: parts = snap?.primary.map { [("", $0)] } ?? []
        case .weekly: parts = (snap?.weekly ?? snap?.primary).map { [("", $0)] } ?? []
        case .both:
            parts = [snap?.primary.map { ("5h", $0) }, snap?.weekly.map { ("7d", $0) }].compactMap { $0 }
        }
        button.toolTip = snap.map { snap in
            (["Brink · \(snap.displayName)"] + parts.map { "\(L($0.window.label)): \(Int($0.window.usedPercent.rounded()))%" })
                .joined(separator: "\n")
        } ?? "Brink"
        // With an account picked the number alone is the status item; the icon
        // only shows when there's nothing to show, so the item stays clickable.
        guard !parts.isEmpty else {
            button.image = Self.icon
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            return
        }
        button.image = nil
        button.imagePosition = .noImage
        let size = NSFont.systemFontSize - 1
        let number = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
        let tag = NSFont.systemFont(ofSize: size - 3, weight: .semibold)
        let title = NSMutableAttributedString()
        // Single-part titles drop the tag, since the setting already says which limit it is.
        let tagged = parts.count > 1
        for (i, part) in parts.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: number])) }
            if tagged {
                title.append(NSAttributedString(string: part.tag + " ", attributes: [
                    .font: tag, .baselineOffset: 1, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            let percent = part.window.usedPercent
            var attributes: [NSAttributedString.Key: Any] = [.font: number, .baselineOffset: 0.5]
            if percent >= 90 { attributes[.foregroundColor] = NSColor.systemRed }
            title.append(NSAttributedString(string: "\(Int(percent.rounded()))%", attributes: attributes))
        }
        button.attributedTitle = title
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
        store.refreshIfStale(olderThan: 180)
    }

    func popoverDidClose(_ notification: Notification) {
        // Release the hosting controller and its whole SwiftUI tree.
        popover?.contentViewController = nil
        popover = nil
    }
}
