import Foundation

// MARK: - The `cache` objects of the summary

/// Prompt cache by span ("today", "7d", "30d"), as `accounts[].cache`, the top-level `cache` and
/// `antigravity.cache` carry it (`usage/STATE-ADDITIONS-24.md`, "Cache"). Decoding never throws: a malformed
/// object reads as empty and a malformed span drops only itself.
public struct UsageCacheStats: Decodable, Sendable, Equatable {
    public var spans: [String: Span]

    public struct Span: Decodable, Sendable, Equatable {
        /// Of the prompt tokens that could have come from the cache, the part that did.
        public var readPct: Double?
        /// The part paid at the full input price (for Claude, cache writes count here).
        public var missPct: Double?
        public var calls: Double?
        public var readTokens: Double?
        public var missTokens: Double?
        public var writeTokens: Double?
        /// What the reads saved against the full input price, API dollars.
        public var savedUsd: Double?
        /// What the misses cost above the cache-read price, API dollars.
        public var missUsd: Double?
        /// Antigravity only: share of calls that read nothing from the cache.
        public var coldCallsPct: Double?

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            func number(_ key: Key) -> Double? {
                keys?.lenient(Double.self, key)
            }
            self.readPct = number(.readPct)
            self.missPct = number(.missPct)
            self.calls = number(.calls)
            self.readTokens = number(.readTokens)
            self.missTokens = number(.missTokens)
            self.writeTokens = number(.writeTokens)
            self.savedUsd = number(.savedUsd)
            self.missUsd = number(.missUsd)
            self.coldCallsPct = number(.coldCallsPct)
        }

        enum Key: String, CodingKey {
            case readPct, missPct, calls, readTokens, missTokens, writeTokens, savedUsd, missUsd, coldCallsPct
        }

        /// Percent reused, from `readPct` or, in older summaries, `100 - missPct`.
        public var reusedPct: Double? {
            if let readPct, readPct.isFinite {
                return min(100, max(0, readPct))
            }
            if let missPct, missPct.isFinite {
                return min(100, max(0, 100 - missPct))
            }
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let single = try? decoder.singleValueContainer()
        let raw = (try? single?.decode([String: Lenient<Span>].self)) ?? [:]
        self.spans = raw.compactMapValues(\.value)
    }

    init(spans: [String: Span]) {
        self.spans = spans
    }

    public subscript(key: String) -> Span? {
        self.spans[key]
    }

    /// Some span has a percentage to show.
    public var hasData: Bool {
        self.spans.values.contains { $0.reusedPct != nil }
    }
}

// MARK: - What the cache row and panel show

/// The cache of Claude Code (all accounts, then each account) or of Antigravity (then each model), ready to
/// draw: the compact menu row (`UsageCacheRowView`) and its detail panel (`UsageCachePanelView`).
public struct UsageCacheSummary: Sendable, Equatable {
    public enum Product: Sendable, Equatable {
        case claude
        case antigravity
    }

    public struct Span: Sendable, Equatable, Identifiable {
        public let id: String
        /// "Today", "7 days", "30 days".
        public let title: String
        public let reusedPct: Double
        public let savedUsd: Double?
        public let missUsd: Double?
    }

    /// One account (Claude) or one model (Antigravity).
    public struct Part: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let reusedPct: Double
        public let savedUsd: Double?
    }

    public let product: Product
    /// Spans with a percentage, in the order today, 7 days, 30 days.
    public let spans: [Span]
    /// The span the row and the panel's picture show: a week is steady; 30 days and today are the fallbacks.
    public let main: Span
    public let parts: [Part]
    /// "By account · 7 days", "By model · 30 days".
    public let partsTitle: String

    /// Row id for the menu. Claude's is its own; Antigravity's carries the page prefix, so the page's
    /// warm-row recycling picks it up.
    public var rowID: String {
        switch self.product {
        case .claude: "lemelsonCache-claude"
        case .antigravity: UsageAntigravityPage.idPrefix + "cache"
        }
    }

    public var productName: String {
        self.product == .claude ? "Claude Code" : "Antigravity"
    }

    static let spanTitles: [(key: String, title: String)] = [("today", "Today"), ("7d", "7 days"), ("30d", "30 days")]
    private static let mainOrder = ["7d", "30d", "today"]

    static func spans(of stats: UsageCacheStats?) -> [Span] {
        guard let stats else { return [] }
        return self.spanTitles.compactMap { key, title in
            guard let span = stats[key], let reused = span.reusedPct else { return nil }
            return Span(id: key, title: title, reusedPct: reused, savedUsd: span.savedUsd, missUsd: span.missUsd)
        }
    }

    private static func main(of spans: [Span]) -> Span? {
        for key in self.mainOrder {
            if let span = spans.first(where: { $0.id == key }) {
                return span
            }
        }
        return nil
    }

    /// Claude Code: the top-level `cache`, or the accounts' caches combined when it is missing; one part per
    /// account that has data. Nil when no span has a percentage, and when the collector's cache step failed
    /// (`cacheError`): the row is then simply absent.
    public static func claude(_ state: UsagePanelState) -> UsageCacheSummary? {
        guard state.cacheError == nil else { return nil }
        let spans = self.spans(of: state.cache ?? self.combined(state.accounts.compactMap(\.cache)))
        guard let main = self.main(of: spans) else { return nil }
        let parts: [Part] = state.orderedAccounts.compactMap { account in
            let own = self.spans(of: account.cache)
            guard let span = own.first(where: { $0.id == main.id }) ?? self.main(of: own) else { return nil }
            return Part(id: account.uuid, name: account.displayName, reusedPct: span.reusedPct, savedUsd: span.savedUsd)
        }
        return UsageCacheSummary(
            product: .claude,
            spans: spans,
            main: main,
            parts: parts.count >= 2 ? parts : [],
            partsTitle: "By account · \(main.title.lowercased())")
    }

    /// Antigravity: `antigravity.cache`; one part per model of the last 30 days, most spend first.
    public static func antigravity(_ block: UsageAntigravityBlock) -> UsageCacheSummary? {
        guard block.error == nil else { return nil }
        let spans = self.spans(of: block.cache)
        guard let main = self.main(of: spans) else { return nil }
        let models = block.models
            .compactMap { id, stats -> (String, Double, Double)? in
                guard let miss = stats.missPct, miss.isFinite, (stats.calls ?? 1) > 0 else { return nil }
                return (id, min(100, max(0, 100 - miss)), stats.usd ?? 0)
            }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
        let labels = UsageAntigravityModels.labels(for: models.map(\.0))
        let parts = models.map { Part(id: $0.0, name: labels[$0.0] ?? $0.0, reusedPct: $0.1, savedUsd: nil) }
        return UsageCacheSummary(
            product: .antigravity,
            spans: spans,
            main: main,
            parts: parts.count >= 2 ? parts : [],
            partsTitle: "By model · 30 days")
    }

    /// Accounts together when the summary has no top-level cache: percentages weighted by the tokens behind
    /// them (or by calls), dollars added up.
    static func combined(_ all: [UsageCacheStats]) -> UsageCacheStats? {
        guard !all.isEmpty else { return nil }
        var spans: [String: UsageCacheStats.Span] = [:]
        for (key, _) in self.spanTitles {
            let present = all.compactMap { stats -> (UsageCacheStats.Span, Double)? in
                guard let span = stats[key], let reused = span.reusedPct else { return nil }
                let tokens = reused > 0 ? (span.readTokens ?? 0) * 100 / reused : 0
                let weight = tokens > 0 ? tokens : span.calls ?? 1
                return (span, weight)
            }
            let weight = present.reduce(0) { $0 + $1.1 }
            guard weight > 0, var first = present.first?.0 else { continue }
            first.readPct = present.reduce(0) { $0 + ($1.0.reusedPct ?? 0) * $1.1 } / weight
            first.missPct = 100 - (first.readPct ?? 0)
            first.calls = present.reduce(0) { $0 + ($1.0.calls ?? 0) }
            first.savedUsd = self.sum(present.map(\.0.savedUsd))
            first.missUsd = self.sum(present.map(\.0.missUsd))
            spans[key] = first
        }
        return spans.isEmpty ? nil : UsageCacheStats(spans: spans)
    }

    private static func sum(_ values: [Double?]) -> Double? {
        let known = values.compactMap(\.self)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// Some span carries dollars: the panel then shows what reuse saved.
    var hasMoney: Bool {
        self.spans.contains { $0.savedUsd != nil }
    }
}
