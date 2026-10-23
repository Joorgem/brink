import Foundation

/// Reads the Cursor CLI's session JWT (macOS Keychain, service
/// "cursor-access-token" / account "cursor-user") and queries Cursor's
/// `usage-summary` endpoint — the source behind the "You've used N% of your
/// included usage" message in the Cursor app.
///
/// Design notes — same posture as ClaudeProvider:
/// - Auth is the browser-style session cookie `WorkosCursorSessionToken=
///   <userId>::<jwt>`. The numeric userId is read from ~/.cursor/cli-config.json
///   (written by `cursor-agent login`); the JWT comes from the Keychain.
/// - Brink only reads "cursor-access-token". The sibling "cursor-refresh-token"
///   is never touched — refreshing would rotate it and log the user out of
///   `cursor-agent`.
/// - Cursor exposes no public usage API; `usage-summary` is internal, so every
///   field is probed defensively and a missing shape degrades to a friendly
///   error rather than crashing.
/// - The server returns pre-computed percentages, so Brink displays them as-is.
/// - cursor-agent keeps a single login, so extra accounts use a pasted
///   `WorkosCursorSessionToken` cookie (from cursor.com) stored in Brink's own
///   0600 file — `sessionFile`. Those never touch the Keychain.
struct CursorProvider: UsageProvider {
    let id = "cursor"
    /// nil = cursor-agent's login (Keychain + ~/.cursor/cli-config.json).
    var sessionFile: URL? = nil

    private static let usageURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let keychainService = "cursor-access-token"
    private static let keychainAccount = "cursor-user"

    func fetch() async -> ProviderSnapshot {
        var snap = ProviderSnapshot(id: id, name: "Cursor",
                                    systemImage: "cursorarrow",
                                    windows: [], error: nil)
        if let sessionFile {
            guard let session = Self.loadSession(sessionFile) else {
                snap.error = L("Session token missing — remove this account and add it again")
                return snap
            }
            do {
                let (data, status) = try await Self.requestUsage(token: session.token, userId: session.userId)
                return Self.finish(snap, data: data, status: status,
                                   unauthorized: L("Session expired — copy a fresh WorkosCursorSessionToken from cursor.com"))
            } catch {
                snap.error = error.localizedDescription
                return snap
            }
        }

        guard let token = Self.loadToken(), let userId = Self.loadUserId() else {
            return ClaudeProvider.demoSnapshot(
                name: "Cursor", systemImage: "cursorarrow",
                note: L("Cursor CLI credentials not found — run `cursor-agent login`"))
        }

        do {
            var (data, status) = try await Self.requestUsage(token: token, userId: userId)
            if status == 401 || status == 403 {
                // cursor-agent rotated its token: drop cache, re-read once.
                Self.clearCache()
                if let fresh = Self.loadToken(), fresh != token {
                    (data, status) = try await Self.requestUsage(token: fresh, userId: userId)
                }
            }
            return Self.finish(snap, data: data, status: status,
                               unauthorized: L("Unauthorized — run `cursor-agent login` to refresh"))
        } catch {
            snap.error = error.localizedDescription
            return snap
        }
    }

    private static func finish(_ snap: ProviderSnapshot, data: Data, status: Int,
                               unauthorized: String) -> ProviderSnapshot {
        var snap = snap
        if status == 401 || status == 403 {
            snap.error = unauthorized
            return snap
        }
        guard status == 200 else {
            snap.error = L("HTTP %d", status)
            return snap
        }
        snap.windows = parseUsage(data)
        snap.updatedAt = Date()
        if snap.windows.isEmpty { snap.error = L("No usage data in response") }
        return snap
    }

    /// Parses a pasted cookie value: "<userId>::<jwt>" or "<userId>%3A%3A<jwt>",
    /// optionally with the "WorkosCursorSessionToken=" prefix still attached.
    static func parseSession(_ raw: String) -> (userId: String, token: String)? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let eq = value.range(of: "WorkosCursorSessionToken=") {
            value = String(value[eq.upperBound...])
        }
        if let semicolon = value.firstIndex(of: ";") { value = String(value[..<semicolon]) }
        value = value.replacingOccurrences(of: "%3A%3A", with: "::")
            .replacingOccurrences(of: "%3a%3a", with: "::")
        let parts = value.components(separatedBy: "::")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count > 20 else { return nil }
        return (parts[0], parts[1])
    }

    private static func loadSession(_ url: URL) -> (userId: String, token: String)? {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseSession(raw)
    }

    private static func requestUsage(token: String, userId: String) async throws -> (Data, Int) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        // Session-cookie auth: "WorkosCursorSessionToken=<userId>::<jwt>", ":" percent-encoded.
        request.setValue("WorkosCursorSessionToken=\(userId)%3A%3A\(token)",
                         forHTTPHeaderField: "Cookie")
        request.setValue("Brink/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: Parsing

    /// usage-summary shape (fields probed defensively):
    /// { individualUsage: { plan: { totalPercentUsed, autoPercentUsed, apiPercentUsed,
    ///                              enabled, limit, used, remaining },
    ///                      onDemand: { enabled, limit, used } },
    ///   isUnlimited, billingCycleEnd }
    static func parseUsage(_ data: Data) -> [UsageWindow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let reset = ClaudeProvider.isoDate(root["billingCycleEnd"])

        // Unlimited plans have no meaningful percentage to show.
        if let unlimited = ClaudeProvider.number(root["isUnlimited"]), unlimited == 1 {
            return [UsageWindow(label: "Included usage", usedPercent: 0, resetsAt: reset)]
        }

        let individual = root["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        var windows: [UsageWindow] = []

        // Headline window — total included usage (matches the app's banner).
        if let pct = ClaudeProvider.number(plan?["totalPercentUsed"]) {
            windows.append(UsageWindow(label: "Included usage", usedPercent: pct, resetsAt: reset))
        }
        if let pct = ClaudeProvider.number(plan?["autoPercentUsed"]) {
            windows.append(UsageWindow(label: "Auto", usedPercent: pct, resetsAt: reset))
        }
        if let pct = ClaudeProvider.number(plan?["apiPercentUsed"]) {
            windows.append(UsageWindow(label: "API", usedPercent: pct, resetsAt: reset))
        }

        // On-demand / usage-based spend, only when the user has enabled it.
        if let onDemand = individual?["onDemand"] as? [String: Any],
           ClaudeProvider.number(onDemand["enabled"]) == 1,
           let used = ClaudeProvider.number(onDemand["used"]),
           let limit = ClaudeProvider.number(onDemand["limit"]), limit > 0 {
            windows.append(UsageWindow(label: "On-demand",
                                       usedPercent: used / limit * 100, resetsAt: reset))
        }

        return windows
    }

    // MARK: Credentials

    private static var tokenCache: String?
    private static var userIdCache: String?
    private static var lastKeychainAttempt: Date?
    private static let keychainRetryInterval: TimeInterval = 10 * 60

    /// Lookup order, chosen so the macOS Keychain prompt appears at most once:
    ///  1) in-memory cache
    ///  2) Brink's own copy (mode 0600) — survives relaunches *and* rebuilds, which
    ///     matter here: an ad-hoc signature changes on every build and macOS then
    ///     treats the app as a different program, re-asking for Keychain access
    ///  3) the Keychain itself — the only step that can prompt
    /// The refresh token is never read; refreshing it would log the user out of
    /// `cursor-agent`.
    static func loadToken() -> String? {
        if let cached = tokenCache { return cached }

        if let data = try? Data(contentsOf: ownStoreURL),
           let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            tokenCache = token
            return token
        }

        // Don't hammer the Keychain (and the user with prompts) if it keeps failing.
        if let last = lastKeychainAttempt, Date().timeIntervalSince(last) < keychainRetryInterval {
            return nil
        }
        lastKeychainAttempt = Date()

        guard let data = ClaudeProvider.keychainData(service: keychainService,
                                                     account: keychainAccount),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        tokenCache = token
        saveOwnCopy(token)
        return token
    }

    // MARK: Own token cache (~/Library/Application Support/Brink/cursor-token)

    static var ownStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brink", isDirectory: true)
            .appendingPathComponent("cursor-token")
    }

    static func saveOwnCopy(_ token: String) {
        let dir = ownStoreURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data(token.utf8).write(to: ownStoreURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: ownStoreURL.path)
    }

    /// The numeric Cursor userId lives in ~/.cursor/cli-config.json under
    /// authInfo.userId. Needed as the cookie's "<userId>::" prefix.
    static func loadUserId() -> String? {
        if let cached = userIdCache { return cached }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/cli-config.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let auth = root["authInfo"] as? [String: Any] else {
            return nil
        }
        let raw = auth["userId"]
        let id: String?
        if let s = raw as? String { id = s }
        else if let n = raw as? Int { id = String(n) }
        else if let d = raw as? Double { id = String(Int(d)) }
        else { id = nil }
        userIdCache = id
        return id
    }

    static func clearCache() {
        tokenCache = nil
        lastKeychainAttempt = nil
        try? FileManager.default.removeItem(at: ownStoreURL)
    }
}
