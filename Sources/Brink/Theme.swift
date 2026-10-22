import SwiftUI
import AppKit

// MARK: - Preferences (persisted)

@MainActor
final class ThemeStore: ObservableObject {
    private static let menuBarKey = "menuBarAccount"
    private static let metricKey = "menuBarMetric"

    /// Which limit of the chosen account the menu bar shows.
    enum MenuBarMetric: String, CaseIterable, Identifiable {
        case session, weekly, both
        var id: String { rawValue }
        var title: String {
            switch self {
            case .session: return L("Current session")
            case .weekly: return L("Weekly limit")
            case .both: return L("Both")
            }
        }
    }

    /// "" = system default; otherwise a code from L10n.available. Changing it
    /// re-renders every view (they observe this store), so it applies instantly.
    @Published var language: String = L10n.override {
        didSet { L10n.override = language }
    }

    /// The account whose usage sits next to the menu bar icon ("73%"), by
    /// account id. "" = icon only. Defaults to the first account.
    @Published var menuBarAccount: String {
        didSet { UserDefaults.standard.set(menuBarAccount, forKey: Self.menuBarKey) }
    }

    @Published var menuBarMetric: MenuBarMetric {
        didSet { UserDefaults.standard.set(menuBarMetric.rawValue, forKey: Self.metricKey) }
    }

    init(defaultMenuBarAccount: String) {
        menuBarAccount = UserDefaults.standard.string(forKey: Self.menuBarKey) ?? defaultMenuBarAccount
        menuBarMetric = UserDefaults.standard.string(forKey: Self.metricKey)
            .flatMap(MenuBarMetric.init(rawValue:)) ?? .session
    }
}

// MARK: - Palette
//
// The popover draws on the system's own material, so the palette just follows
// the menu bar's light/dark appearance through the semantic colours.

struct Palette {
    var fg: Color
    var muted: Color
    var soft: Color
    var track: Color
    var barTrack: Color

    static let popover = Palette(
        fg: .primary,
        muted: .secondary,
        soft: .primary.opacity(0.8),
        track: .primary.opacity(0.12),
        barTrack: .primary.opacity(0.14)
    )
}
