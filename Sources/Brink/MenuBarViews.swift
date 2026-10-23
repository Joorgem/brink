import SwiftUI
import AppKit

// Design: native macOS popover (Liquid Glass on macOS 26, the system material
// before that). Content stays flat and uses vibrant system colours; only the
// controls are plain borderless icons. Accounts sit in one grouped list per
// provider, like System Settings; refresh and settings sit in a footer.

// The macOS 27 SDK declares a `State` macro whose plugin ships only with full
// Xcode; a typealias keeps the property wrapper so Command Line Tools build too.
typealias ViewState = SwiftUI.State

// MARK: - Popover root

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var accounts: AccountStore
    @ObservedObject var themeStore: ThemeStore
    @ViewState private var adding: ProviderKind?
    @ViewState private var contentHeight: CGFloat = 0

    static let width: CGFloat = 320
    private static let maxListHeight: CGFloat = 560
    let palette = Palette.popover

    var body: some View {
        VStack(spacing: 0) {
            if let kind = adding {
                AddAccountForm(kind: kind, accounts: accounts) { adding = nil }
                    .padding(14)
            } else {
                accountList
                Divider().padding(.horizontal, 12)
                footer
            }
        }
        .frame(width: Self.width)
        // Re-render on language change.
        .id(themeStore.language)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            // Refresh + how old the numbers are, e.g. "↻ 1 min".
            Button { store.refreshAll() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                        .animation(store.isRefreshing
                                   ? .linear(duration: 1).repeatForever(autoreverses: false)
                                   : .default, value: store.isRefreshing)
                    if let last = store.lastRefresh {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Text(Self.age(of: last)).monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help(L("Refresh now"))
            Spacer()
            Menu {
                SettingsMenuItems(store: store, accounts: accounts, themeStore: themeStore)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Settings"))
        }
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// "now", "3 min", "2 h".
    static func age(of date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return L("now") }
        if seconds < 3600 { return L("%d min", Int(seconds / 60)) }
        return L("%d h", Int(seconds / 3600))
    }

    // MARK: List

    private var accountList: some View {
        // Every provider gets a header with its "+", even with no accounts yet,
        // so that's the one place to add an account.
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(accounts.visibleKinds) { kind in
                    ProviderSection(kind: kind, list: accounts.accounts(for: kind), store: store,
                                    accounts: accounts, themeStore: themeStore, palette: palette) { adding = kind }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 60), Self.maxListHeight))
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Provider section

struct ProviderSection: View {
    let kind: ProviderKind
    let list: [Account]
    @ObservedObject var store: UsageStore
    @ObservedObject var accounts: AccountStore
    @ObservedObject var themeStore: ThemeStore
    let palette: Palette
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ProviderIcon(id: kind.rawValue, size: 12, color: palette.muted)
                Text(kind.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!accounts.canAdd(kind))
                .help(accounts.canAdd(kind)
                      ? L("Add account")
                      : L("Up to %d accounts per provider", AccountStore.maxPerProvider))
            }
            .padding(.horizontal, 4)
            .opacity(list.isEmpty ? 0.6 : 1)

            // One card per account.
            ForEach(list) { account in
                AccountRow(account: account, snapshot: store.snapshot(for: account),
                           accounts: accounts, themeStore: themeStore, palette: palette)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045)))
            }
        }
    }
}

// MARK: - Account row

struct AccountRow: View {
    let account: Account
    let snapshot: ProviderSnapshot?
    @ObservedObject var accounts: AccountStore
    @ObservedObject var themeStore: ThemeStore
    let palette: Palette
    @ViewState private var renaming = false
    @ViewState private var newName = ""
    @ViewState private var hovering = false

    private var isInMenuBar: Bool { themeStore.menuBarAccount == account.id.uuidString }
    private var hasData: Bool { snapshot.map { !$0.windows.isEmpty && !$0.isDemo } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            if let snapshot, hasData {
                if let primary = snapshot.primary {
                    UsageBar(fraction: primary.fraction,
                             color: UsageColor.color(for: snapshot, percent: primary.usedPercent),
                             height: 5)
                    // No label: the big number is the current window; its reset
                    // sits on the right, under the percentage.
                    if let reset = primary.resetDetail {
                        HStack {
                            Spacer(minLength: 0)
                            Text(reset)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .help(L(primary.label))
                    }
                }
                ForEach(snapshot.windows.dropFirst()) { window in
                    SecondaryUsageRow(window: window,
                                      color: UsageColor.color(for: snapshot, percent: window.usedPercent),
                                      showsReset: window.id == snapshot.weekly?.id)
                }
                if let error = snapshot.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                // "What used it": only for the default Claude login, whose transcripts Brink reads.
                if snapshot.isDefaultLogin, snapshot.provider == ProviderKind.claude.rawValue,
                   CostModel.shared.state != .unavailable {
                    CostSection(model: .shared, snapshot: snapshot, palette: palette)
                }
            } else {
                Text(statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { actions }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if renaming {
                TextField(L("Name"), text: $newName, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            } else {
                Text(account.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let detail = sourceDetail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Menu { actions } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
            if let snapshot, hasData, let primary = snapshot.primary {
                Text("\(Int(primary.usedPercent.rounded()))%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(isInMenuBar ? L("Hide from menu bar") : L("Show in menu bar")) {
            themeStore.menuBarAccount = isInMenuBar ? "" : account.id.uuidString
        }
        Divider()
        Button(L("Rename")) { newName = account.name; renaming = true }
        Button(L("Remove"), role: .destructive) { accounts.remove(account.id) }
    }

    private var sourceDetail: String? {
        switch account.source {
        case .defaultLogin: return nil
        case .directory(let path):
            return (path as NSString).abbreviatingWithTildeInPath
        case .sessionToken: return L("session token")
        }
    }

    /// No numbers yet: say why, and for a folder login how to sign in.
    private var statusText: String {
        guard let snapshot else { return L("Loading…") }
        if snapshot.updatedAt == nil && snapshot.error == nil { return L("Loading…") }
        var text = snapshot.error ?? L("No data")
        if case .directory(let path) = account.source, let env = account.provider.directoryEnv {
            text += "\n" + L("Sign in with: %@", "\(env)=\"\(path)\" \(account.provider.cli)")
        }
        return text
    }

    private func commitRename() {
        accounts.rename(account.id, to: newName)
        renaming = false
    }
}

/// "Weekly limit   ▬▬░░░░  22%", with "Resets Mon 14:00 · in 2 d 3 h" under it on the right for the weekly window.
struct SecondaryUsageRow: View {
    let window: UsageWindow
    let color: Color
    var showsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            bar
            if showsReset, let reset = window.resetDetail {
                HStack {
                    Spacer(minLength: 0)
                    Text(reset)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Text(L(window.label))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            UsageBar(fraction: window.fraction, color: color, height: 3)
                .frame(width: 64)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 32, alignment: .trailing)
        }
        .help(window.resetText ?? "")
    }
}

struct UsageBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: - Add account

struct AddAccountForm: View {
    let kind: ProviderKind
    @ObservedObject var accounts: AccountStore
    var onDone: () -> Void

    private enum Mode: Hashable { case defaultLogin, directory, sessionToken }

    @ViewState private var name = ""
    @ViewState private var mode: Mode = .directory
    @ViewState private var path = ""
    @ViewState private var pathEdited = false
    @ViewState private var token = ""
    @ViewState private var copied = false

    let palette = Palette.popover

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Add %@ account", kind.displayName))
                .font(.system(size: 12.5, weight: .semibold))

            TextField(L("Name (e.g. Work)"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { newValue in
                    if !pathEdited { path = kind.suggestedDirectory(for: newValue) }
                }

            if modes.count > 1 {
                Picker("", selection: $mode) {
                    ForEach(modes, id: \.self) { Text(title(for: $0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch mode {
            case .defaultLogin:
                hint(kind == .cursor
                     ? L("Uses the account signed in to cursor-agent on this Mac.")
                     : L("Uses the account signed in to %@ on this Mac.", kind.displayName))
            case .directory:
                TextField(L("Login folder"), text: Binding(
                    get: { path },
                    set: { path = $0; pathEdited = true }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                hint(L("Each extra account keeps its own login folder, so you never have to sign out of the other. Sign in once in Terminal:"))
                HStack(alignment: .top, spacing: 6) {
                    Text(loginCommand)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(copied ? L("Copied") : L("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(loginCommand, forType: .string)
                        copied = true
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.track))
                if kind == .claude {
                    hint(L("Tip: add an alias, e.g. alias claude-work='%@'. Brink reads the token Claude Code keeps fresh while you use it.", loginCommand))
                }
            case .sessionToken:
                SecureField("WorkosCursorSessionToken", text: $token)
                    .textFieldStyle(.roundedBorder)
                hint(L("On cursor.com, open the browser's developer tools → Application → Cookies and copy the value of WorkosCursorSessionToken. It is stored only on this Mac (mode 0600)."))
            }

            if let problem {
                Text(problem).font(.system(size: 10.5)).foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button(L("Cancel"), action: onDone)
                    .keyboardShortcut(.cancelAction)
                Button(L("Add")) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || trimmedName.isEmpty || (mode == .sessionToken && token.isEmpty))
            }
        }
        .onAppear {
            mode = modes.first ?? .directory
            path = kind.suggestedDirectory(for: name)
        }
    }

    // MARK: Logic

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var modes: [Mode] {
        let extra: Mode = kind == .cursor ? .sessionToken : .directory
        return accounts.hasDefaultLogin(kind) ? [extra] : [.defaultLogin, extra]
    }

    private func title(for mode: Mode) -> String {
        switch mode {
        case .defaultLogin: return L("This Mac's login")
        case .directory: return L("Separate folder")
        case .sessionToken: return L("Session token")
        }
    }

    private var loginCommand: String {
        let dir = AccountFiles.normalize(path.isEmpty ? kind.suggestedDirectory(for: name) : path)
        return "\(kind.directoryEnv ?? "")=\"\(dir)\" \(kind.cli)"
    }

    private var problem: String? {
        if !accounts.canAdd(kind) { return L("Up to %d accounts per provider", AccountStore.maxPerProvider) }
        switch mode {
        case .defaultLogin:
            return nil
        case .directory:
            if path.trimmingCharacters(in: .whitespaces).isEmpty { return L("Choose a login folder") }
            if accounts.usesDirectory(path) { return L("Another account already uses this folder") }
            return nil
        case .sessionToken:
            if token.isEmpty { return nil }   // nothing typed yet; Add stays disabled below
            return CursorProvider.parseSession(token) == nil ? L("That doesn't look like a session token") : nil
        }
    }

    private func add() {
        let account: Account
        switch mode {
        case .defaultLogin:
            account = Account(provider: kind, name: trimmedName, source: .defaultLogin)
            accounts.add(account)
        case .directory:
            account = Account(provider: kind, name: trimmedName, source: .directory(path))
            accounts.add(account)
        case .sessionToken:
            guard CursorProvider.parseSession(token) != nil else { return }
            account = Account(provider: kind, name: trimmedName, source: .sessionToken)
            accounts.add(account, token: token)
        }
        onDone()
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
