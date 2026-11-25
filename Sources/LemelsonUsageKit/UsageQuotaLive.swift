import Foundation

// The live readings files of a provider quota (contract: usage/ANTIGRAVITY-STATE.md, section
// "Live readings file (written by the app)"; usage/CODEX-STATE.md uses the same format):
// `antigravity-quota.jsonl` (Antigravity's Gemini 5-hour and weekly quota) and `codex-quota.jsonl` (Codex's
// session and weekly window). CodexBar's own history keeps only the peak of each clock hour; every fresh
// reading the app gets is appended here, and the collector imports it.
//
//   {"ts": 1795424947, "source": "codexbar-live", "windows": {"5h": {"pct": 1.0, "resetsAt": 1795439520}, …},
//    "plan": "…", "account": "codex:v1:provider-account:…"}
//
// "plan" is the plan or tier name exactly as the app fetched it with that reading; the key is left out when
// the fetch did not name one. "account" is the account the reading belongs to: the key CodexBar files that
// account's history under (`preferredAccountKey` in `history/<provider>.json`; for Codex
// `CodexHistoryOwnership.canonicalKey`), never an e-mail; left out while CodexBar has no key for it. A line
// of another account than the last one is written at once, so the collector can keep the accounts apart.
//
// A line goes in only when a value changed or ten minutes passed since the last line. Each line is
// written under the shared lock file (open, lock, append in one write, close, unlock), so the collector's
// compaction never loses it.

/// One quota reading: USED percent and reset time of the 5-hour and the weekly window.
public struct UsageQuotaLiveReading: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        /// Used percent, 0–100.
        public var pct: Double
        /// Epoch seconds, nil when unknown.
        public var resetsAt: Int?

        public init(pct: Double, resetsAt: Int?) {
            self.pct = pct
            self.resetsAt = resetsAt
        }

        public init(pct: Double, resetsAt: Date?) {
            self.init(pct: pct, resetsAt: resetsAt.map { Int($0.timeIntervalSince1970) })
        }
    }

    /// Epoch seconds the reading was taken at.
    public var ts: Int
    public var fiveHour: Window?
    public var week: Window?
    /// The plan or tier name the fetch gave, as is; nil when it named none. Not a value of the reading: a line
    /// is not written only because it changed.
    public var plan: String?
    /// The account the reading belongs to (see the file comment); nil when unknown.
    public var account: String?

    public init(ts: Int, fiveHour: Window?, week: Window?, plan: String? = nil, account: String? = nil) {
        self.ts = ts
        self.fiveHour = fiveHour.map(Self.normalized)
        self.week = week.map(Self.normalized)
        let trimmed = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.plan = trimmed?.isEmpty == false ? trimmed : nil
        let key = account?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.account = key?.isEmpty == false ? key : nil
    }

    public init(at date: Date, fiveHour: Window?, week: Window?, plan: String? = nil, account: String? = nil) {
        self.init(ts: Int(date.timeIntervalSince1970), fiveHour: fiveHour, week: week, plan: plan, account: account)
    }

    /// Clamped to 0–100 and rounded to hundredths: the fetch gives values like 59.199999999999996.
    private static func normalized(_ window: Window) -> Window {
        let clamped = min(100, max(0, window.pct.isFinite ? window.pct : 0))
        return Window(pct: (clamped * 100).rounded() / 100, resetsAt: window.resetsAt)
    }

    public var isEmpty: Bool {
        self.fiveHour == nil && self.week == nil
    }

    /// A reset time that moved by less than this is the same reset (the server rounds it differently
    /// from one reading to the next).
    public static let resetTolerance = 60

    /// Same account, same windows, same percentages and the same reset times (within `resetTolerance`).
    public func hasSameValues(as other: UsageQuotaLiveReading) -> Bool {
        func same(_ lhs: Window?, _ rhs: Window?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (lhs?, rhs?):
                guard lhs.pct == rhs.pct else { return false }
                switch (lhs.resetsAt, rhs.resetsAt) {
                case (nil, nil): return true
                case let (l?, r?): return abs(l - r) < Self.resetTolerance
                default: return false
                }
            default:
                return false
            }
        }
        return self.account == other.account && same(self.fiveHour, other.fiveHour) && same(self.week, other.week)
    }

    /// The line as written, `\n` included.
    public var jsonLine: String {
        func number(_ value: Double) -> String {
            value == value.rounded() ? String(format: "%.1f", value) : String(value)
        }
        func window(_ key: String, _ window: Window?) -> String? {
            guard let window else { return nil }
            let resets = window.resetsAt.map(String.init) ?? "null"
            return "\"\(key)\": {\"pct\": \(number(window.pct)), \"resetsAt\": \(resets)}"
        }
        let windows = [window("5h", self.fiveHour), window("7d", self.week)].compactMap(\.self)
        let plan = self.plan.map { ", \"plan\": \(Self.jsonString($0))" } ?? ""
        let account = self.account.map { ", \"account\": \(Self.jsonString($0))" } ?? ""
        let body = "\"ts\": \(self.ts), \"source\": \"codexbar-live\", \"windows\": {\(windows.joined(separator: ", "))}"
        return "{\(body)\(plan)\(account)}\n"
    }

    /// A JSON string literal, quotes included (one line: control characters are escaped).
    static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        // `["…"]` -> `"…"`.
        return String(array.dropFirst().dropLast())
    }

    /// Reads a line of the file back (nil for a broken or empty line).
    public init?(jsonLine line: some StringProtocol) {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = (object["ts"] as? NSNumber)?.intValue,
              let windows = object["windows"] as? [String: Any]
        else { return nil }
        func window(_ key: String) -> Window? {
            guard let raw = windows[key] as? [String: Any], let pct = (raw["pct"] as? NSNumber)?.doubleValue
            else { return nil }
            return Window(pct: pct, resetsAt: (raw["resetsAt"] as? NSNumber)?.intValue)
        }
        self.init(
            ts: ts, fiveHour: window("5h"), week: window("7d"), plan: object["plan"] as? String,
            account: object["account"] as? String)
    }
}

/// Appends readings to one provider's live file following the contract's rules. One writer per file: it
/// remembers the last line it wrote. An actor, so the file work (reading the tail, waiting for the shared
/// lock the collector may hold while it compacts, the write) runs on its own serial executor, never on the
/// main thread; calls to one writer run one at a time, and `decide` keeps the file in order and deduplicated.
public actor UsageQuotaLiveWriter {
    /// `antigravity-quota.jsonl`.
    public static let antigravity = UsageQuotaLiveWriter(url: UsageQuotaLiveWriter.url(fileName: "antigravity-quota.jsonl"))
    /// `codex-quota.jsonl`.
    public static let codex = UsageQuotaLiveWriter(url: UsageQuotaLiveWriter.url(fileName: "codex-quota.jsonl"))

    /// A file next to the summary (`state.json`).
    public nonisolated static func url(fileName: String) -> URL {
        UsagePanelStore.defaultURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// A line goes in at least this often while readings keep coming, even when nothing changed.
    public nonisolated static let interval = 600

    public enum Outcome: Equatable, Sendable {
        case written
        /// Same values as the last line, less than `interval` after it.
        case unchanged
        /// Not newer than the last line (the same snapshot seen again, or an older one).
        case stale
        /// No 5-hour or weekly window in the reading.
        case empty
        case failed(String)
    }

    public nonisolated let url: URL
    public nonisolated var lockURL: URL {
        self.url.appendingPathExtension("lock")
    }

    /// The last line written (or found at the end of the file on first use).
    public private(set) var last: UsageQuotaLiveReading?
    private var loadedLast = false

    public init(url: URL) {
        self.url = url
    }

    /// Whether `reading` goes into the file after `last`: some value changed, or ten minutes passed.
    public nonisolated static func decide(
        _ reading: UsageQuotaLiveReading,
        after last: UsageQuotaLiveReading?) -> Outcome
    {
        guard !reading.isEmpty else { return .empty }
        guard let last else { return .written }
        guard reading.ts > last.ts else { return .stale }
        if !reading.hasSameValues(as: last) { return .written }
        return reading.ts - last.ts >= self.interval ? .written : .unchanged
    }

    @discardableResult
    public func record(_ reading: UsageQuotaLiveReading) -> Outcome {
        if !self.loadedLast {
            self.loadedLast = true
            self.last = Self.lastLine(of: self.url)
        }
        let outcome = Self.decide(reading, after: self.last)
        guard outcome == .written else { return outcome }
        do {
            try Self.append(reading.jsonLine, to: self.url, lock: self.lockURL)
            self.last = reading
            return .written
        } catch {
            return .failed(String(describing: error))
        }
    }

    // MARK: - File

    public struct WriteError: Error, CustomStringConvertible {
        public let description: String
    }

    /// One line under the shared lock: open the lock file, take `flock`, open the data file for appending,
    /// write the whole line in one `write`, close it, release the lock. The data file is never kept open.
    public nonisolated static func append(_ line: String, to url: URL, lock lockURL: URL) throws {
        precondition(line.hasSuffix("\n") && !line.dropLast().contains("\n"), "one line, ending in \\n")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard lockFD >= 0 else { throw WriteError(description: "lock open: errno \(errno)") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else { throw WriteError(description: "flock: errno \(errno)") }
        defer { flock(lockFD, LOCK_UN) }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw WriteError(description: "open: errno \(errno)") }
        defer { close(fd) }
        let bytes = Array(line.utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else {
            throw WriteError(description: "write: \(written) of \(bytes.count) bytes, errno \(errno)")
        }
    }

    /// The last complete line of the file, read from its tail.
    public nonisolated static func lastLine(of url: URL) -> UsageQuotaLiveReading? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > 4096 ? size - 4096 : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        // Only lines that end in "\n" are complete.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast()
        for line in lines.reversed() {
            if let reading = UsageQuotaLiveReading(jsonLine: line) {
                return reading
            }
        }
        return nil
    }
}
