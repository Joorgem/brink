import Foundation

// MARK: - Provider kinds

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case claude, codex, cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// Environment variable that points the CLI at another login folder, so a
    /// second (third, …) account can live next to the default one.
    var directoryEnv: String? {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .cursor: return nil
        }
    }

    /// Command that signs in, as typed in Terminal.
    var cli: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex login"
        case .cursor: return "cursor-agent login"
        }
    }

    /// Folder the CLI uses when no override is set.
    var defaultDirectory: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude")
        case .codex:
            return ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
        case .cursor: return nil
        }
    }

    /// Suggested folder for an extra account, e.g. ~/.claude-work.
    func suggestedDirectory(for name: String) -> String {
        let slug = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let base = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(base)/.\(rawValue)-\(slug.isEmpty ? "2" : slug)"
    }
}

// MARK: - Account

/// One login Brink watches. Several may exist per provider (up to
/// `AccountStore.maxPerProvider`); each gets its own section row in the popover.
struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var provider: ProviderKind
    var name: String
    var source: Source

    enum Source: Codable, Hashable {
        /// The CLI's own login (~/.claude + Keychain, ~/.codex, cursor-agent).
        case defaultLogin
        /// A separate login folder: CLAUDE_CONFIG_DIR / CODEX_HOME.
        case directory(String)
        /// Cursor only: a pasted `WorkosCursorSessionToken`, kept in Brink's own 0600 file.
        case sessionToken
    }

    var isDefaultLogin: Bool { source == .defaultLogin }

    /// Per-account file in ~/Library/Application Support/Brink/accounts/.
    func storageURL(_ suffix: String) -> URL {
        AccountFiles.directory.appendingPathComponent("\(id.uuidString)-\(suffix)")
    }

    func makeProvider() -> UsageProvider {
        switch provider {
        case .claude:
            if case .directory(let path) = source {
                return ClaudeProvider(configDir: path, ownStoreURL: storageURL("credentials.json"))
            }
            return ClaudeProvider()
        case .codex:
            if case .directory(let path) = source {
                return CodexProvider(home: URL(fileURLWithPath: path))
            }
            return CodexProvider()
        case .cursor:
            if source == .sessionToken {
                return CursorProvider(sessionFile: storageURL("cursor-session"))
            }
            return CursorProvider()
        }
    }
}

// MARK: - Store

/// The accounts the user added, persisted in UserDefaults. The usage store
/// follows this list: add one and its card appears, remove it and it's gone.
@MainActor
final class AccountStore: ObservableObject {
    static let maxPerProvider = 5
    private static let key = "accounts"

    @Published private(set) var accounts: [Account]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = saved
        } else {
            accounts = Self.initialAccounts()
            save()
        }
    }

    /// First launch: one account per CLI that is already signed in on this Mac.
    /// Claude is always there — its card explains how to sign in if it isn't.
    private static func initialAccounts() -> [Account] {
        let fm = FileManager.default
        var list = [Account(provider: .claude, name: "Claude", source: .defaultLogin)]
        if let codex = ProviderKind.codex.defaultDirectory,
           fm.fileExists(atPath: codex.appendingPathComponent("auth.json").path) {
            list.append(Account(provider: .codex, name: "Codex", source: .defaultLogin))
        }
        let cursorConfig = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/cli-config.json")
        if fm.fileExists(atPath: cursorConfig.path) {
            list.append(Account(provider: .cursor, name: "Cursor", source: .defaultLogin))
        }
        return list
    }

    func accounts(for kind: ProviderKind) -> [Account] {
        accounts.filter { $0.provider == kind }
    }

    func canAdd(_ kind: ProviderKind) -> Bool {
        accounts(for: kind).count < Self.maxPerProvider
    }

    func hasDefaultLogin(_ kind: ProviderKind) -> Bool {
        accounts.contains { $0.provider == kind && $0.isDefaultLogin }
    }

    func usesDirectory(_ path: String) -> Bool {
        let wanted = AccountFiles.normalize(path)
        return accounts.contains {
            if case .directory(let p) = $0.source { return AccountFiles.normalize(p) == wanted }
            if $0.isDefaultLogin, let d = $0.provider.defaultDirectory { return d.path == wanted }
            return false
        }
    }

    /// Adds an account. For a Cursor session token, `token` is written to the
    /// account's own 0600 file first. Returns false when the provider is full.
    @discardableResult
    func add(_ account: Account, token: String? = nil) -> Bool {
        guard canAdd(account.provider) else { return false }
        var account = account
        if case .directory(let path) = account.source {
            let normalized = AccountFiles.normalize(path)
            account.source = .directory(normalized)
            // Harmless if it exists; saves the user a mkdir before signing in.
            try? FileManager.default.createDirectory(atPath: normalized, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        if let token {
            AccountFiles.writePrivate(Data(token.utf8), to: account.storageURL("cursor-session"))
        }
        accounts.append(account)
        save()
        return true
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].name = trimmed
        save()
    }

    func remove(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts.remove(at: i)
        // Drop whatever Brink cached for it. The CLI's own login is never touched.
        for suffix in ["credentials.json", "cursor-session"] {
            try? FileManager.default.removeItem(at: account.storageURL(suffix))
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Files

/// Path helpers, kept off the main actor so providers can use them while fetching.
enum AccountFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brink", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
    }

    static func normalize(_ path: String) -> String {
        var p = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func writePrivate(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
