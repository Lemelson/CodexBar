import Foundation

// MARK: - The `antigravity` block of the summary

/// Gemini use through Antigravity: one account-like object next to the Claude accounts in `state.json`.
/// Contract: `usage/ANTIGRAVITY-STATE.md`.
///
/// The keys it shares with a Claude account (`windows`, `rates`, `daily`, `weeks`, `value`, ...) end up in
/// `account`, so the Claude views for limits and spend take it as is. Decoding never throws and goes key by
/// key: a missing or malformed key leaves out only its own part of the page, never the whole summary.
public struct UsageAntigravityBlock: Decodable, Sendable, Equatable {
    public var account: UsagePanelState.Account
    /// Always true for now: the token reading is reverse-engineered and the dollars are an estimate.
    public var beta: Bool
    /// Set when the collector's Antigravity step failed; the block then has no data keys.
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
    /// The value in the shape of `STATE-ADDITIONS-24.md` (plan, month, ×, per model); nil in older summaries.
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

    /// `antigravity.value`: what the plan buys at Gemini API prices.
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

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            self.sessionIntervals = keys?.lenient(Double.self, .sessionIntervals)
            self.sessionPairsNeeded = keys?.lenient(Thresholds.self, .thresholds)?.sessionPairs
        }

        private struct Thresholds: Decodable {
            var sessionPairs: Double?

            init(from decoder: Decoder) throws {
                let keys = try? decoder.container(keyedBy: Key.self)
                self.sessionPairs = keys?.lenient(Double.self, .sessionPairs)
            }

            enum Key: String, CodingKey {
                case sessionPairs
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

        public init(from decoder: Decoder) throws {
            let keys = try? decoder.container(keyedBy: Key.self)
            self.app = keys?.lenient(String.self, .app)
            self.lastSampleAt = keys?.lenient(Double.self, .lastSampleAt)
            self.ageSec = keys?.lenient(Double.self, .ageSec)
            self.cadence = keys?.lenient(String.self, .cadence)
        }

        enum Key: String, CodingKey {
            case app, lastSampleAt, ageSec, cadence
        }
    }

    enum Key: String, CodingKey {
        case uuid, name, short, active, planName, planPriceUsd, has5h, sessionPctOfWeek, kFable
        case windows, rates, drift, lastMeasuredAt, weeks, daily, trackedSince, value
        case usdToday, tokensToday, usd7d, tokens7d, usd30d, tokens30d
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
        let name = keys?.lenient(String.self, .name) ?? "Antigravity"
        let weekSessions = keys?.lenient([String: Lenient<WeekWindow>].self, .windows)?["7d"]?.value?.sessions?.value
        // The collector's measured count comes first; a share of the week it may also write comes next.
        let measuredShare = weekSessions?.perWeek.flatMap { $0 > 0 ? 100 / $0 : nil }
        self.account = UsagePanelState.Account(
            uuid: keys?.lenient(String.self, .uuid) ?? "antigravity",
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

extension UsageAntigravityBlock {
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

    /// "≈N full 5h sessions left · M fit before reset" for the weekly row. Antigravity's own rates only:
    /// a Claude plan says nothing about a Google quota.
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

    /// Short title of a limit row: "5-hour", "Weekly".
    public static func rowTitle(_ kind: UsagePanelState.WindowKind) -> String {
        kind == .fiveHour ? "5-hour" : kind.title
    }

    /// Title of a limit's detail panel: "5-hour limit", "Weekly limit".
    public static func detailTitle(_ kind: UsagePanelState.WindowKind) -> String {
        kind == .fiveHour ? "5-hour limit" : kind.longTitle
    }

    /// Dollars that fill 100% of a limit at Gemini API prices.
    public func capacity(_ kind: UsagePanelState.WindowKind) -> Double? {
        if kind == .week, let week = self.account.value?.weekOpusUsd, week > 0 {
            return week
        }
        return self.account.rates?[kind.rawValue]?.usdPer100.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Whether anything at all was recorded: quota readings or spend.
    public var hasData: Bool {
        !self.limitWindows.isEmpty || (self.account.daily ?? []).contains { $0.total > 0 || ($0.tokens ?? 0) > 0 }
    }
}

// MARK: - Model names and colors

/// Gemini model ids as short labels and stable chart colors.
public enum UsageAntigravityModels {
    /// Key for spend that the summary does not attribute to a model.
    static let unknown = "unknown"

    /// "gemini-4-neon" → "Neon"; when two models share a name the version stays: "Flash 3.7", "Flash 3.6".
    public static func labels(for ids: [String]) -> [String: String] {
        let parsed = ids.map { ($0, self.parse($0)) }
        var counts: [String: Int] = [:]
        for (_, part) in parsed {
            counts[part.name, default: 0] += 1
        }
        var labels: [String: String] = [:]
        for (id, part) in parsed {
            if id == self.unknown {
                labels[id] = "Gemini"
            } else if counts[part.name, default: 0] > 1, let version = part.version {
                labels[id] = "\(part.name) \(version)"
            } else {
                labels[id] = part.name
            }
        }
        return labels
    }

    private static func parse(_ id: String) -> (name: String, version: String?) {
        var parts = id.lowercased().split(separator: "-").map(String.init)
        if parts.first == "gemini" {
            parts.removeFirst()
        }
        var version: String?
        if let first = parts.first, first.first?.isNumber == true {
            version = first
            parts.removeFirst()
        }
        guard let word = parts.first else { return (version.map { "Gemini \($0)" } ?? id, nil) }
        return (word.prefix(1).uppercased() + word.dropFirst(), version)
    }
}

// MARK: - Spend, computed once

/// Everything the Antigravity spend block draws, computed once per summary: a period switch or a hover then
/// only reads ready values. Same rules as `UsageSpendDigest` (calendar days counting today), but split by
/// Gemini model instead of by account.
public struct UsageAntigravitySpend: Sendable, Equatable {
    /// A model row: one named model, or everything after the first few as "Other".
    public struct ModelRow: Identifiable, Sendable, Equatable {
        public let id: String
        let label: String
        let color: UsageSeriesColor
        let use: UsageModelUse
    }

    /// One selectable period: chart, model rows and the total.
    public struct Period: Sendable, Equatable {
        public let period: UsageSpendPeriod
        let chart: UsageDayChartData
        let rows: [ModelRow]
        let whole: UsageModelUse
        /// What "Other" consists of in this period, or nil when every model has its own row.
        let otherNote: String?
    }

    public let today: UsageModelUse
    public let week: UsageModelUse
    /// The periods worth a button: up to the first one that covers the whole local history.
    /// One period means the history is short and the page shows no switch.
    public let offered: [UsageSpendPeriod]
    /// Some day of the history has spend or tokens.
    public let hasSpend: Bool
    private let periods: [Period]

    /// Named model rows; with more models than this plus one, the rest share an "Other" row.
    static let namedRows = 3

    public init(block: UsageAntigravityBlock, now: Date) {
        let days = (block.account.daily ?? []).sorted { $0.day < $1.day }
        func uses(_ day: UsagePanelState.Day) -> [String: UsageModelUse] {
            guard let models = day.m, !models.isEmpty else {
                return [UsageAntigravityModels.unknown: UsageModelUse(usd: day.total, tokens: day.tokens ?? 0)]
            }
            var result: [String: UsageModelUse] = [:]
            for (id, value) in models {
                result[id, default: UsageModelUse()] = result[id, default: UsageModelUse()]
                    + UsageModelUse(usd: value.first ?? 0, tokens: value.count > 1 ? value[1] : 0)
            }
            return result
        }
        let perDay = days.map { (key: $0.day, uses: uses($0)) }
        func sum(lastDays count: Int) -> [String: UsageModelUse] {
            let from = UsageDayKey.start(days: count, now: now)
            var total: [String: UsageModelUse] = [:]
            for day in perDay where day.key >= from {
                for (id, use) in day.uses {
                    total[id, default: UsageModelUse()] = total[id, default: UsageModelUse()] + use
                }
            }
            return total
        }
        func whole(_ split: [String: UsageModelUse]) -> UsageModelUse {
            split.values.reduce(UsageModelUse(), +)
        }
        self.today = whole(sum(lastDays: 1))
        self.week = whole(sum(lastDays: 7))
        self.hasSpend = perDay.contains { $0.uses.values.contains { $0.usd > 0 || $0.tokens > 0 } }

        // Colors follow the shortest period first, so the models of the default view get the distinct ones,
        // and stay the same in every period.
        let splits = Dictionary(uniqueKeysWithValues: UsageSpendPeriod.allCases.map { ($0, sum(lastDays: $0.days)) })
        let longest = splits[.d180] ?? [:]
        let first = splits[.d30] ?? [:]
        let order = longest.keys.sorted { lhs, rhs in
            let a = first[lhs]?.usd ?? 0
            let b = first[rhs]?.usd ?? 0
            if a != b { return a > b }
            let c = longest[lhs]?.usd ?? 0
            let d = longest[rhs]?.usd ?? 0
            if c != d { return c > d }
            return lhs < rhs
        }
        let labels = UsageAntigravityModels.labels(for: order)
        let named = order.count > Self.namedRows + 1 ? Array(order.prefix(Self.namedRows)) : order
        let rest = Set(order).subtracting(named)
        var colors: [String: UsageSeriesColor] = [:]
        for (index, id) in named.enumerated() {
            colors[id] = .model(index)
        }

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

        let legend = named.map { UsageDayChartData.Legend(id: $0, name: labels[$0] ?? $0, color: colors[$0] ?? .other) }
            + (rest.isEmpty ? [] : [UsageDayChartData.Legend(id: "other", name: "Other", color: .other)])
        self.periods = UsageSpendPeriod.allCases.map { period in
            let split = splits[period] ?? [:]
            let domain = Self.domain(period: period, firstDay: firstDay, now: now)
            let from = UsageDayKey.string(domain.lowerBound)
            var bars: [UsageDayChartData.Bar] = []
            var notes: [String: String] = [:]
            for day in perDay where day.key >= from {
                guard let date = UsageDayKey.date(day.key) else { continue }
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
            var rows = named.map { id in
                ModelRow(id: id, label: labels[id] ?? id, color: colors[id] ?? .other, use: split[id] ?? UsageModelUse())
            }
            var otherNote: String?
            if !rest.isEmpty {
                let members = rest.map { ($0, split[$0] ?? UsageModelUse()) }
                rows.append(ModelRow(
                    id: "other",
                    label: "Other",
                    color: .other,
                    use: members.reduce(UsageModelUse()) { $0 + $1.1 }))
                let shown = members.filter { $0.1.tokens > 0 || $0.1.usd >= 0.005 }.sorted { $0.1.usd > $1.1.usd }
                otherNote = shown.isEmpty
                    ? "Other: \(rest.compactMap { labels[$0] }.sorted().joined(separator: ", ")) (none in this period)."
                    : "Other: " + shown.map {
                        "\(labels[$0.0] ?? $0.0) \(UsageFormat.usdFine($0.1.usd)) · \(UsageFormat.tokens($0.1.tokens)) tok"
                    }.joined(separator: "   ")
            }
            let chart = UsageDayChartData(
                period: period,
                domain: domain,
                bars: bars,
                hint: Self.hint(period: period, firstDay: firstDay, now: now),
                legend: legend,
                dayNotes: notes,
                emptyText: "No Antigravity use on this Mac in this period.",
                chipLimit: 3,
                centsInChips: true)
            return Period(period: period, chart: chart, rows: rows, whole: whole(split), otherNote: otherNote)
        }
    }

    public subscript(period: UsageSpendPeriod) -> Period {
        self.periods.first { $0.period == period } ?? self.periods[0]
    }

    /// The period to show for the menu-wide choice: the chosen one if it is offered, otherwise the longest
    /// offered one (a longer period would show the same days).
    public func effective(_ chosen: UsageSpendPeriod) -> UsageSpendPeriod {
        UsageSpendPeriod.effective(chosen, offered: self.offered)
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
            return "Per day since \(UsageFormat.format(firstDay, "MMM d")), the first day on record."
        }
        return "Per day. Point at a bar for that day."
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
