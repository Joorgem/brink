import Foundation
import CryptoKit

/// Renews an idle Claude account's login the way Claude Code does when it
/// starts, so extra accounts keep reporting without being opened.
///
/// Each renewal rotates the refresh token: the old one stops working once
/// Anthropic answers. The only way to lose a login is for the new pair to
/// never reach Claude Code's store, so:
/// - Brink renews only a login that expired over an hour ago. Claude Code keeps
///   the token fresh while it's in use, so by then no session of it is about to
///   renew the same token (an idle open session could still hold the old one).
/// - Renewals are serialized per store, and the store is re-read right before
///   the request: a token Claude Code already replaced is never sent.
/// - Before spending the token, Brink proves it can write both the pending file
///   and the store (rewriting the store's current bytes unchanged).
/// - The new credentials go to a private pending file first, then to Claude
///   Code's store (Keychain item or `.credentials.json`), which is read back to
///   check. If the write fails, the pending file is replayed on the next refresh.
/// - The pending file is the only place Brink keeps a refresh token, and only
///   until the store write is confirmed.
/// A dropped connection after Anthropic rotated the token but before the reply
/// arrived can't be recovered by anyone; that account then needs `/login`.
enum ClaudeTokenRefresher {
    /// Where Claude Code keeps an account's credentials JSON.
    enum Store {
        case keychain(service: String)
        case file(URL)

        func read() -> Data? {
            switch self {
            case .keychain(let service): return ClaudeProvider.keychainDataViaSecurityTool(service: service)
            case .file(let url): return try? Data(contentsOf: url)
            }
        }

        func write(_ data: Data) -> Bool {
            switch self {
            case .keychain(let service): return SecurityTool.update(service: service, data: data)
            // Same 0600 file Claude Code writes; atomic so it's never half-written.
            case .file(let url): return AccountFiles.writePrivate(data, to: url)
            }
        }

        var key: String {
            switch self {
            case .keychain(let service): return "keychain:" + service
            case .file(let url): return "file:" + url.path
            }
        }
    }

    /// One renewal at a time per store; a second caller waits for the first's result.
    private actor Gate {
        private var running: [String: Task<Data?, Never>] = [:]

        func run(_ key: String, _ work: @escaping @Sendable () async -> Data?) async -> Data? {
            if let task = running[key] { return await task.value }
            let task = Task { await work() }
            running[key] = task
            let result = await task.value
            running[key] = nil
            return result
        }
    }
    private static let gate = Gate()

    /// A login must have been expired this long before Brink renews it.
    private static let idleMargin: TimeInterval = 60 * 60

    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Renews the login in `store`.
    /// Returns the new credentials JSON once it is safely in the store, or nil.
    static func renew(store: Store, pendingURL: URL) async -> Data? {
        await gate.run(store.key) { await renewNow(store: store, pendingURL: pendingURL) }
    }

    private static func renewNow(store: Store, pendingURL: URL) async -> Data? {
        // Re-read: Claude Code may have renewed (or you signed in) meanwhile.
        guard let current = store.read() else { return nil }
        guard var root = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            return nil
        }

        // A renewal whose store write didn't land last time: the store still
        // holds the refresh token it replaced, so finish that write instead of
        // spending the (already dead) old token.
        if let pending = Pending.load(from: pendingURL) {
            if pending.replaces == fingerprint(refreshToken) {
                if await commit(pending.data, to: store) {
                    try? FileManager.default.removeItem(at: pendingURL)
                    return pending.data
                }
                return nil
            }
            // The store moved on (Claude Code renewed or you signed in again).
            try? FileManager.default.removeItem(at: pendingURL)
        }

        if let ms = ClaudeProvider.number(oauth["expiresAt"]),
           Date().timeIntervalSince1970 - ms / 1000 < idleMargin {
            return nil   // expired too recently; Claude Code may still be about to renew it
        }
        // Prove both writes work before the token is spent: the pending file,
        // and the store with its own current bytes (a no-op for Claude Code).
        guard Pending(replaces: "", data: current).save(to: pendingURL) else { return nil }
        try? FileManager.default.removeItem(at: pendingURL)
        guard await commit(current, to: store) else { return nil }

        guard let reply = await requestNewTokens(refreshToken: refreshToken),
              let access = reply["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        oauth["accessToken"] = access
        if let newRefresh = reply["refresh_token"] as? String, !newRefresh.isEmpty {
            oauth["refreshToken"] = newRefresh
        }
        if let seconds = ClaudeProvider.number(reply["expires_in"]) {
            oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + seconds) * 1000)
        }
        root["claudeAiOauth"] = oauth
        guard let updated = try? JSONSerialization.data(withJSONObject: root) else { return nil }

        // If even this fails, still try the store: it's the copy that matters.
        Pending(replaces: fingerprint(refreshToken), data: updated).save(to: pendingURL)
        guard await commit(updated, to: store) else { return nil }   // pending stays for the next try
        try? FileManager.default.removeItem(at: pendingURL)
        return updated
    }

    /// Writes and reads back, with one retry.
    private static func commit(_ data: Data, to store: Store) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            if store.write(data), store.read() == data { return true }
        }
        return false
    }

    private static func requestNewTokens(refreshToken: String) async -> [String: Any]? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Brink/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Identifies a refresh token without storing it.
    private static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The renewed credentials, kept until the store write is confirmed.
    private struct Pending: Codable {
        var replaces: String   // fingerprint of the refresh token it supersedes
        var data: Data

        static func load(from url: URL) -> Pending? {
            guard let raw = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Pending.self, from: raw)
        }

        @discardableResult
        func save(to url: URL) -> Bool {
            guard let raw = try? JSONEncoder().encode(self) else { return false }
            return AccountFiles.writePrivate(raw, to: url)
        }
    }
}

/// Writes Claude Code's Keychain item through `/usr/bin/security`, the tool
/// Claude Code itself uses, so the item's access list stays as it was.
private enum SecurityTool {
    static func update(service: String, data: Data) -> Bool {
        guard let account = account(service: service),
              !account.contains("\""), !service.contains("\"") else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        // Interactive mode reads the command from stdin, so the secret never
        // shows up in argv (and `ps`).
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        return run(["-i"], input: Data(command.utf8)) != nil
    }

    /// The item's account attribute, so the update hits the same item.
    private static func account(service: String) -> String? {
        guard let out = run(["find-generic-password", "-s", service], input: nil),
              let text = String(data: out, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("\"acct\"<blob>=\"") {
            guard let start = line.range(of: "<blob>=\"")?.upperBound,
                  let end = line.lastIndex(of: "\""), start < end else { return nil }
            return String(line[start..<end])
        }
        return nil
    }

    /// Runs `security`; returns stdout on exit status 0.
    private static func run(_ arguments: [String], input: Data?) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let inPipe = Pipe()
        if input != nil { process.standardInput = inPipe }
        do { try process.run() } catch { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }
        let result = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? result : nil
    }
}
