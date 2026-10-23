import Foundation
import SwiftUI
import Combine

// MARK: - Data model

struct UsageWindow: Identifiable, Codable {
    var id: String { label }
    var label: String            // "Current session", "Weekly limit"...
    var usedPercent: Double      // 0...100
    var resetsAt: Date?

    var fraction: Double { min(max(usedPercent / 100.0, 0), 1) }

    var resetText: String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSinceNow
        if seconds <= 0 { return L("Resets soon") }
        if seconds < 3600 {
            return L("Resets in %d min", Int(seconds / 60))
        }
        if seconds < 86400 {
            let h = Int(seconds / 3600)
            let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? L("Resets in %d h %d min", h, m) : L("Resets in %d h", h)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm"
        return L("Resets %@", fmt.string(from: resetsAt))
    }

    /// When and how long until: "Resets 16:30 · in 2 h 10 min" today,
    /// "Resets Thu 14:00 · in 2 d 3 h" on another day. Used under the bars.
    var resetDetail: String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSinceNow
        if seconds <= 0 { return L("Resets soon") }
        let fmt = DateFormatter()
        if !L10n.override.isEmpty { fmt.locale = Locale(identifier: L10n.override) }
        fmt.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(resetsAt) ? "Hm" : "EEEHm")
        let minutes = Int(seconds / 60)
        let remaining: String
        if minutes < 60 {
            remaining = L("%d min", max(1, minutes))
        } else if minutes < 24 * 60 {
            remaining = minutes % 60 > 0 ? L("%d h %d min", minutes / 60, minutes % 60) : L("%d h", minutes / 60)
        } else {
            let hours = minutes / 60
            remaining = hours % 24 > 0 ? L("%d d %d h", hours / 24, hours % 24) : L("%d d", hours / 24)
        }
        return L("Resets %@ · in %@", fmt.string(from: resetsAt), remaining)
    }
}

struct ProviderSnapshot: Identifiable {
    var id: String               // provider id from fetch(); the store swaps in the account id
    var name: String
    var systemImage: String
    var windows: [UsageWindow]
    var error: String?
    var isDemo: Bool = false
    var accent: Color? = nil     // fixed brand color; nil = percent-based scale
    var updatedAt: Date?
    var provider: String = ""    // "claude", "codex", "cursor"
    var accountName: String = ""
    var isDefaultLogin: Bool = false

    var primary: UsageWindow? { windows.first }

    /// The week-long window, "Weekly limit" for both Claude and Codex.
    var weekly: UsageWindow? {
        windows.first { $0.label == "Weekly limit" }
    }

    /// "Claude · Work" — used in notifications, where several accounts can share a provider.
    var displayName: String {
        accountName.isEmpty || accountName == name ? name : "\(name) · \(accountName)"
    }
}

// MARK: - Ring color scale

enum UsageColor {
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34) // #D97757

    static func color(for snapshot: ProviderSnapshot, percent: Double) -> Color {
        snapshot.accent ?? color(for: percent)
    }

    static func color(for percent: Double) -> Color {
        if percent < 50.0 { return Color(red: 0x2f/255, green: 0xd4/255, blue: 0x87/255) } // #2FD487
        if percent < 70.0 { return Color(red: 0xf2/255, green: 0xdf/255, blue: 0x2a/255) } // #F2DF2A
        return Color(red: 1.0, green: 0x44/255, blue: 0.0)                                 // #FF4400
    }
}

// MARK: - Provider protocol

protocol UsageProvider {
    var id: String { get }
    func fetch() async -> ProviderSnapshot
}

// MARK: - Store

/// Holds one snapshot per account, in the order the accounts were added.
/// Follows `AccountStore`: a new account is fetched right away, a removed one
/// disappears with its provider (and that provider's caches).
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    private let accountStore: AccountStore
    private var accounts: [Account] = []
    private var providers: [UUID: UsageProvider] = [:]
    private var timer: Timer?
    private var accountsObserver: AnyCancellable?

    init(accounts accountStore: AccountStore) {
        self.accountStore = accountStore
        sync(accountStore.activeAccounts, fetchNew: false)
        accountsObserver = accountStore.$activeAccounts
            .dropFirst()
            .sink { [weak self] list in
                Task { @MainActor [weak self] in self?.sync(list, fetchNew: true) }
            }
    }

    func snapshot(for account: Account) -> ProviderSnapshot? {
        snapshots.first { $0.id == account.id.uuidString }
    }

    func startAutoRefresh(interval: TimeInterval = 120) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refreshAll() }
        }
        timer?.tolerance = interval * 0.2   // let macOS coalesce wake-ups
        refreshAll()
    }

    /// Opening the popover refreshes only if the numbers are older than `age`.
    func refreshIfStale(olderThan age: TimeInterval = 60) {
        guard let last = lastRefresh else { return refreshAll() }
        if Date().timeIntervalSince(last) > age { refreshAll() }
    }

    func refreshAll() {
        refresh(accounts)
    }

    /// Rebuilds the provider list after accounts change. Existing providers are
    /// kept (with their token caches and 429 back-off); new ones get a blank
    /// card and, when `fetchNew`, an immediate fetch.
    private func sync(_ list: [Account], fetchNew: Bool) {
        let previous = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        var kept: [UUID: UsageProvider] = [:]
        var added: [Account] = []
        for account in list {
            if let existing = providers[account.id] {
                kept[account.id] = existing
            } else {
                kept[account.id] = account.makeProvider()
                added.append(account)
            }
        }
        providers = kept
        accounts = list
        snapshots = list.map { account in
            var snap = previous[account.id.uuidString]
                ?? ProviderSnapshot(id: "", name: "", systemImage: "hourglass", windows: [], error: nil)
            Self.label(&snap, with: account)
            return snap
        }
        if fetchNew && !added.isEmpty { refresh(added) }
    }

    private static func label(_ snap: inout ProviderSnapshot, with account: Account) {
        snap.id = account.id.uuidString
        snap.provider = account.provider.rawValue
        snap.name = account.provider.displayName
        snap.accountName = account.name
        snap.isDefaultLogin = account.isDefaultLogin
    }

    /// Fetches the given accounts at once and publishes each result as it lands,
    /// so one slow or rate-limited source never leaves the others blank. Cards
    /// keep their previous values until their own account answers.
    private func refresh(_ targets: [Account]) {
        let jobs = targets.compactMap { account in providers[account.id].map { (account, $0) } }
        guard !jobs.isEmpty else { return }
        isRefreshing = true
        Task {
            await withTaskGroup(of: (Account, ProviderSnapshot).self) { group in
                for (account, provider) in jobs {
                    group.addTask { (account, await provider.fetch()) }
                }
                for await (account, fetched) in group {
                    var snap = fetched
                    Self.label(&snap, with: account)
                    // The account may have been removed (or renamed) while we waited.
                    guard let i = self.accounts.firstIndex(where: { $0.id == account.id }) else { continue }
                    Self.label(&snap, with: self.accounts[i])
                    if let j = self.snapshots.firstIndex(where: { $0.id == snap.id }) {
                        self.snapshots[j] = snap
                    }
                    self.lastRefresh = Date()
                }
            }
            isRefreshing = false
            // Notifications and limit attribution only once the picture is complete.
            Notifier.shared.observe(snapshots)
            CostModel.shared.observe(snapshots)
        }
    }
}
