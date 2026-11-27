import Foundation

// MARK: - A provider block of the summary (`antigravity`, `codex`)

/// One provider with a single account next to the Claude accounts in `state.json`: Gemini use through
/// Antigravity (`state.antigravity`, contract `usage/ANTIGRAVITY-STATE.md`) and Codex (`state.codex`,
/// `usage/CODEX-STATE.md`, the same shape). Both decode with this one type.
///
/// The keys it shares with a Claude account (`windows`, `rates`, `daily`, `weeks`, `value`, ...) end up in
/// `account`, so the Claude views for limits and spend take it as is. Decoding never throws and goes key by
/// key: a missing or malformed key leaves out only its own part of the page, never the whole summary.
public struct UsageProviderBlock: Decodable, Sendable, Equatable {
    public var account: UsagePanelState.Account
    /// Always true for now: the token reading is reverse-engineered and the dollars are an estimate.
    public var beta: Bool
    /// Set when the collector's step for this provider failed; the block then has no data keys.
    public var error: String?
    /// Last 30 days, by priced model id.
    public var models: [String: ModelStats]
    /// Prompt cache by span: "today", "7d", "30d".
    public var cache: UsageCacheStats
    public var coverage: Coverage?
    public var quotaSource: QuotaSource?
    /// Why `account.value` is missing (too few readings), when it is.
    public var valueReason: String?
    /// How many pairs of readings the weekly value was measured from.
    public var valuePairs: Double?
    /// The value in the shape of `usage/ANTIGRAVITY-STATE.md` (plan, month, ×, per model); nil in older summaries.
    public var worth: Worth?
    /// How many full 5-hour windows one weekly window holds, measured by the collector (`windows.7d.sessions`).
    public var weekSessions: Sessions?
    /// How the weekly rate was measured (`rates.7d.method`, `pairsUsed`, `pairsDropped`).
    public var weekRate: RateNote?
    /// How far the collector is with measuring a week in 5-hour sessions (`calibration`); nil in older summaries.
    public var calibration: Calibration?

    public struct ModelStats: Decodable, Sendable, Equatable {
        public var calls: Double?
        public var input: Double?
        public var cached: Double?
        public var cacheWrite: Double?
        public var output: Double?
        public var thinking: Double?
        public var usd: Double?
        public var missPct: Double?
        public var priced: Bool?
        public var priceConfirmed: Bool?
    }

    /// `value`: what the plan buys at the provider's API prices.
    public struct Worth: Decodable, Sendable, Equatable {
        public var planName: String?
        /// Nil: the plan price is not known, so there is no "You pay" and no ×.
        public var planPriceUsd: Double?
        public var weekUsd: Double?
        public var monthUsd: Double?
        public var timesPrice: Double?
        public var pairs: Double?
        /// False: too little data; `reason` says why and the page shows it instead of numbers.
        public var confident: Bool?
        public var reason: String?
        public var byModel: [Model]

        public struct Model: Decodable, Sendable, Equatable {
            public var model: String?
            public var label: String?
            public var monthUsd: Double?
            public var timesPrice: Double?

            public init(from decoder: Decoder) throws {
                let keys = try? decoder.container(keyedBy: Key.self)
                self.model = keys?.lenient(String.self, .model)
                self.label = keys?.lenient(String.self, .label)
                self.monthUsd = keys?.lenient(Double.self, .monthUsd)
                self.timesPrice = keys?.lenient(Double.self, .timesPrice)
            }

            enum Key: String, CodingKey {
                case model, label, monthUsd, timesPrice
            }
        }

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            self.planName = keys?.lenient(String.self, .planName)
            self.planPriceUsd = keys?.lenient(Double.self, .planPriceUsd)
            self.weekUsd = keys?.lenient(Double.self, .weekUsd)
            self.monthUsd = keys?.lenient(Double.self, .monthUsd)
            self.timesPrice = keys?.lenient(Double.self, .timesPrice)
            self.pairs = keys?.lenient(Double.self, .pairs)
            self.confident = keys?.lenient(Bool.self, .confident)
            self.reason = keys?.lenient(String.self, .reason)
            self.byModel = keys?.lenient([Lenient<Model>].self, .byModel)?.compactMap(\.value) ?? []
        }

        enum Key: String, CodingKey {
            case planName, planPriceUsd, weekUsd, monthUsd, timesPrice, pairs, confident, reason, byModel
        }

        /// Written by a collector that knows this shape: it has `confident` or a month figure.
        var isNewShape: Bool {
            self.confident != nil || self.monthUsd != nil
        }
    }

    public struct Sessions: Decodable, Sendable, Equatable {
        public var perWeek: Double?
        public var pairs: Double?

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            self.perWeek = keys?.lenient(Double.self, .perWeek)
            self.pairs = keys?.lenient(Double.self, .pairs)
        }

        enum Key: String, CodingKey {
            case perWeek, pairs
        }
    }

    public struct RateNote: Decodable, Sendable, Equatable {
        /// One short sentence for the page.
        public var method: String?
        public var pairsUsed: Double?
        /// Pairs thrown out because the limit moved more than this Mac's spend explains.
        public var pairsDropped: Double?
        /// Pairs set aside because the limit moved much less than the other pairs agree on.
        public var pairsLow: Double?

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            self.method = keys?.lenient(String.self, .method)
            self.pairsUsed = keys?.lenient(Double.self, .pairsUsed)
            self.pairsDropped = keys?.lenient(Double.self, .pairsDropped)
            self.pairsLow = keys?.lenient(Double.self, .pairsLow)
        }

        enum Key: String, CodingKey {
            case method, pairsUsed, pairsDropped, pairsLow
        }
    }

    /// The parts of `calibration` the page reads: how many 5-hour windows were measured for the session size
    /// (`sessionIntervals`) and how many it takes (`thresholds.sessionPairs`).
    public struct Calibration: Decodable, Sendable, Equatable {
        public var sessionIntervals: Double?
        public var sessionPairsNeeded: Double?
        /// How many measured stretches the value needs before the collector calls it confident.
        public var valuePairsNeeded: Double?

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            self.sessionIntervals = keys?.lenient(Double.self, .sessionIntervals)
            let thresholds = keys?.lenient(Thresholds.self, .thresholds)
            self.sessionPairsNeeded = thresholds?.sessionPairs
            self.valuePairsNeeded = thresholds?.confidentStretches
        }

        private struct Thresholds: Decodable {
            var sessionPairs: Double?
            var confidentStretches: Double?

            init(from decoder: Decoder) throws {
                let keys = try? decoder.container(keyedBy: Key.self)
                self.sessionPairs = keys?.lenient(Double.self, .sessionPairs)
                self.confidentStretches = keys?.lenient(Double.self, .confidentStretches)
            }

            enum Key: String, CodingKey {
                case sessionPairs, confidentStretches
            }
        }

        enum Key: String, CodingKey {
            case sessionIntervals, thresholds
        }
    }

    /// `windows.7d.sessions` read on its own, so the window itself decodes as before.
    private struct WeekWindow: Decodable {
        var sessions: Lenient<Sessions>?
    }

    public struct Coverage: Decodable, Sendable, Equatable {
        public var historySince: String?
        public var calls: Double?
        public var encryptedConversations: Double?
        public var unpricedCalls30d: Double?
        public var unconfirmedPrices: [String]?
        public var notCounted: String?
        public var pricesChecked: String?

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            self.historySince = keys?.lenient(String.self, .historySince)
            self.calls = keys?.lenient(Double.self, .calls)
            self.encryptedConversations = keys?.lenient(Double.self, .encryptedConversations)
            self.unpricedCalls30d = keys?.lenient(Double.self, .unpricedCalls30d)
            self.unconfirmedPrices = keys?.lenient([String].self, .unconfirmedPrices)
            self.notCounted = keys?.lenient(String.self, .notCounted)
            self.pricesChecked = keys?.lenient(String.self, .pricesChecked)
        }

        enum Key: String, CodingKey {
            case historySince, calls, encryptedConversations, unpricedCalls30d, unconfirmedPrices, notCounted
            case pricesChecked
        }
    }

    public struct QuotaSource: Decodable, Sendable, Equatable {
        public var app: String?
        public var lastSampleAt: Double?
        public var ageSec: Double?
        public var cadence: String?
        /// The CodexBar account whose quota readings the block holds (the key CodexBar files that account's
        /// history under, and the `account` of the live lines); nil in older summaries.
        public var accountKey: String?

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            self.app = keys?.lenient(String.self, .app)
            self.lastSampleAt = keys?.lenient(Double.self, .lastSampleAt)
            self.ageSec = keys?.lenient(Double.self, .ageSec)
            self.cadence = keys?.lenient(String.self, .cadence)
            let key = keys?.lenient(String.self, .accountKey) ?? keys?.lenient(String.self, .account)
            self.accountKey = key?.isEmpty == false ? key : nil
        }

        enum Key: String, CodingKey {
            case app, lastSampleAt, ageSec, cadence, accountKey, account
        }
    }

    enum Key: String, CodingKey {
        case uuid, name, short, active, planName, planPriceUsd, has5h, sessionPctOfWeek, kFable
        case windows, rates, drift, lastMeasuredAt, weeks, daily, trackedSince, value
        case usdToday, tokensToday, usd24h, tokens24h, usd7d, tokens7d, usd30d, tokens30d
        case beta, error, models, cache, coverage, quotaSource, valueReason, calibration
    }

    private struct ValuePairs: Decodable {
        var pairs: Double?
    }

    public init(from decoder: Decoder) throws {
        let keys = try? decoder.container(keyedBy: Key.self)
        func number(_ key: Key) -> Double? {
            keys?.lenient(Double.self, key)
        }
        // Window by window and day by day: one odd entry drops only itself.
        let windows = keys?.lenient([String: Lenient<UsagePanelState.Window>].self, .windows)?
            .compactMapValues(\.value)
        let rates = keys?.lenient([String: Lenient<UsagePanelState.Rate>].self, .rates)?
            .compactMapValues(\.value)
        // A missing name or id falls back to the provider the block is filed under ("antigravity", "codex").
        let filedUnder = decoder.codingPath.last?.stringValue ?? UsageProviderSpec.antigravity.key.rawValue
        let name = keys?.lenient(String.self, .name)
            ?? UsageProviderSpec.Key(rawValue: filedUnder).map { UsageProviderSpec.spec(for: $0).name }
            ?? filedUnder.capitalized
        let weekSessions = keys?.lenient([String: Lenient<WeekWindow>].self, .windows)?["7d"]?.value?.sessions?.value
        // The collector's measured count comes first; a share of the week it may also write comes next.
        let measuredShare = weekSessions?.perWeek.flatMap { $0 > 0 ? 100 / $0 : nil }
        self.account = UsagePanelState.Account(
            uuid: keys?.lenient(String.self, .uuid) ?? filedUnder,
            name: name,
            short: keys?.lenient(String.self, .short) ?? name,
            active: keys?.lenient(Bool.self, .active),
            planName: keys?.lenient(String.self, .planName),
            planPriceUsd: number(.planPriceUsd),
            has5h: keys?.lenient(Bool.self, .has5h),
            sessionPctOfWeek: measuredShare ?? number(.sessionPctOfWeek),
            kFable: number(.kFable),
            windows: windows,
            rates: rates,
            drift: keys?.lenient([Lenient<UsagePanelState.DriftPoint>].self, .drift)?.compactMap(\.value),
            lastMeasuredAt: number(.lastMeasuredAt),
            weeks: keys?.lenient([Lenient<UsagePanelState.Week>].self, .weeks)?.compactMap(\.value),
            daily: keys?.lenient([Lenient<UsagePanelState.Day>].self, .daily)?.compactMap(\.value),
            usdToday: number(.usdToday),
            tokensToday: number(.tokensToday),
            usd24h: number(.usd24h),
            tokens24h: number(.tokens24h),
            usd7d: number(.usd7d),
            tokens7d: number(.tokens7d),
            usd30d: number(.usd30d),
            tokens30d: number(.tokens30d),
            trackedSince: number(.trackedSince),
            value: keys?.lenient(UsagePanelState.Value.self, .value))
        self.beta = keys?.lenient(Bool.self, .beta) ?? true
        self.error = keys?.lenient(String.self, .error)
        self.models = keys?.lenient([String: Lenient<ModelStats>].self, .models)?.compactMapValues(\.value) ?? [:]
        self.cache = keys?.lenient(UsageCacheStats.self, .cache) ?? UsageCacheStats(spans: [:])
        self.coverage = keys?.lenient(Coverage.self, .coverage)
        self.quotaSource = keys?.lenient(QuotaSource.self, .quotaSource)
        self.valueReason = keys?.lenient(String.self, .valueReason)
        self.valuePairs = keys?.lenient(ValuePairs.self, .value)?.pairs
        self.worth = keys?.lenient(Worth.self, .value).flatMap { $0.isNewShape ? $0 : nil }
        self.weekSessions = weekSessions
        self.weekRate = keys?.lenient([String: Lenient<RateNote>].self, .rates)?["7d"]?.value
        self.calibration = keys?.lenient(Calibration.self, .calibration)
    }
}

/// Decodes `T` if it can and stays `nil` otherwise, without failing the container around it.
struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        self.value = try? T(from: decoder)
    }
}

extension Lenient: Equatable where T: Equatable {}

extension Lenient: Sendable where T: Sendable {}

extension KeyedDecodingContainer {
    /// The value when present and well-formed, otherwise `nil`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? self.decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: - What the page shows

extension UsageProviderBlock {
    /// Quota windows with a reading, 5-hour first. A rolled window stays: it reads "new window, no reading yet".
    public var limitWindows: [(UsagePanelState.WindowKind, UsagePanelState.Window)] {
        [UsagePanelState.WindowKind.fiveHour, .week].compactMap { kind in
            guard let window = self.account.window(kind), window.pct != nil else { return nil }
            if kind == .fiveHour, self.account.has5h == false {
                return nil
            }
            return (kind, window)
        }
    }

    /// "≈N full 5h sessions left · M fit before reset" for the weekly row. The provider's own rates only:
    /// a Claude plan says nothing about a Google or OpenAI quota.
    public func sessionsLeft(for kind: UsagePanelState.WindowKind, now: Date) -> UsageSessionsLeft? {
        kind == .week ? UsageSessionsLeft.make(account: self.account, donors: [], now: now) : nil
    }

    /// While the collector has not measured the session size yet (`windows.7d.sessions` is null), the weekly
    /// row says how far it is instead of showing nothing: "5h sessions: measuring, 1 of 3 windows seen".
    /// No preliminary number. Nil for the 5-hour row, once a session line can be shown, and without a 5-hour limit.
    public func sessionsMeasuringCaption(for kind: UsagePanelState.WindowKind, now: Date) -> String? {
        guard self.sessionsAreMeasuring(kind, now: now) else { return nil }
        let (seen, needed) = self.sessionProgress
        if let seen, let needed, seen < needed {
            return "5h sessions: measuring, \(seen) of \(needed) windows seen"
        }
        if let seen, seen > 0 {
            return "5h sessions: measuring, \(seen) \(seen == 1 ? "window" : "windows") seen"
        }
        return "5h sessions: measuring"
    }

    /// The same for the weekly detail panel, as one sentence.
    public func sessionsMeasuringSentence(for kind: UsagePanelState.WindowKind, now: Date) -> String? {
        guard self.sessionsAreMeasuring(kind, now: now) else { return nil }
        let (seen, needed) = self.sessionProgress
        guard let needed else {
            return "Full 5-hour sessions left appear here once enough 5-hour windows have been measured."
        }
        let soFar = seen.map { "; \($0) so far" } ?? ""
        return "Full 5-hour sessions left appear here once \(needed) 5-hour windows have been measured\(soFar)."
    }

    private func sessionsAreMeasuring(_ kind: UsagePanelState.WindowKind, now: Date) -> Bool {
        kind == .week && self.weekSessions?.perWeek == nil && self.account.has5h != false
            && self.limitWindows.contains { $0.0 == .fiveHour }
            && self.sessionsLeft(for: .week, now: now) == nil
    }

    private var sessionProgress: (seen: Int?, needed: Int?) {
        func count(_ value: Double?) -> Int? {
            value.flatMap { $0.isFinite && $0 >= 0 ? Int($0.rounded()) : nil }
        }
        let needed = count(self.calibration?.sessionPairsNeeded).flatMap { $0 > 0 ? $0 : nil }
        return (count(self.calibration?.sessionIntervals), needed)
    }

    /// Dollars that fill 100% of a limit at the provider's API prices.
    public func capacity(_ kind: UsagePanelState.WindowKind) -> Double? {
        if kind == .week, let week = self.account.value?.weekOpusUsd, week > 0 {
            return week
        }
        return self.account.rates?[kind.rawValue]?.usdPer100.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The display name of every model id the block names anywhere (daily spend, weeks, the 30-day models,
    /// the value per model). Spend, Value and Prompt cache all read names from here, so one model has one
    /// name on the whole page: the version stays only where two models of the history share a name.
    public func modelLabels(spec: UsageProviderSpec) -> [String: String] {
        var ids = Set(self.models.keys)
        for day in self.account.daily ?? [] {
            ids.formUnion((day.m ?? [:]).keys)
        }
        for week in self.account.weeks ?? [] {
            ids.formUnion((week.m ?? [:]).keys)
        }
        ids.formUnion((self.worth?.byModel ?? []).compactMap(\.model))
        return spec.models.labels(for: ids.sorted())
    }

    /// Whether anything at all was recorded: quota readings or spend.
    public var hasData: Bool {
        !self.limitWindows.isEmpty || (self.account.daily ?? []).contains { $0.total > 0 || ($0.tokens ?? 0) > 0 }
    }
}

// MARK: - Model names

/// How a provider's model ids become the short names its page shows. Colors are not here: a page gives its
/// models the chart colors in order of use (`UsageProviderSpend`).
public enum UsageModelNaming: Sendable, Equatable {
    /// "gemini-4-neon" → "Neon"; when two models share a name the version stays: "Flash 3.7", "Flash 3.6".
    case gemini
    /// "gpt-6.1-sol" → "Sol", "gpt-6.1-sol-mini" → "Sol Mini"; "gpt-5" → "GPT-5"; when two models share a
    /// name the version stays: "Sol 6.1", "Sol 6".
    case openai

    /// Key for spend that the summary does not attribute to a model.
    static let unknown = "unknown"

    /// What spend without a model is called.
    var unknownLabel: String {
        switch self {
        case .gemini: "Gemini"
        case .openai: "Codex"
        }
    }

    public func labels(for ids: [String]) -> [String: String] {
        let parsed = ids.map { ($0, self.parse($0)) }
        var counts: [String: Int] = [:]
        for (_, part) in parsed {
            counts[part.name, default: 0] += 1
        }
        var labels: [String: String] = [:]
        for (id, part) in parsed {
            if id == Self.unknown {
                labels[id] = self.unknownLabel
            } else if counts[part.name, default: 0] > 1, let version = part.version {
                labels[id] = "\(part.name) \(version)"
            } else {
                labels[id] = part.name
            }
        }
        return labels
    }

    /// Ids whose generic reading would be long or misleading.
    private static let aliases: [String: String] = [
        // Codex's own reviewer: "Codex Auto Review" did not fit a model column.
        "codex-auto-review": "Auto Review",
    ]

    private func parse(_ id: String) -> (name: String, version: String?) {
        if let alias = Self.aliases[id.lowercased()] {
            return (alias, nil)
        }
        var parts = id.lowercased().split(separator: "-").map(String.init)
        let family = self == .gemini ? "gemini" : "gpt"
        if parts.first == family {
            parts.removeFirst()
        }
        var version: String?
        if let first = parts.first, first.first?.isNumber == true {
            version = first
            parts.removeFirst()
        }
        func capitalized(_ word: String) -> String {
            word.prefix(1).uppercased() + word.dropFirst()
        }
        switch self {
        case .gemini:
            guard let word = parts.first else { return (version.map { "Gemini \($0)" } ?? id, nil) }
            return (capitalized(word), version)
        case .openai:
            // "latest" and dated snapshots say nothing a reader needs.
            let words = parts.filter { $0 != "latest" && !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
            guard !words.isEmpty else { return (version.map { "GPT-\($0)" } ?? id, nil) }
            return (words.map(capitalized).joined(separator: " "), version)
        }
    }
}

// MARK: - Spend, computed once

/// Everything a provider page's spend section draws, computed once per summary: a period switch or a hover
/// then only reads ready values. Same rules as `UsageSpendDigest` (calendar days counting today), but split by
/// the provider's models instead of by account.
public struct UsageProviderSpend: Sendable, Equatable {
    /// A model row: one named model, or everything after the first few as "Other".
    typealias ModelRow = UsageModelLine

    /// One selectable period (or one zoom): chart, model rows and the total.
    public struct Period: Sendable, Equatable {
        public let period: UsageSpendPeriod
        let chart: UsageDayChartData
        let rows: [ModelRow]
        let whole: UsageModelUse
        /// What "Other" consists of in this period, biggest first ("Astra $4,738", "Auto Review no price");
        /// empty when every model has its own row. The view shows as many as fit on one line.
        let otherMembers: [String]
        /// No model inside "Other" had use in this period: the members are only named.
        let otherIsEmpty: Bool
        /// Set for a zoom: the span shown (`period` is then the smallest preset period covering it).
        var range: UsageSpendRange?

        /// The note under the rows with the first `count` members named and the rest counted:
        /// "Other: Astra $4,738, Sol 5.6 $1,942 and 4 more." Nil without an "Other" row.
        func otherNote(naming count: Int) -> String? {
            guard !self.otherMembers.isEmpty else { return nil }
            if self.otherIsEmpty, self.range != nil {
                return "Other: none on these days."
            }
            let named = self.otherMembers.prefix(max(0, count))
            let rest = self.otherMembers.count - named.count
            var text = "Other: " + named.joined(separator: ", ")
            if rest > 0 {
                text += named.isEmpty ? "\(rest) models" : " and \(rest) more"
            }
            let none = self.range == nil ? " (none in this period)." : " (none on these days)."
            return text + (self.otherIsEmpty ? none : ".")
        }
    }

    /// One day of the history: use by model id, and the tokens of models the collector had no price for.
    struct DayUses: Sendable, Equatable {
        let key: String
        let date: Date?
        let uses: [String: UsageModelUse]
        let unpriced: [String: Double]

        var total: UsageModelUse {
            self.uses.values.reduce(UsageModelUse(), +)
        }
    }

    /// Which models get a named row (and a distinct color) for one split, and which share "Other".
    struct RowPlan {
        let named: [String]
        let rest: [String]
        let colors: [String: UsageSeriesColor]
    }

    public let today: UsageModelUse
    public let week: UsageModelUse
    /// The periods worth a button: up to the first one that covers the whole local history.
    /// One period means the history is short and the page shows no switch.
    public let offered: [UsageSpendPeriod]
    /// Some day of the history has spend or tokens.
    public let hasSpend: Bool
    /// Display name of every model id the block names, by `UsageProviderBlock.modelLabels(spec:)`.
    public let labels: [String: String]
    private let periods: [Period]
    private let perDay: [DayUses]
    private let dayIndex: [String: Int]
    private let dayTotals: [UsageDayTotal]
    /// Every model of the history, most spend first.
    private let order: [String]
    private let hasOther: Bool
    /// Models without a price in the 30-day model list.
    private let unpricedModels: Set<String>
    private let providerName: String

    /// Named model rows; with more models than this plus one, the rest share an "Other" row.
    static let namedRows = 3

    public init(block: UsageProviderBlock, spec: UsageProviderSpec, now: Date) {
        let days = (block.account.daily ?? []).sorted { $0.day < $1.day }
        func uses(_ day: UsagePanelState.Day) -> [String: UsageModelUse] {
            guard let models = day.m, !models.isEmpty else {
                return [UsageModelNaming.unknown: UsageModelUse(usd: day.total, tokens: day.tokens ?? 0)]
            }
            var result: [String: UsageModelUse] = [:]
            for (id, value) in models {
                result[id, default: UsageModelUse()] = result[id, default: UsageModelUse()]
                    + UsageModelUse(usd: value.first ?? 0, tokens: value.count > 1 ? value[1] : 0)
            }
            return result
        }
        let perDay = days.map {
            DayUses(key: $0.day, date: UsageDayKey.date($0.day), uses: uses($0), unpriced: $0.unpriced ?? [:])
        }
        func sum(lastDays count: Int) -> [String: UsageModelUse] {
            let from = UsageDayKey.start(days: count, now: now)
            return Self.sum(perDay) { $0 >= from }
        }
        func whole(_ split: [String: UsageModelUse]) -> UsageModelUse {
            split.values.reduce(UsageModelUse(), +)
        }
        self.today = whole(sum(lastDays: 1))
        self.week = whole(sum(lastDays: 7))
        self.hasSpend = perDay.contains { $0.uses.values.contains { $0.usd > 0 || $0.tokens > 0 } }

        // Every model of the history, most spend first; a period's own leaders are picked from these.
        let splits = Dictionary(uniqueKeysWithValues: UsageSpendPeriod.allCases.map { ($0, sum(lastDays: $0.days)) })
        let longest = splits[.d180] ?? [:]
        let order = Self.ranked(Array(longest.keys), by: longest)
        let labels = block.modelLabels(spec: spec).merging(spec.models.labels(for: order)) { known, _ in known }
        self.labels = labels
        // The same number of rows in every period (so a switch never changes the menu's height): three named
        // models and "Other" when the history has more than four, otherwise one row per model.
        let hasOther = order.count > Self.namedRows + 1
        let unpriced = Set(block.models.compactMap { $0.value.priced == false ? $0.key : nil })

        // The history starts at the first call on record (or the first day with spend).
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let firstDay = [
            block.account.trackedSince.map { calendar.startOfDay(for: Date(timeIntervalSince1970: $0)) },
            perDay.first { $0.uses.values.contains { $0.usd > 0 || $0.tokens > 0 } }.flatMap { UsageDayKey.date($0.key) },
        ].compactMap(\.self).min()
        var offered: [UsageSpendPeriod] = []
        for period in UsageSpendPeriod.allCases {
            offered.append(period)
            let start = calendar.date(byAdding: .day, value: -(period.days - 1), to: today) ?? today
            if firstDay.map({ $0 >= start }) ?? true {
                break
            }
        }
        self.offered = offered
        self.perDay = perDay
        self.dayIndex = Dictionary(perDay.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { _, last in last })
        self.dayTotals = perDay.compactMap { day in day.date.map { UsageDayTotal(key: day.key, date: $0, use: day.total) } }
        self.order = order
        self.hasOther = hasOther
        self.unpricedModels = unpriced
        self.providerName = spec.name

        self.periods = UsageSpendPeriod.allCases.map { period in
            let domain = Self.domain(period: period, firstDay: firstDay, now: now)
            let from = UsageDayKey.string(domain.lowerBound)
            let periodFrom = UsageDayKey.start(days: period.days, now: now)
            return Self.makePeriod(
                period: period,
                range: nil,
                split: splits[period] ?? [:],
                domain: domain,
                includes: { $0 >= from },
                unpricedIncludes: { $0 >= periodFrom },
                hint: Self.hint(period: period, firstDay: firstDay, now: now),
                perDay: perDay,
                order: order,
                labels: labels,
                hasOther: hasOther,
                unpriced: unpriced,
                name: spec.name)
        }
    }

    /// One period's (or one zoom's) chart, rows and Other note.
    private static func makePeriod(
        period: UsageSpendPeriod,
        range: UsageSpendRange?,
        split: [String: UsageModelUse],
        domain: ClosedRange<Date>,
        includes: (String) -> Bool,
        unpricedIncludes: (String) -> Bool,
        hint: String,
        perDay: [DayUses],
        order: [String],
        labels: [String: String],
        hasOther: Bool,
        unpriced: Set<String>,
        name: String) -> Period
    {
        // This period's leaders get the named rows and the distinct colors, by rank; models without use in
        // the period fill the rows that are left, in the order of the whole history.
        let plan = Self.rowPlan(split: split, order: order, hasOther: hasOther)
        let named = plan.named
        let rest = plan.rest
        let colors = plan.colors
        let legend = named.map { UsageDayChartData.Legend(id: $0, name: labels[$0] ?? $0, color: colors[$0] ?? .other) }
            + (rest.isEmpty ? [] : [UsageDayChartData.Legend(id: "other", name: "Other", color: .other)])
        var bars: [UsageDayChartData.Bar] = []
        var notes: [String: String] = [:]
        for day in perDay where includes(day.key) {
            guard let date = day.date else { continue }
            for id in named {
                if let use = day.uses[id], use.usd > 0 {
                    bars.append(.init(key: day.key, date: date, series: labels[id] ?? id, color: colors[id] ?? .other,
                                      usd: use.usd))
                }
            }
            let others = rest.reduce(0) { $0 + (day.uses[$1]?.usd ?? 0) }
            if others > 0 {
                bars.append(.init(key: day.key, date: date, series: "Other", color: .other, usd: others))
            }
            let tokens = day.uses.values.reduce(0) { $0 + $1.tokens }
            if tokens > 0 {
                notes[day.key] = "\(UsageFormat.tokens(tokens)) tokens"
            }
        }
        // No price: the 30-day model list, plus the days of this period that name such a model (the
        // collector's daily "unpriced"), so an older or unpriced model is never shown as "$0".
        let unpricedHere = perDay.filter { unpricedIncludes($0.key) }
            .reduce(into: unpriced) { set, day in set.formUnion(day.unpriced.keys) }
        var rows = named.map { id in
            ModelRow(
                id: id,
                label: labels[id] ?? id,
                color: colors[id] ?? .other,
                use: split[id] ?? UsageModelUse(),
                unpriced: unpricedHere.contains(id))
        }
        var members: [String] = []
        var otherIsEmpty = false
        if !rest.isEmpty {
            let uses = rest.map { ($0, split[$0] ?? UsageModelUse()) }
            rows.append(ModelRow(id: "other", label: "Other", color: .other, use: uses.reduce(UsageModelUse()) { $0 + $1.1 }))
            let shown = uses.filter { $0.1.tokens > 0 || $0.1.usd > 0 }
            if shown.isEmpty {
                otherIsEmpty = true
                members = rest.map { labels[$0] ?? $0 }.sorted()
            } else {
                members = shown.map { id, use in
                    "\(labels[id] ?? id) \(Self.cost(use.usd, unpriced: unpricedHere.contains(id)))"
                }
            }
        }
        let chart = UsageDayChartData(
            period: period,
            domain: domain,
            bars: bars,
            hint: hint,
            legend: legend,
            dayNotes: notes,
            emptyText: range == nil
                ? "No \(name) use on this Mac in this period."
                : "No \(name) use on this Mac on these days.",
            chipLimit: 3,
            centsInChips: true,
            customRange: range)
        let whole = split.values.reduce(UsageModelUse(), +)
        return Period(
            period: period, chart: chart, rows: rows, whole: whole, otherMembers: members,
            otherIsEmpty: otherIsEmpty, range: range)
    }

    /// The split's leaders by rank, then the models without use in it in history order; past `namedRows`
    /// (with more than one model left) the rest share "Other".
    static func rowPlan(split: [String: UsageModelUse], order: [String], hasOther: Bool) -> RowPlan {
        let used = Self.ranked(order.filter { (split[$0]?.usd ?? 0) > 0 || (split[$0]?.tokens ?? 0) > 0 }, by: split)
        let ranked = used + order.filter { !used.contains($0) }
        let named = hasOther ? Array(ranked.prefix(Self.namedRows)) : ranked
        let rest = ranked.filter { !named.contains($0) }
        var colors: [String: UsageSeriesColor] = [:]
        for (index, id) in named.enumerated() {
            colors[id] = .model(index)
        }
        return RowPlan(named: named, rest: rest, colors: colors)
    }

    private static func sum(_ perDay: [DayUses], where includes: (String) -> Bool) -> [String: UsageModelUse] {
        var total: [String: UsageModelUse] = [:]
        for day in perDay where includes(day.key) {
            for (id, use) in day.uses {
                total[id, default: UsageModelUse()] = total[id, default: UsageModelUse()] + use
            }
        }
        return total
    }

    /// Most dollars first, then most tokens, then by id: the same order on every build.
    private static func ranked(_ ids: [String], by split: [String: UsageModelUse]) -> [String] {
        ids.sorted { lhs, rhs in
            let a = split[lhs] ?? UsageModelUse()
            let b = split[rhs] ?? UsageModelUse()
            if a.usd != b.usd { return a.usd > b.usd }
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            return lhs < rhs
        }
    }

    /// A member's dollars in the Other note: "no price" only for a model the collector has no price for;
    /// a priced model under half a cent is "<$0.01".
    static func cost(_ usd: Double, unpriced: Bool) -> String {
        if unpriced, usd < 0.005 {
            return "no price"
        }
        return usd < 0.005 ? "<$0.01" : UsageFormat.usdFine(usd)
    }

    public subscript(period: UsageSpendPeriod) -> Period {
        self.periods.first { $0.period == period } ?? self.periods[0]
    }

    /// The period to show for the menu-wide choice: the chosen one if it is offered, otherwise the longest
    /// offered one (a longer period would show the same days).
    public func effective(_ chosen: UsageSpendPeriod) -> UsageSpendPeriod {
        UsageSpendPeriod.effective(chosen, offered: self.offered)
    }

    /// Row slots of the model rows: the same in every period and zoom.
    var rowCount: Int {
        self.hasOther ? Self.namedRows + 1 : self.order.count
    }

    // MARK: Zoom

    /// The layer of a zoom: the same chart and rows as a period, over the span's days only.
    public func period(range: UsageSpendRange) -> Period {
        Self.makePeriod(
            period: range.coveringPeriod,
            range: range,
            split: Self.sum(self.perDay) { range.contains($0) },
            domain: range.domain,
            includes: { range.contains($0) },
            unpricedIncludes: { range.contains($0) },
            hint: UsageSpendDigest.zoomHint,
            perDay: self.perDay,
            order: self.order,
            labels: self.labels,
            hasOther: self.hasOther,
            unpriced: self.unpricedModels,
            name: self.providerName)
    }

    /// The zoomed header's tiles: the span's total, daily average and busiest day.
    public func customSummary(for range: UsageSpendRange) -> UsageCustomRangeSummary {
        UsageDayStats.summary(range: range, days: self.dayTotals)
    }

    // MARK: Day panel

    /// The day panel of a provider page's chart: the day by model (no section by account: one account).
    /// `chartID` defaults to the page's (`spec.idPrefix + "spend"`).
    public func dayDetailCatalog(chartID: String? = nil, spec: UsageProviderSpec, now: Date) -> UsageDayDetailCatalog {
        let spend = self
        let todayKey = UsageDayKey.string(now)
        return UsageDayDetailCatalog(
            chartID: chartID ?? spec.spendChartID,
            defaultDayKey: todayKey,
            fixedSection1Rows: 0,
            fixedSection2Rows: self.rowCount,
            section1NameWidth: 66,
            // `UsageProviderPeriodLayer.nameWidth`: provider model names are longer than Claude's.
            section2NameWidth: 66,
            reservesNoteLine: true,
            dayDetail: { key, period, range in
                spend.dayDetail(key, period: spend.effective(period), range: range, todayKey: todayKey)
            },
            rangePreview: { range in
                spend.rangePreview(range)
            })
    }

    func dayDetail(_ key: String, period: UsageSpendPeriod, range: UsageSpendRange?, todayKey: String) -> UsageDayDetail {
        let domain = range?.domain ?? self[period].chart.domain
        let context = UsageDayStats.context(dayKey: key, domain: domain, days: self.dayTotals)
        // The rows of the shown period or zoom, so the colors match the chart.
        let plan: RowPlan = if let range {
            Self.rowPlan(split: Self.sum(self.perDay) { range.contains($0) }, order: self.order, hasOther: self.hasOther)
        } else {
            self.plan(of: self[period])
        }
        let day = self.dayIndex[key].map { self.perDay[$0] }
        let uses = day?.uses ?? [:]
        let total = day?.total ?? UsageModelUse()
        let dayUnpriced = self.unpricedModels.union((day?.unpriced ?? [:]).keys)
        return UsageDayDetail(
            dayKey: key,
            date: day?.date ?? UsageDayKey.date(key) ?? domain.lowerBound,
            isToday: key == todayKey,
            totalUsd: total.usd,
            totalTokens: total.tokens,
            periodDays: context.count,
            periodLabel: UsageDayStats.label(days: context.count, isCustom: range != nil),
            isCustomRange: range != nil,
            periodDailyAverageUsd: context.average,
            rankInPeriod: context.rank,
            section1Title: nil,
            section1Rows: [],
            section2Title: "By model",
            section2Rows: self.rows(plan, uses: uses, unpriced: dayUnpriced),
            otherNote: self.otherNote(plan, uses: uses),
            unpricedNote: self.unpricedNote(day?.unpriced ?? [:]))
    }

    func rangePreview(_ range: UsageSpendRange) -> UsageRangeDetailPreview {
        let split = Self.sum(self.perDay) { range.contains($0) }
        let plan = Self.rowPlan(split: split, order: self.order, hasOther: self.hasOther)
        let summary = UsageDayStats.summary(range: range, days: self.dayTotals)
        let rangeUnpriced = self.perDay.filter { range.contains($0.key) }
            .reduce(into: self.unpricedModels) { set, day in set.formUnion(day.unpriced.keys) }
        return UsageRangeDetailPreview(
            range: range,
            totalUsd: summary.total.usd,
            totalTokens: summary.total.tokens,
            dailyAverageUsd: summary.dailyAverage.usd,
            busiestDay: summary.busiestDay,
            section1Title: nil,
            section1Rows: [],
            section2Title: "By model",
            section2Rows: self.rows(plan, uses: split, unpriced: rangeUnpriced))
    }

    /// The named models, colors and "Other" of a ready period, as its rows show them.
    private func plan(of period: Period) -> RowPlan {
        let named = period.rows.filter { $0.id != "other" || !self.hasOther }.map(\.id)
        var colors: [String: UsageSeriesColor] = [:]
        for row in period.rows where named.contains(row.id) {
            colors[row.id] = row.color
        }
        return RowPlan(named: named, rest: self.order.filter { !named.contains($0) }, colors: colors)
    }

    private func rows(_ plan: RowPlan, uses: [String: UsageModelUse], unpriced: Set<String>) -> [UsageDayDetail.Row] {
        // Put models with activity on this day above inactive "$0" rows while keeping their chart colors.
        let active = Self.ranked(plan.named.filter { (uses[$0]?.usd ?? 0) > 0 || (uses[$0]?.tokens ?? 0) > 0 }, by: uses)
        let ordered = active + plan.named.filter { !active.contains($0) }
        var rows = ordered.map { id in
            let use = uses[id] ?? UsageModelUse()
            return UsageDayDetail.Row(
                id: id,
                label: self.labels[id] ?? id,
                color: plan.colors[id] ?? .other,
                usd: use.usd,
                tokens: use.tokens,
                unpriced: unpriced.contains(id))
        }
        if !plan.rest.isEmpty {
            let other = plan.rest.reduce(UsageModelUse()) { $0 + (uses[$1] ?? UsageModelUse()) }
            rows.append(UsageDayDetail.Row(id: "other", label: "Other", color: .other, usd: other.usd, tokens: other.tokens))
        }
        return rows
    }

    /// "Other: Astra $4.70, Sol 5.6 $1.20 and 2 more." for the models inside "Other" with use that day.
    private func otherNote(_ plan: RowPlan, uses: [String: UsageModelUse]) -> String? {
        let used = Self.ranked(plan.rest.filter { (uses[$0]?.usd ?? 0) > 0 || (uses[$0]?.tokens ?? 0) > 0 }, by: uses)
        guard !used.isEmpty else { return nil }
        let named = used.prefix(2).map { id in
            "\(self.labels[id] ?? id) \(Self.cost(uses[id]?.usd ?? 0, unpriced: self.unpricedModels.contains(id)))"
        }
        let rest = used.count - named.count
        return "Other: " + named.joined(separator: ", ") + (rest > 0 ? " and \(rest) more." : ".")
    }

    /// "No price: Auto Review (12K tokens)." for the models the collector had no price for that day.
    private func unpricedNote(_ unpriced: [String: Double]) -> String? {
        let ids = unpriced.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map(\.key)
        guard !ids.isEmpty else { return nil }
        let named = ids.prefix(2).map { "\(self.labels[$0] ?? $0) (\(UsageFormat.tokens(unpriced[$0] ?? 0)) tokens)" }
        let rest = ids.count - named.count
        return "No price: " + named.joined(separator: ", ") + (rest > 0 ? " and \(rest) more." : ".")
    }

    /// From the first day on record, but at least a week wide, so a few days of history still get
    /// readable bars; never longer than the period.
    private static func domain(period: UsageSpendPeriod, firstDay: Date?, now: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var start = calendar.date(byAdding: .day, value: -(period.days - 1), to: today) ?? today
        let shortest = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        if let firstDay, firstDay > start {
            start = min(firstDay, shortest)
        }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return start...end
    }

    private static func hint(period: UsageSpendPeriod, firstDay: Date?, now: Date) -> String {
        let calendar = Calendar.current
        let asked = calendar.date(byAdding: .day, value: -(period.days - 1), to: calendar.startOfDay(for: now))
        if let asked, let firstDay, firstDay > asked {
            return "Since \(UsageFormat.format(firstDay, "MMM d")) · point at a bar or drag to zoom."
        }
        return "Per day. Point at a bar, drag across days to zoom in."
    }
}

extension UsageProviderSpec {
    /// The id of the page's per-day chart; its day panel is registered under `spendChartID + ":day"`.
    public var spendChartID: String {
        self.idPrefix + "spend"
    }
}

extension UsageSpendPeriod {
    /// The chosen period if offered, else the longest offered one.
    public static func effective(_ chosen: UsageSpendPeriod, offered: [UsageSpendPeriod]) -> UsageSpendPeriod {
        if offered.contains(chosen) {
            return chosen
        }
        return offered.last ?? chosen
    }
}
