import Foundation
import SQLite3

// MARK: - Types

/// Which limit window an attribution belongs to.
enum CostWindow: String {
    case session
    case weekly

    /// How long one period of this window lasts. Used with the reset time the API
    /// reports to find where the current period started.
    var duration: TimeInterval {
        switch self {
        case .session: return 5 * 3600
        case .weekly:  return 7 * 86400
        }
    }

    /// Maps a provider's window label (as parsed from the API) to a cost window.
    static func from(label: String) -> CostWindow? {
        switch label {
        case "Current session": return .session
        case "Weekly limit":    return .weekly
        default:                return nil   // per-model scoped windows are a subset
        }
    }
}

/// One assistant turn, deduplicated per request. Numbers only — never content.
struct UsageEvent {
    var ts: Int              // unix seconds, end of the request
    var sessionId: String
    var dedupeKey: String    // "r:<requestId>" or a synthetic key when absent
    var project: String      // resolved project root (git root, else cwd)
    var cwd: String          // the raw cwd, kept for provenance
    var branch: String?
    var model: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var ccVersion: String?
}

/// A row in the "what used it" list.
struct ProjectCost: Identifiable {
    var project: String
    var pct: Double
    var isUnexplained: Bool = false
    var mergedCount: Int = 0     // > 0 when this row aggregates several projects

    var id: String { project }

    var displayName: String {
        if isUnexplained { return L("Elsewhere") }
        if mergedCount > 0 { return L("Other (%d)", mergedCount) }
        return Self.shortName(for: project)
    }

    /// Folder names that say nothing on their own. When a path ends in one — which
    /// happens whenever the git root could not be resolved, e.g. the project has
    /// since been deleted — the parent is kept too, so the row reads "nodes/src"
    /// rather than a bare "src". The full path is always in the tooltip.
    private static let genericFolders: Set<String> = [
        "src", "source", "sources", "lib", "libs", "app", "apps", "core", "common",
        "shared", "packages", "package", "modules", "components", "dist", "build",
        "out", "bin", "scripts", "assets", "public", "static", "docs", "doc",
        "test", "tests", "spec", "api", "server", "client", "web", "windows",
        "macos", "ios", "android", "main", "index", "utils", "util",
    ]

    static func shortName(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return path }
        if genericFolders.contains(last.lowercased()), parts.count >= 2 {
            return parts[parts.count - 2] + "/" + last
        }
        return last
    }
}

// MARK: - Store

/// SQLite-backed store for token usage and limit attribution.
///
/// Design notes:
/// - Only the numeric usage fields plus cwd/branch/model are ever stored. No
///   message content, tool results or attachments are read (see CostIndexer).
/// - All access is serialised on one queue; SQLite is used from that queue only.
/// - Deduplication is by `requestId`: Claude Code writes the same assistant turn
///   several times while streaming, each write carrying a larger `output_tokens`.
///   We keep the maximum, so a turn is counted once at its final size.
final class CostStore {
    static let unexplainedKey = "__unexplained__"

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.semihtali.brink.cost")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // Weights that split a limit delta across turns within one interval. They are
    // relative, not absolute: cached input costs roughly a tenth of fresh input,
    // output several times more. Small errors do not accumulate across intervals.
    static let kOutput: Double = 5.0
    static let kCacheWrite: Double = 1.25
    static let kCacheRead: Double = 0.1

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle else { return nil }
        db = handle
        var ok = false
        queue.sync { ok = migrate() }
        guard ok else { sqlite3_close(db); return nil }
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: Schema

    private func migrate() -> Bool {
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        let schema = """
        CREATE TABLE IF NOT EXISTS file_cursor(
          path   TEXT PRIMARY KEY,
          inode  INTEGER NOT NULL,
          size   INTEGER NOT NULL,
          offset INTEGER NOT NULL,
          mtime  REAL    NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_event(
          id          INTEGER PRIMARY KEY,
          dedupe_key  TEXT    NOT NULL UNIQUE,
          ts          INTEGER NOT NULL,
          session_id  TEXT    NOT NULL,
          project     TEXT    NOT NULL,
          cwd         TEXT    NOT NULL,
          branch      TEXT,
          model       TEXT    NOT NULL,
          input       INTEGER NOT NULL,
          output      INTEGER NOT NULL,
          cache_read  INTEGER NOT NULL,
          cache_write INTEGER NOT NULL,
          cc_version  TEXT
        );
        CREATE INDEX IF NOT EXISTS ix_event_ts ON usage_event(ts);
        CREATE INDEX IF NOT EXISTS ix_event_project_ts ON usage_event(project, ts);
        CREATE TABLE IF NOT EXISTS quota_sample(
          id        INTEGER PRIMARY KEY,
          ts        INTEGER NOT NULL,
          window    TEXT    NOT NULL,
          pct       REAL    NOT NULL,
          resets_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS ix_sample_window_ts ON quota_sample(window, ts);
        CREATE TABLE IF NOT EXISTS attribution(
          id        INTEGER PRIMARY KEY,
          t0        INTEGER NOT NULL,
          t1        INTEGER NOT NULL,
          window    TEXT    NOT NULL,
          project   TEXT    NOT NULL,
          branch    TEXT,
          delta_pct REAL    NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ix_attr_window_t1 ON attribution(window, t1);
        CREATE TABLE IF NOT EXISTS period_boundary(
          id     INTEGER PRIMARY KEY,
          ts     INTEGER NOT NULL,
          window TEXT    NOT NULL
        );
        CREATE INDEX IF NOT EXISTS ix_boundary_window_ts ON period_boundary(window, ts);
        CREATE TABLE IF NOT EXISTS parse_error(
          ts     INTEGER NOT NULL,
          path   TEXT    NOT NULL,
          reason TEXT    NOT NULL
        );
        """
        _ = exec(schema)
        // Databases from 0.6.0-dev predate resets_at; a no-op once the column exists.
        exec("ALTER TABLE quota_sample ADD COLUMN resets_at INTEGER;")
        return true
    }

    // MARK: Low-level helpers (queue-confined)

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        return st
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(st, i, v, -1, Self.transient) } else { sqlite3_bind_null(st, i) }
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    // MARK: File cursors

    struct FileCursor {
        var inode: Int
        var size: Int
        var offset: Int
    }

    func fileCursor(_ path: String) -> FileCursor? {
        queue.sync {
            guard let st = prepare("SELECT inode, size, offset FROM file_cursor WHERE path = ?1") else { return nil }
            defer { sqlite3_finalize(st) }
            bind(st, 1, path)
            guard sqlite3_step(st) == SQLITE_ROW else { return nil }
            return FileCursor(inode: Int(sqlite3_column_int64(st, 0)),
                              size: Int(sqlite3_column_int64(st, 1)),
                              offset: Int(sqlite3_column_int64(st, 2)))
        }
    }

    /// Writes the events of one file and advances its cursor in a single transaction,
    /// so an interrupted run never leaves the cursor ahead of the stored rows.
    func commit(events: [UsageEvent], path: String, inode: Int, size: Int, offset: Int, mtime: Double) {
        queue.sync {
            exec("BEGIN IMMEDIATE;")
            let sql = """
            INSERT INTO usage_event
              (dedupe_key, ts, session_id, project, cwd, branch, model, input, output, cache_read, cache_write, cc_version)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
            ON CONFLICT(dedupe_key) DO UPDATE SET
              ts          = MAX(usage_event.ts,          excluded.ts),
              input       = MAX(usage_event.input,       excluded.input),
              output      = MAX(usage_event.output,      excluded.output),
              cache_read  = MAX(usage_event.cache_read,  excluded.cache_read),
              cache_write = MAX(usage_event.cache_write, excluded.cache_write);
            """
            if let st = prepare(sql) {
                for e in events {
                    bind(st, 1, e.dedupeKey)
                    sqlite3_bind_int64(st, 2, Int64(e.ts))
                    bind(st, 3, e.sessionId)
                    bind(st, 4, e.project)
                    bind(st, 5, e.cwd)
                    bind(st, 6, e.branch)
                    bind(st, 7, e.model)
                    sqlite3_bind_int64(st, 8, Int64(e.input))
                    sqlite3_bind_int64(st, 9, Int64(e.output))
                    sqlite3_bind_int64(st, 10, Int64(e.cacheRead))
                    sqlite3_bind_int64(st, 11, Int64(e.cacheWrite))
                    bind(st, 12, e.ccVersion)
                    sqlite3_step(st)
                    sqlite3_reset(st)
                }
                sqlite3_finalize(st)
            }
            if let st = prepare("""
                INSERT INTO file_cursor(path, inode, size, offset, mtime) VALUES(?1,?2,?3,?4,?5)
                ON CONFLICT(path) DO UPDATE SET inode=excluded.inode, size=excluded.size,
                                                offset=excluded.offset, mtime=excluded.mtime;
                """) {
                bind(st, 1, path)
                sqlite3_bind_int64(st, 2, Int64(inode))
                sqlite3_bind_int64(st, 3, Int64(size))
                sqlite3_bind_int64(st, 4, Int64(offset))
                sqlite3_bind_double(st, 5, mtime)
                sqlite3_step(st)
                sqlite3_finalize(st)
            }
            exec("COMMIT;")
        }
    }

    func recordParseErrors(path: String, count: Int, reason: String) {
        guard count > 0 else { return }
        queue.sync {
            guard let st = prepare("INSERT INTO parse_error(ts, path, reason) VALUES(?1,?2,?3)") else { return }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int64(st, 1, Int64(Date().timeIntervalSince1970))
            bind(st, 2, path)
            bind(st, 3, "\(reason) ×\(count)")
            sqlite3_step(st)
        }
    }

    // MARK: Quota sampling and attribution

    /// Records one quota reading and attributes any increase since the last one.
    /// Called after every usage poll — no extra network traffic.
    func recordSample(window: CostWindow, pct: Double, resetsAt: Date? = nil, at date: Date = Date()) {
        queue.sync {
            let ts = Int(date.timeIntervalSince1970)
            let prev = lastSample(window)
            insertSample(window: window, pct: pct, ts: ts, resetsAt: resetsAt)

            guard let prev else { return }             // first sample: nothing to compare
            let delta = pct - prev.pct

            if delta < 0 {                             // the limit reset
                insertBoundary(window: window, ts: ts)
                return
            }
            guard delta > 0 else { return }            // no measurable change yet

            attribute(window: window, delta: delta, t0: anchor(window: window), t1: ts)
        }
    }

    private func lastSample(_ window: CostWindow) -> (ts: Int, pct: Double, resetsAt: Int?)? {
        let sql = SELECT_LAST_SAMPLE
        guard let st = prepare(sql) else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, 1, window.rawValue)
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        let resets = sqlite3_column_type(st, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(st, 2))
        return (Int(sqlite3_column_int64(st, 0)), sqlite3_column_double(st, 1), resets)
    }

    private let SELECT_LAST_SAMPLE =
        "SELECT ts, pct, resets_at FROM quota_sample WHERE window=?1 ORDER BY ts DESC LIMIT 1"

    private func insertSample(window: CostWindow, pct: Double, ts: Int, resetsAt: Date?) {
        guard let st = prepare("INSERT INTO quota_sample(ts, window, pct, resets_at) VALUES(?1,?2,?3,?4)") else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(ts))
        bind(st, 2, window.rawValue)
        sqlite3_bind_double(st, 3, pct)
        if let resetsAt { sqlite3_bind_int64(st, 4, Int64(resetsAt.timeIntervalSince1970)) }
        else { sqlite3_bind_null(st, 4) }
        sqlite3_step(st)
    }

    /// Token weight per project for the turns in (from, to].
    private func weights(from: Int, to: Int) -> (byProject: [String: Double], total: Double) {
        var byProject: [String: Double] = [:]
        var total = 0.0
        let sql = "SELECT project, input, output, cache_read, cache_write"
                + " FROM usage_event WHERE ts > ?1 AND ts <= ?2"
        guard let st = prepare(sql) else { return ([:], 0) }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(from))
        sqlite3_bind_int64(st, 2, Int64(to))
        while sqlite3_step(st) == SQLITE_ROW {
            let project = text(st, 0) ?? Self.unexplainedKey
            let w = Double(sqlite3_column_int64(st, 1))
                  + Double(sqlite3_column_int64(st, 2)) * Self.kOutput
                  + Double(sqlite3_column_int64(st, 3)) * Self.kCacheRead
                  + Double(sqlite3_column_int64(st, 4)) * Self.kCacheWrite
            byProject[project, default: 0] += w
            total += w
        }
        return (byProject, total)
    }

    private func insertBoundary(window: CostWindow, ts: Int) {
        guard let st = prepare("INSERT INTO period_boundary(ts, window) VALUES(?1,?2)") else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(ts))
        bind(st, 2, window.rawValue)
        sqlite3_step(st)
    }

    /// Start of the interval to attribute: the last point already accounted for.
    ///
    /// Zero deltas deliberately leave the anchor behind. The endpoint reports whole
    /// percents, so a turn often lands in a poll that still reads the same number;
    /// keeping the anchor means the next rise is credited to every turn since the
    /// last one that was actually attributed, not just the last two minutes.
    ///
    /// With nothing attributed yet the anchor is the first sample of the period —
    /// never the previous sample, which would silently drop everything before it.
    private func anchor(window: CostWindow) -> Int {
        var t0 = 0
        if let st = prepare("SELECT MAX(t1) FROM attribution WHERE window=?1") {
            bind(st, 1, window.rawValue)
            if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL {
                t0 = max(t0, Int(sqlite3_column_int64(st, 0)))
            }
            sqlite3_finalize(st)
        }
        if let st = prepare("SELECT MAX(ts) FROM period_boundary WHERE window=?1") {
            bind(st, 1, window.rawValue)
            if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL {
                t0 = max(t0, Int(sqlite3_column_int64(st, 0)))
            }
            sqlite3_finalize(st)
        }
        if t0 > 0 { return t0 }

        // Nothing attributed and no reset seen: the period starts at the first
        // reading we took. Consumption from before Brink was running is not ours
        // to explain.
        if let st = prepare("SELECT MIN(ts) FROM quota_sample WHERE window=?1") {
            bind(st, 1, window.rawValue)
            if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL {
                t0 = Int(sqlite3_column_int64(st, 0))
            }
            sqlite3_finalize(st)
        }
        return t0
    }

    private func attribute(window: CostWindow, delta: Double, t0: Int, t1: Int) {
        let (byProject, total) = weights(from: t0, to: t1)

        let sql = "INSERT INTO attribution(t0, t1, window, project, branch, delta_pct)"
                + " VALUES(?1,?2,?3,?4,?5,?6)"
        guard let st = prepare(sql) else { return }
        defer { sqlite3_finalize(st) }

        func insert(project: String, pct: Double) {
            sqlite3_bind_int64(st, 1, Int64(t0))
            sqlite3_bind_int64(st, 2, Int64(t1))
            bind(st, 3, window.rawValue)
            bind(st, 4, project)
            sqlite3_bind_null(st, 5)
            sqlite3_bind_double(st, 6, pct)
            sqlite3_step(st)
            sqlite3_reset(st)
        }

        if total <= 0 {
            // Nothing local explains this consumption: claude.ai, another machine,
            // a background job. Surfaced honestly rather than hidden.
            insert(project: Self.unexplainedKey, pct: delta)
            return
        }
        for (project, weight) in byProject {
            insert(project: project, pct: delta * (weight / total))
        }
    }

    // MARK: Reading

    /// Attribution for the current period of a window, largest first.
    ///
    /// Observed deltas only cover the stretches Brink was running for. Anything
    /// else — the app closed, the Mac asleep, a period that began before Brink
    /// was ever launched — would otherwise leave the list adding up to less than
    /// the percentage on the card. The remainder is therefore spread across the
    /// turns recorded in this period, so the rows always account for the whole of
    /// what the card reports.
    func currentPeriod(window: CostWindow) -> [ProjectCost] {
        queue.sync {
            var totals: [String: Double] = [:]

            var periodStart = 0
            if let st = prepare("SELECT MAX(ts) FROM period_boundary WHERE window=?1") {
                bind(st, 1, window.rawValue)
                if sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL {
                    periodStart = Int(sqlite3_column_int64(st, 0))
                }
                sqlite3_finalize(st)
            }

            let latest = lastSample(window)
            // A reset time is the firmer boundary: it tells us where this period
            // began even if Brink never saw the reset happen.
            if let resets = latest?.resetsAt {
                periodStart = max(periodStart, resets - Int(window.duration))
            }

            let sql = "SELECT project, SUM(delta_pct) FROM attribution"
                    + " WHERE window = ?1 AND t1 > ?2 GROUP BY project"
            if let st = prepare(sql) {
                bind(st, 1, window.rawValue)
                sqlite3_bind_int64(st, 2, Int64(periodStart))
                while sqlite3_step(st) == SQLITE_ROW {
                    totals[text(st, 0) ?? Self.unexplainedKey, default: 0] += sqlite3_column_double(st, 1)
                }
                sqlite3_finalize(st)
            }

            if let latest {
                let observed = totals.values.reduce(0, +)
                let gap = latest.pct - observed
                if gap > 0.25, periodStart > 0 {
                    let (byProject, total) = weights(from: periodStart, to: latest.ts)
                    if total > 0 {
                        for (project, weight) in byProject {
                            totals[project, default: 0] += gap * (weight / total)
                        }
                    } else {
                        totals[Self.unexplainedKey, default: 0] += gap
                    }
                }
            }

            return totals
                .map { ProjectCost(project: $0.key, pct: $0.value,
                                   isUnexplained: $0.key == Self.unexplainedKey) }
                .sorted { $0.pct > $1.pct }
        }
    }

    /// Queue-confined wrapper around the interval weighting, for the share views.
    func weightsPublic(from: Int, to: Int) -> (byProject: [String: Double], total: Double) {
        queue.sync { weights(from: from, to: to) }
    }

    /// Token weight per project across every turn ever indexed.
    func allWeights() -> (byProject: [String: Double], total: Double) {
        queue.sync {
            var byProject: [String: Double] = [:]
            var total = 0.0
            let sql = "SELECT project, SUM(input + output * ?1 + cache_read * ?2 + cache_write * ?3)"
                    + " FROM usage_event GROUP BY project"
            guard let st = prepare(sql) else { return ([:], 0) }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_double(st, 1, Self.kOutput)
            sqlite3_bind_double(st, 2, Self.kCacheRead)
            sqlite3_bind_double(st, 3, Self.kCacheWrite)
            while sqlite3_step(st) == SQLITE_ROW {
                let project = text(st, 0) ?? Self.unexplainedKey
                let w = sqlite3_column_double(st, 1)
                byProject[project] = w
                total += w
            }
            return (byProject, total)
        }
    }

    /// Diagnostics for the settings menu.
    func stats() -> (events: Int, files: Int, errors: Int) {
        queue.sync {
            func count(_ sql: String) -> Int {
                guard let st = prepare(sql) else { return 0 }
                defer { sqlite3_finalize(st) }
                return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
            }
            return (count("SELECT COUNT(*) FROM usage_event"),
                    count("SELECT COUNT(*) FROM file_cursor"),
                    count("SELECT COUNT(*) FROM parse_error"))
        }
    }
}

// MARK: - Presentation

extension Array where Element == ProjectCost {
    /// Top rows by name, the rest merged into one, `Elsewhere` always last.
    func presentable(limit: Int = 4) -> [ProjectCost] {
        let known = filter { !$0.isUnexplained && $0.pct > 0.0001 }
        let unexplained = filter(\.isUnexplained).reduce(0.0) { $0 + $1.pct }
        var rows = Array(known.prefix(limit))
        let rest = known.dropFirst(limit)
        if !rest.isEmpty {
            rows.append(ProjectCost(project: "__other__",
                                    pct: rest.reduce(0) { $0 + $1.pct },
                                    mergedCount: rest.count))
        }
        if unexplained > 0.0001 {
            rows.append(ProjectCost(project: CostStore.unexplainedKey,
                                    pct: unexplained, isUnexplained: true))
        }
        return rows
    }
}

// MARK: - Ranges

/// What the breakdown is measured over.
///
/// The two limit windows report *percent of the limit* — the same number the card
/// shows. All-time has no limit to measure against, so it reports each project's
/// *share of total work* instead; both are percentages, and the UI says which.
enum CostRange: String, CaseIterable, Identifiable {
    case session
    case weekly
    case month
    case allTime

    var id: String { rawValue }

    /// Used as the section heading, where there is room for a full phrase.
    var title: String {
        switch self {
        case .session: return L("This session")
        case .weekly:  return L("This week")
        case .month:   return L("This month")
        case .allTime: return L("All time")
        }
    }

    /// Used in the picker, where four labels have to fit on one line.
    var shortTitle: String {
        switch self {
        case .session: return L("Session")
        case .weekly:  return L("Week")
        case .month:   return L("Month")
        case .allTime: return L("All")
        }
    }

    /// The limit window this range measures, if any. Anthropic resets on a five
    /// hour session and a seven day week; there is no monthly limit, so a month
    /// can only be expressed as a share of the work done in it.
    var window: CostWindow? {
        switch self {
        case .session: return .session
        case .weekly:  return .weekly
        case .month, .allTime: return nil
        }
    }

    /// Start of the range for the share-based views.
    var start: Date? {
        switch self {
        case .month:
            let cal = Calendar.current
            return cal.date(from: cal.dateComponents([.year, .month], from: Date()))
        default:
            return nil
        }
    }

    /// True when percentages mean "share of your own work", not "share of the limit".
    var isShare: Bool { window == nil }
}

extension CostStore {
    /// Every project's share of all recorded work, as a percentage summing to 100.
    /// Read straight from the turns, so it covers everything indexed — including
    /// periods that ended long ago.
    func allTimeShare() -> [ProjectCost] {
        let (byProject, total) = allWeights()
        guard total > 0 else { return [] }
        return byProject
            .map { ProjectCost(project: $0.key, pct: $0.value / total * 100,
                               isUnexplained: $0.key == Self.unexplainedKey) }
            .sorted { $0.pct > $1.pct }
    }

    /// Share of the work recorded since a given moment, as percentages summing to 100.
    func share(since: Date) -> [ProjectCost] {
        let now = Int(Date().timeIntervalSince1970)
        let (byProject, total) = weightsPublic(from: Int(since.timeIntervalSince1970), to: now)
        guard total > 0 else { return [] }
        return byProject
            .map { ProjectCost(project: $0.key, pct: $0.value / total * 100,
                               isUnexplained: $0.key == Self.unexplainedKey) }
            .sorted { $0.pct > $1.pct }
    }

    func rows(for range: CostRange) -> [ProjectCost] {
        if let window = range.window { return currentPeriod(window: window) }
        if let start = range.start { return share(since: start) }
        return allTimeShare()
    }
}
