import SwiftUI
import AppKit

// MARK: - Provider icons (vector, from the mockup)

struct ClaudeIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        var p = Path()
        let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (12, 2.5, 12, 8), (12, 16, 12, 21.5), (2.5, 12, 8, 12), (16, 12, 21.5, 12),
            (5.2, 5.2, 9.1, 9.1), (14.9, 14.9, 18.8, 18.8), (5.2, 18.8, 9.1, 14.9), (14.9, 9.1, 18.8, 5.2),
        ]
        for (x1, y1, x2, y2) in lines {
            p.move(to: CGPoint(x: rect.minX + x1 * s, y: rect.minY + y1 * s))
            p.addLine(to: CGPoint(x: rect.minX + x2 * s, y: rect.minY + y2 * s))
        }
        return p
    }
}

struct CodexIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var p = Path()
        p.move(to: pt(12, 3)); p.addLine(to: pt(19.4, 7.3)); p.addLine(to: pt(19.4, 16.7))
        p.addLine(to: pt(12, 21)); p.addLine(to: pt(4.6, 16.7)); p.addLine(to: pt(4.6, 7.3)); p.closeSubpath()
        p.move(to: pt(12, 8.4)); p.addLine(to: pt(15.1, 10.2)); p.addLine(to: pt(15.1, 13.8))
        p.addLine(to: pt(12, 15.6)); p.addLine(to: pt(8.9, 13.8)); p.addLine(to: pt(8.9, 10.2)); p.closeSubpath()
        return p
    }
}

struct ProviderIcon: View {
    let id: String
    var size: CGFloat
    var color: Color

    private static let logos: [String: NSImage] = {
        var dict: [String: NSImage] = [:]
        for (key, file) in [("claude", "claude"), ("codex", "openai"), ("cursor", "cursor")] {
            if let url = L10n.resources.url(forResource: file, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                dict[key] = img
            }
        }
        return dict
    }()

    var body: some View {
        Group {
            if let logo = Self.logos[id] {
                Image(nsImage: logo)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(color)
            } else {
                switch id {
                case "claude":
                    ClaudeIcon().stroke(color, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                case "codex":
                    CodexIcon().stroke(color, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                case "cursor":
                    Image(systemName: "cursorarrow").font(.system(size: size * 0.8, weight: .semibold)).foregroundColor(color)
                default:
                    Image(systemName: "sparkle").font(.system(size: size * 0.8, weight: .semibold)).foregroundColor(color)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Settings menu (gear button in the popover)

struct SettingsMenuItems: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var themeStore: ThemeStore

    var body: some View {
        Button(L("Refresh now")) { store.refreshAll() }
        Divider()
        Picker(L("Show in menu bar"), selection: $themeStore.menuBarAccount) {
            Text(L("Icon only")).tag("")
            Divider()
            ForEach(store.snapshots) { Text($0.displayName).tag($0.id) }
        }
        Picker(L("Language"), selection: $themeStore.language) {
            Text(L("System default")).tag("")
            Divider()
            ForEach(L10n.available, id: \.code) { Text($0.name).tag($0.code) }
        }
        Toggle(L("Launch at login"), isOn: Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { LaunchAtLogin.set($0) }
        ))
        Toggle(L("Notifications"), isOn: Binding(
            get: { Notifier.shared.isEnabled },
            set: { Notifier.shared.setEnabled($0) }
        ))
        Button(L("Test notification")) { Notifier.shared.sendTest() }
        if let stats = CostModel.shared.statsLine() {
            Divider()
            Button(stats) { }.disabled(true)
        }
        Divider()
        Button(L("Quit Brink")) { NSApp.terminate(nil) }
    }
}

// MARK: - Cost breakdown ("what used it")

enum CostFormat {
    /// Locale-aware percentage: "3,1 %" / "3.1%" / "%3,1" depending on language.
    static func percent(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = value < 10 ? 1 : 0
        if !L10n.override.isEmpty { f.locale = Locale(identifier: L10n.override) }
        return f.string(from: NSNumber(value: value / 100)) ?? String(format: "%.1f%%", value)
    }
}

/// A collapsed one-liner under the limit windows; expands into a per-project list.
/// Kept deliberately quiet: the card is still about the limit, this is the footnote
/// that answers "what used it".
struct CostSection: View {
    @ObservedObject var model: CostModel
    let snapshot: ProviderSnapshot
    let palette: Palette

    private var accent: Color { snapshot.accent ?? UsageColor.claudeOrange }
    private var maxPct: Double { model.rows.map(\.pct).max() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(palette.barTrack)
                .frame(height: 1)
                .padding(.top, 12)
                .padding(.bottom, 9)

            Button {
                withAnimation(.easeOut(duration: 0.18)) { model.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(model.range.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(palette.fg)
                    Spacer(minLength: 8)
                    if !model.isExpanded {
                        if let top = model.rows.first {
                            Text("\(top.displayName) · \(CostFormat.percent(top.pct))")
                                .font(.system(size: 10.5))
                                .foregroundColor(palette.soft)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(L("Not measured yet"))
                                .font(.system(size: 10.5))
                                .foregroundColor(palette.muted)
                        }
                    }
                    Image(systemName: model.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(palette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.isExpanded {
                HStack(spacing: 9) {
                    ForEach(CostRange.allCases) { range in
                        let selected = range == model.range
                        Button {
                            model.range = range
                        } label: {
                            Text(range.shortTitle)
                                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                                .foregroundColor(selected ? palette.fg : palette.muted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)

                if model.rows.isEmpty {
                    Text(L("Brink matches every rise in your limit to the project you were working in. The first reading takes a few minutes."))
                        .font(.system(size: 10))
                        .foregroundColor(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 7)
                } else {
                    ForEach(model.rows) { row in
                        CostRow(row: row, maxPct: maxPct, accent: accent, palette: palette)
                    }
                    // All-time has no limit to measure against, so the numbers mean
                    // something else — say so rather than let them look alike.
                    if model.range.isShare {
                        Text(L("share of the work in this range"))
                            .font(.system(size: 9.5))
                            .foregroundColor(palette.muted)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }
}

struct CostRow: View {
    let row: ProjectCost
    let maxPct: Double
    let accent: Color
    let palette: Palette

    private static let barWidth: CGFloat = 54

    private var fraction: CGFloat {
        CGFloat(min(max(row.pct / max(maxPct, 0.0001), 0), 1))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(row.displayName)
                .font(.system(size: 11))
                .foregroundColor(row.isUnexplained ? palette.muted : palette.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(palette.barTrack)
                    .frame(width: Self.barWidth, height: 4)
                RoundedRectangle(cornerRadius: 2)
                    .fill(row.isUnexplained ? palette.muted : accent)
                    .frame(width: max(3, Self.barWidth * fraction), height: 4)
            }
            Text(CostFormat.percent(row.pct))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(palette.soft)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.top, 7)
        .help(row.isUnexplained
              ? L("Spent outside this Mac — claude.ai, another device, or a background job.")
              : row.project)
    }
}
