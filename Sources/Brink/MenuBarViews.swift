import SwiftUI
import AppKit

// MARK: - Popover root

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var accounts: AccountStore
    @ObservedObject var themeStore: ThemeStore
    @State private var adding: ProviderKind?
    @State private var contentHeight: CGFloat = 0

    static let width: CGFloat = 340
    private static let maxListHeight: CGFloat = 520
    let palette = Palette.popover

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let kind = adding {
                AddAccountForm(kind: kind, accounts: accounts) { adding = nil }
                    .padding(14)
            } else {
                accountList
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        // Re-render on language change.
        .id(themeStore.language)
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Text("Brink").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { store.refreshAll() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing
                               ? .linear(duration: 1).repeatForever(autoreverses: false)
                               : .default, value: store.isRefreshing)
            }
            .buttonStyle(.plain)
            .help(L("Refresh now"))
            Menu {
                SettingsMenuItems(store: store, themeStore: themeStore)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundColor(palette.soft)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            if let last = store.lastRefresh {
                Text(L("Updated %@", Self.relative(last)))
            }
            Spacer()
            addMenu
        }
        .font(.system(size: 11))
        .foregroundColor(palette.muted)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var addMenu: some View {
        Menu {
            ForEach(ProviderKind.allCases) { kind in
                Button("\(kind.displayName) (\(accounts.accounts(for: kind).count)/\(AccountStore.maxPerProvider))") {
                    adding = kind
                }
                .disabled(!accounts.canAdd(kind))
            }
        } label: {
            Label(L("Add account"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(adding != nil)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        if !L10n.override.isEmpty { f.locale = Locale(identifier: L10n.override) }
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: List

    private var accountList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if accounts.accounts.isEmpty {
                    emptyState
                } else {
                    ForEach(ProviderKind.allCases) { kind in
                        let list = accounts.accounts(for: kind)
                        if !list.isEmpty {
                            ProviderSection(kind: kind, list: list, store: store, accounts: accounts,
                                            palette: palette) { adding = kind }
                        }
                    }
                }
            }
            .padding(14)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 60), Self.maxListHeight))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("No accounts yet"))
                .font(.system(size: 12.5, weight: .semibold))
            Text(L("Add a Claude, Codex or Cursor account to see its limits here."))
                .font(.system(size: 11.5))
                .foregroundColor(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    let palette: Palette
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderIcon(id: kind.rawValue, size: 13, color: palette.fg)
                Text(kind.displayName).font(.system(size: 12, weight: .semibold))
                Text("\(list.count)/\(AccountStore.maxPerProvider)")
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.muted)
                Spacer()
                Button(action: onAdd) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundColor(palette.soft)
                    .disabled(!accounts.canAdd(kind))
                    .help(accounts.canAdd(kind)
                          ? L("Add account")
                          : L("Up to %d accounts per provider", AccountStore.maxPerProvider))
            }
            ForEach(list) { account in
                AccountCard(account: account, snapshot: store.snapshot(for: account),
                            accounts: accounts, palette: palette)
            }
        }
    }
}

// MARK: - Account card

struct AccountCard: View {
    let account: Account
    let snapshot: ProviderSnapshot?
    @ObservedObject var accounts: AccountStore
    let palette: Palette
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if renaming {
                    TextField(L("Name"), text: $newName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5))
                } else {
                    Text(account.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    if let detail = sourceDetail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Button(L("Rename")) { newName = account.name; renaming = true }
                    Button(L("Remove"), role: .destructive) { accounts.remove(account.id) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundColor(palette.muted)
            }

            if let snapshot, !snapshot.windows.isEmpty, !snapshot.isDemo {
                ForEach(snapshot.windows) { window in
                    UsageRow(window: window, color: UsageColor.color(for: snapshot, percent: window.usedPercent),
                             palette: palette)
                }
                if let error = snapshot.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
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
                    .foregroundColor(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.track.opacity(0.5)))
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

struct UsageRow: View {
    let window: UsageWindow
    let color: Color
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(L(window.label))
                    .font(.system(size: 11))
                Spacer()
                if let reset = window.resetText {
                    Text(reset)
                        .font(.system(size: 9.5))
                        .foregroundColor(palette.muted)
                }
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 34, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.barTrack)
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * window.fraction))
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Add account

struct AddAccountForm: View {
    let kind: ProviderKind
    @ObservedObject var accounts: AccountStore
    var onDone: () -> Void

    private enum Mode: Hashable { case defaultLogin, directory, sessionToken }

    @State private var name = ""
    @State private var mode: Mode = .directory
    @State private var path = ""
    @State private var pathEdited = false
    @State private var token = ""
    @State private var copied = false

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
