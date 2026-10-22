import SwiftUI
import AppKit

// MARK: - Preferences (persisted)

@MainActor
final class ThemeStore: ObservableObject {
    private static let percentKey = "showPercentInMenuBar"

    /// "" = system default; otherwise a code from L10n.available. Changing it
    /// re-renders every view (they observe this store), so it applies instantly.
    @Published var language: String = L10n.override {
        didSet { L10n.override = language }
    }

    /// Show the highest usage next to the menu bar icon ("73%").
    @Published var showPercentInMenuBar: Bool =
        UserDefaults.standard.object(forKey: ThemeStore.percentKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPercentInMenuBar, forKey: Self.percentKey) }
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
