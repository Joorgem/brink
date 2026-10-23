import Foundation
import Security
import CryptoKit

/// Reads Claude Code's OAuth access token (macOS Keychain or
/// ~/.claude/.credentials.json) and queries Anthropic's usage endpoint —
/// the same request Claude Code itself makes for `/usage`.
///
/// Design notes:
/// - While Claude Code runs it keeps the token fresh, and Brink just re-reads
///   its store. Once a login has expired (the account sat idle), Brink renews
///   it itself and writes the new pair back to Claude Code's store; see
///   `ClaudeTokenRefresher` for how that avoids logging the account out.
/// - Only the short-lived access token (+ expiry) is cached locally, so the
///   Keychain prompt appears once, not on every refresh cycle.
/// - The usage endpoint itself is shared with Claude Code's own `/usage`
///   command, so it rate-limits fairly easily. On a 429, `fetch()` backs off
///   for the `Retry-After` window and serves the last good snapshot instead
///   of hammering the endpoint and blanking the ring.
/// - One instance per account. Extra accounts are Claude Code logins kept in
///   their own folder (`CLAUDE_CONFIG_DIR=<dir> claude`); all caches below are
///   per instance so accounts never see each other's tokens.
final class ClaudeProvider: UsageProvider {
    let id = "claude"

    /// nil = Claude Code's default login (~/.claude, Keychain "Claude Code-credentials").
    private let configDir: String?
    /// Brink's own copy of this account's short-lived access token.
    private let ownStoreURL: URL

    init(configDir: String? = nil, ownStoreURL: URL? = nil) {
        self.configDir = configDir
        self.ownStoreURL = ownStoreURL ?? Self.defaultOwnStoreURL
    }

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    struct Credentials {
        var accessToken: String
        var expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 30
        }
    }

    // MARK: Response cache / 429 backoff
    //
    // The usage endpoint is shared with Claude Code's own `/usage` command and
    // any other client polling it, so it rate-limits fairly easily. On a 429
    // we stop hitting the network until Anthropic's own `Retry-After` window
    // has passed, and meanwhile keep showing the last good numbers instead of
    // blanking the ring out.
    private var cache: ProviderSnapshot?
    private var cooldownUntil: Date?

    func fetch() async -> ProviderSnapshot {
        if let until = cooldownUntil, Date() < until {
            return rateLimitedSnapshot(retryAt: until)
        }

        var snap = ProviderSnapshot(id: id, name: "Claude",
                                    systemImage: "asterisk",
                                    windows: [], error: nil,
                                    accent: UsageColor.claudeOrange)
        var loaded = loadCredentials()
        if loaded == nil, let expired = expiredLogin, !renewing,
           renewFailedAt.map({ Date().timeIntervalSince($0) > Self.keychainRetryInterval }) ?? true {
            renewing = true
            renewFailedAt = Date()
            if let data = await ClaudeTokenRefresher.renew(store: expired, pendingURL: pendingURL),
               let fresh = Self.parseCredentialsJSON(data), !fresh.isExpired {
                saveOwnCopy(fresh)
                loaded = fresh
                renewFailedAt = nil
            }
            renewing = false
        }
        guard let creds = loaded else {
            if loginExpired {
                // Claude Code only refreshes a login while it's being used, so an
                // account left idle for a few hours ends up here. Keep the last
                // numbers and say how to bring it back.
                var stale = cache ?? snap
                stale.error = L("Login expired")
                return stale
            }
            var demo = Self.demoSnapshot(name: "Claude", systemImage: "asterisk",
                                         note: L("Claude Code credentials not found"))
            demo.accent = UsageColor.claudeOrange
            return demo
        }

        do {
            var activeToken = creds.accessToken
            var (data, status, response) = try await Self.requestUsage(token: activeToken)
            if status == 401 {
                // Claude Code rotated its token: drop our cache, re-read its store
                // (Keychain / file) and retry once right away.
                clearOwnCopy()
                if let fresh = loadCredentials(), fresh.accessToken != creds.accessToken {
                    activeToken = fresh.accessToken
                    (data, status, response) = try await Self.requestUsage(token: activeToken)
                }
            }
            if status == 401 {
                snap.error = L("Unauthorized — open Claude Code once to refresh login")
                return snap
            }
            if status == 429 {
                // The window is short (often "Retry-After: 0"): quietly try again
                // twice within ~5 s before showing anything. Only if that fails do
                // we back off for the Retry-After window (min 30 s) and say so.
                for delay: UInt64 in [2, 3] {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    (data, status, response) = try await Self.requestUsage(token: activeToken)
                    if status != 429 { break }
                }
            }
            if status == 429 {
                let retrySeconds = max(30, Self.retryAfterSeconds(response) ?? 60)
                let until = Date().addingTimeInterval(retrySeconds)
                cooldownUntil = until
                return rateLimitedSnapshot(retryAt: until)
            }
            guard status == 200 else {
                snap.error = L("HTTP %d", status)
                return snap
            }
            snap.windows = Self.parseUsage(data)
            snap.updatedAt = Date()
            if snap.windows.isEmpty { snap.error = L("No usage data in response") }
            cooldownUntil = nil
            cache = snap
            return snap
        } catch {
            snap.error = error.localizedDescription
            return snap
        }
    }

    /// While rate-limited, keep showing the last good snapshot without a
    /// warning; the back-off retries on its own. Before any data, the card
    /// just says it's loading.
    private func rateLimitedSnapshot(retryAt: Date) -> ProviderSnapshot {
        if let snap = cache { return snap }
        return ProviderSnapshot(id: "claude", name: "Claude", systemImage: "asterisk",
                                windows: [], error: nil, accent: UsageColor.claudeOrange)
    }

    /// `Retry-After` is valid as either delta-seconds ("120") or an HTTP-date
    /// ("Wed, 21 Oct 2026 07:28:00 GMT") per RFC 9110 §10.2.3 — servers do use
    /// both forms, so both need parsing rather than just falling back to a
    /// fixed default when the value isn't a plain number.
    private static func retryAfterSeconds(_ response: HTTPURLResponse?) -> TimeInterval? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func requestUsage(token: String) async throws -> (Data, Int, HTTPURLResponse?) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Brink/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return (data, http?.statusCode ?? 0, http)
    }

    // MARK: Parsing

    /// Newer responses carry a structured `limits` array:
    /// `{kind: session|weekly_all|weekly_scoped, percent, resets_at, scope:{model:{display_name}}}`.
    /// Older responses only have `five_hour`, `seven_day`, `seven_day_sonnet`,
    /// `seven_day_opus` dicts with `utilization` (0-100) and `resets_at`.
    static func parseUsage(_ data: Data) -> [UsageWindow] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        let fromLimits = parseLimitsArray(root["limits"])
        if !fromLimits.isEmpty { return fromLimits }
        return parseLegacyWindows(root)
    }

    static func parseLimitsArray(_ any: Any?) -> [UsageWindow] {
        guard let limits = any as? [[String: Any]] else { return [] }
        var windows: [UsageWindow] = []
        for item in limits {
            guard let kind = item["kind"] as? String,
                  let pct = Self.number(item["percent"]) else { continue }
            let resets = Self.isoDate(item["resets_at"])
            let label: String
            switch kind {
            case "session":
                label = "Current session"
            case "weekly_all":
                label = "Weekly limit"
            case "weekly_scoped":
                let scope = item["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let surface = scope?["surface"] as? [String: Any]
                let name = (model?["display_name"] as? String)
                    ?? (surface?["display_name"] as? String)
                    ?? "Scoped"
                label = name
            default:
                // Unknown kind — still surface it rather than silently drop.
                label = kind.replacingOccurrences(of: "_", with: " ").capitalized
            }
            // Avoid duplicate ids (UsageWindow.id == label).
            if windows.contains(where: { $0.label == label }) { continue }
            windows.append(UsageWindow(label: label, usedPercent: pct, resetsAt: resets))
        }
        return windows
    }

    static func parseLegacyWindows(_ root: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        let ordered: [(String, String)] = [
            ("five_hour", "Current session"),
            ("seven_day", "Weekly limit"),
            ("seven_day_sonnet", "Sonnet"),
            ("seven_day_opus", "Opus"),
        ]
        for (key, label) in ordered {
            guard let dict = root[key] as? [String: Any] else { continue }
            guard let pct = Self.number(dict["utilization"]) else { continue }
            let resets = Self.isoDate(dict["resets_at"])
            windows.append(UsageWindow(label: label, usedPercent: pct, resetsAt: resets))
        }
        return windows
    }

    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        return f2.date(from: s)
    }

    // MARK: Credentials

    /// Lookup order is chosen to keep the macOS Keychain prompt to a minimum:
    ///  1) In-memory cache (no I/O while the app is running)
    ///  2) Brink's own cache of the access token (written after a successful read)
    ///  3) ~/.claude/.credentials.json (file store used by Claude Code on some setups)
    ///  4) Keychain item "Claude Code-credentials", read through `security`
    ///     (see `keychainDataViaSecurityTool`), so no password prompt.
    /// Expired tokens are discarded so Claude Code's fresher copy is picked up.
    /// For an account in its own folder, steps 3–4 use that folder's
    /// `.credentials.json` and its Keychain item instead.
    func loadCredentials() -> Credentials? {
        if let cached = memoryCache, !cached.isExpired { return cached }
        loginExpired = false
        expiredLogin = nil

        if let data = try? Data(contentsOf: ownStoreURL),
           let creds = Self.parseCredentialsJSON(data), !creds.isExpired {
            memoryCache = creds
            return creds
        }

        let claudeDir = configDir.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let claudeFile = claudeDir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: claudeFile),
           let creds = Self.parseCredentialsJSON(data) {
            if !creds.isExpired {
                saveOwnCopy(creds)
                return creds
            }
            loginExpired = true
            expiredLogin = .file(claudeFile)
        }

        // Don't hammer the Keychain (and the user with prompts) if it keeps failing.
        if let last = lastKeychainAttempt, Date().timeIntervalSince(last) < Self.keychainRetryInterval {
            return nil
        }
        lastKeychainAttempt = Date()
        for service in keychainServices {
            if let data = Self.keychainDataViaSecurityTool(service: service),
               let creds = Self.parseCredentialsJSON(data) {
                if !creds.isExpired {
                    saveOwnCopy(creds)
                    return creds
                }
                // The item is there and readable, only stale: no prompt to fear,
                // so look again on the next refresh instead of in 10 minutes.
                loginExpired = true
                expiredLogin = .keychain(service: service)
                lastKeychainAttempt = nil
            }
        }
        return nil
    }

    /// Claude Code names its Keychain item "Claude Code-credentials" for the
    /// default folder, and appends "-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>"
    /// when the variable is set. The path is hashed exactly as typed, so try it
    /// with and without a trailing slash.
    private var keychainServices: [String] {
        guard let configDir else { return ["Claude Code-credentials"] }
        let trimmed = AccountFiles.normalize(configDir)
        return [trimmed, trimmed + "/"].map {
            let digest = SHA256.hash(data: Data($0.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "Claude Code-credentials-\(hex.prefix(8))"
        }
    }

    // MARK: Own credential cache (~/Library/Application Support/Brink/credentials.json)
    // Holds ONLY the short-lived access token and its expiry — never the refresh token.

    private var memoryCache: Credentials?
    private var lastKeychainAttempt: Date?
    /// Set by `loadCredentials()` when a login was found but its token has expired.
    private var loginExpired = false
    /// Where that expired login lives, for `ClaudeTokenRefresher`.
    private var expiredLogin: ClaudeTokenRefresher.Store?
    private var renewing = false
    /// After a failed renewal, wait as long as for the Keychain before trying again.
    private var renewFailedAt: Date?
    /// Renewed credentials waiting for their store write; see `ClaudeTokenRefresher`.
    private var pendingURL: URL { ownStoreURL.appendingPathExtension("pending") }
    private static let keychainRetryInterval: TimeInterval = 10 * 60

    static var defaultOwnStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Brink", isDirectory: true)
            .appendingPathComponent("credentials.json")
    }

    func saveOwnCopy(_ creds: Credentials) {
        memoryCache = creds
        var oauth: [String: Any] = ["accessToken": creds.accessToken]
        if let e = creds.expiresAt { oauth["expiresAt"] = Int(e.timeIntervalSince1970 * 1000) }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else { return }
        AccountFiles.writePrivate(data, to: ownStoreURL)
    }

    func clearOwnCopy() {
        memoryCache = nil
        lastKeychainAttempt = nil
        try? FileManager.default.removeItem(at: ownStoreURL)
    }

    static func parseCredentialsJSON(_ data: Data) -> Credentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        var expires: Date?
        if let ms = number(oauth["expiresAt"]) {
            expires = Date(timeIntervalSince1970: ms / 1000.0)
        }
        return Credentials(accessToken: token, expiresAt: expires)
    }

    static func keychainData(service: String, account: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Claude Code writes its Keychain item with Apple's `security` tool, so
    /// that tool is on the item's access list. Reading through it doesn't ask
    /// for the Mac password, and the access survives Brink being rebuilt and
    /// Claude Code rewriting the item on every token refresh, both of which
    /// drop a direct `SecItemCopyMatching` grant. The secret arrives on stdout,
    /// never in argv.
    static func keychainDataViaSecurityTool(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        // `-w` prints the secret plus a trailing newline.
        var trimmed = data
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Demo fallback

    static func demoSnapshot(name: String, systemImage: String, note: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: name.lowercased(), name: name, systemImage: systemImage,
            windows: [
                UsageWindow(label: "Current session", usedPercent: 73,
                            resetsAt: Date().addingTimeInterval(51 * 60)),
                UsageWindow(label: "Weekly limit", usedPercent: 7,
                            resetsAt: Date().addingTimeInterval(36 * 3600)),
                UsageWindow(label: "Fable", usedPercent: 4,
                            resetsAt: Date().addingTimeInterval(36 * 3600)),
            ],
            error: note, isDemo: true, updatedAt: Date()
        )
    }
}
