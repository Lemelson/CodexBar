import Foundation
import SwiftUI

// MARK: - The three subscriptions of Overview

/// The providers Overview adds up: all Claude accounts together, Codex and Antigravity.
public enum UsageOverviewProviderKind: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, antigravity

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    /// 0 Claude (orange), 1 Codex (blue), 2 Antigravity (lime): `UsageSeriesColor.provider`.
    public var colorIndex: Int {
        switch self {
        case .claude: 0
        case .codex: 1
        case .antigravity: 2
        }
    }

    public var seriesColor: UsageSeriesColor {
        .provider(self.colorIndex)
    }

    public var color: Color {
        self.seriesColor.color
    }

    /// The provider page's spec; nil for Claude (several accounts, pages of its own).
    public var spec: UsageProviderSpec? {
        switch self {
        case .claude: nil
        case .codex: .codex
        case .antigravity: .antigravity
        }
    }
}

/// What the bars of Overview's per-day chart are split by.
public enum UsageOverviewBreakdown: String, CaseIterable, Identifiable, Sendable {
    case providers, models

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .providers: "Providers"
        case .models: "Models"
        }
    }
}

/// Overview's own chart split, kept across menu opens and restarts. The period and a zoom are the menu-wide
/// ones (`UsagePanelSelection`).
@MainActor
public final class UsageOverviewSelection: ObservableObject {
    public static let shared = UsageOverviewSelection()
    public static let breakdownKey = "lemelsonOverviewBreakdown"
    public static let recentSpanKey = "lemelsonOverviewRecentSpan"
    public static let recentUnitKey = "lemelsonOverviewRecentUnit"

    @Published public var breakdown: UsageOverviewBreakdown {
        didSet {
            UserDefaults.standard.set(self.breakdown.rawValue, forKey: Self.breakdownKey)
        }
    }

    /// Limits mode: how far back the cumulative chart goes.
    @Published public var recentSpan: UsageOverviewRecentSpan {
        didSet {
            UserDefaults.standard.set(self.recentSpan.rawValue, forKey: Self.recentSpanKey)
        }
    }

    /// Limits mode: API dollars or weekly quotas.
    @Published public var recentUnit: UsageOverviewRecentUnit {
        didSet {
            UserDefaults.standard.set(self.recentUnit.rawValue, forKey: Self.recentUnitKey)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.breakdown = defaults.string(forKey: Self.breakdownKey)
            .flatMap(UsageOverviewBreakdown.init(rawValue:)) ?? .providers
        self.recentSpan = defaults.string(forKey: Self.recentSpanKey)
            .flatMap(UsageOverviewRecentSpan.init(rawValue:)) ?? .h24
        // Dollars first: the 24-hour "You" then reads the same as the menu bar.
        self.recentUnit = defaults.string(forKey: Self.recentUnitKey)
            .flatMap(UsageOverviewRecentUnit.init(rawValue:)) ?? .usd
    }
}

// MARK: - Spend of every subscription, computed once

/// Everything Overview draws, computed once per summary: the totals, the per-day chart by provider and by
/// model for every period, the three provider rows and their panels, and the day panel. Same rules as
/// `UsageSpendDigest` and `UsageProviderSpend` (calendar days counting today), over all Claude accounts,
/// Codex and Antigravity together. A provider whose block is missing or failed (`error`) adds nothing to the
/// chart and its row says so in one quiet line.
///
/// Models of the three providers share one list ("Opus", "Fable", "Sol", "Neon"...): every period shows its
/// three leaders and "Other" (when there are more than four models), so a period switch or a zoom never
/// changes the number of rows. Opus is always orange and Fable violet; the other leaders take the free colors
/// in rank order, none of them twice.
public struct UsageOverviewSpend: Sendable, Equatable {
    /// The chart id of Overview's per-day chart; its day panel is `UsageDayDetailCatalog.panelKey(for:)`.
    public static let defaultChartID = "lemelsonOverview-spend"

    /// Named model rows in the menu; with more models than this plus one, the rest share "Other".
    static let namedRows = 3
    /// Named model rows of the day panel (one more than the menu: a day's own fourth model).
    static let dayNamedRows = 4
    /// Colors for the leading models other than Opus and Fable, in rank order. Placed so non-Claude leaders
    /// take blue, teal, yellow and pink before lime (keeping Codex models visually distinct from Antigravity's
    /// lime green when both appear in the same day detail card), and staying apart on a warm screen.
    static let freeColors: [UsageSeriesColor] = [.model(0), .claude(.sonnet), .claude(.haiku), .model(3), .model(1)]

    // MARK: Types

    /// One day of one provider: use by Overview model key ("claude:opus", "codex:gpt-6.1-sol").
    struct ProviderDay: Sendable, Equatable {
        let key: String
        let date: Date
        let uses: [String: UsageModelUse]

        var total: UsageModelUse {
            self.uses.values.reduce(UsageModelUse(), +)
        }
    }

    /// One day of all providers together.
    struct Day: Sendable, Equatable {
        let key: String
        let date: Date
        let byProvider: [UsageOverviewProviderKind: UsageModelUse]
        let byModel: [String: UsageModelUse]
        /// Parallel to `claudeAccounts`.
        let byAccount: [UsageModelUse]

        var total: UsageModelUse {
            self.byProvider.values.reduce(UsageModelUse(), +)
        }
    }

    /// Which models get a named row (and a color of their own), and which share "Other".
    struct RowPlan: Sendable, Equatable {
        let named: [String]
        let rest: [String]
        let colors: [String: UsageSeriesColor]
    }

    /// One period (or one zoom): the chart by provider and by model, the model rows and the total.
    public struct Period: Sendable, Equatable {
        public let period: UsageSpendPeriod
        let providerChart: UsageDayChartData
        let modelChart: UsageDayChartData
        /// Three leaders and "Other" (more than four models), otherwise one row per model.
        let rows: [UsageModelLine]
        public let whole: UsageModelUse
        /// What "Other" consists of, biggest first ("Astra $4,738"); empty without an "Other" row.
        let otherMembers: [String]
        /// No model inside "Other" had use in this period: the members are only named.
        let otherIsEmpty: Bool
        /// "12 days" for a zoom; nil for a preset period.
        public let customTitle: String?
        /// Set for a zoom: the span shown (`period` is then the smallest preset covering it).
        var range: UsageSpendRange?
        let plan: RowPlan

        func chart(_ breakdown: UsageOverviewBreakdown) -> UsageDayChartData {
            breakdown == .providers ? self.providerChart : self.modelChart
        }

        /// "Other: Astra $4,738, Sol 5.6 $1,942 and 4 more." with the first `count` members named.
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

    /// One row of Overview under the chart (Claude, Codex, Antigravity) and its hover panel.
    public struct ProviderSummary: Sendable, Equatable, Identifiable {
        /// One limit in the provider's panel: a Claude account's weekly limit, Codex's session or weekly one.
        public struct Limit: Sendable, Equatable, Identifiable {
            public enum Tone: Sendable, Equatable {
                case good, warning, bad, neutral
            }

            public let id: String
            /// "Lemelson", "Session", "Weekly".
            public let name: String
            public let usedPct: Double?
            /// "Enough", "Out in ≈2d 4h", "Out now", "No forecast".
            public let verdict: String
            public let tone: Tone
            /// "resets Tue 11:00", "Paused · VPN", "Collector error: …".
            public let detail: String?
            /// The reading told apart, when it can be: the bar is then drawn in parts.
            public var split: Split? = nil

            /// This Mac, others and what is not split yet, in percent of the limit.
            public struct Split: Sendable, Equatable {
                public let you: Double
                public let others: Double
                public let unknown: Double

                /// Nil when nothing is told apart: Claude without a rate, a provider without a split.
                init?(window: UsagePanelState.Window, sources: UsageLimitSources) {
                    let segments = UsageSegment.threeWay(for: window, sources: sources)
                    guard segments.contains(where: { $0.kind != .unknown }) else { return nil }
                    func part(_ kind: UsageSegment.Kind) -> Double {
                        segments.first { $0.kind == kind }?.barValue ?? 0
                    }
                    self.you = part(.you)
                    self.others = part(.others)
                    self.unknown = part(.unknown)
                }
            }
        }

        public let kind: UsageOverviewProviderKind
        public let title: String
        /// "3 accounts", "Plus", "Ultra 5x"; empty when unknown.
        public let subtitle: String
        /// The weekly limit at the right of the row: "74% left", "Misha · 8% left", "Out · back in 9h 35m", "—".
        public let statusText: String
        public let statusTone: Limit.Tone
        public var statusIsAlert: Bool {
            self.statusTone == .bad
        }
        public var statusIsGood: Bool {
            self.statusTone == .good
        }
        /// "24h" (rolling) or "Today" (older summaries).
        public let firstCellTitle: String
        public let usd24h: Double
        public let usd7d: Double
        public let periodUsd: [UsageSpendPeriod: Double]
        /// One quiet line in place of the numbers: no block in the summary, or the collector failed on it.
        public let unavailableNote: String?
        public let limits: [Limit]
        /// "Weekly limit by account", "Limits".
        public let limitsTitle: String
        let days: [ProviderDay]
        /// The provider's models, most spend first.
        let order: [String]
        let labels: [String: String]
        /// Stable color per model key from Overview's 180-day palette.
        let palette: [String: UsageSeriesColor]
        let unpriced: Set<String>
        /// First day key of each preset period.
        let periodStarts: [UsageSpendPeriod: String]

        public var id: String {
            self.kind.rawValue
        }

        /// Some day has use.
        public var hasSpend: Bool {
            !self.order.isEmpty
        }

        /// The provider's spend on the days of `range`.
        public func spend(in range: UsageSpendRange) -> UsageModelUse {
            self.days.reduce(UsageModelUse()) { range.contains($1.key) ? $0 + $1.total : $0 }
        }

        /// The provider's own "By model" rows of a period or a zoom (three leaders and "Other" past four
        /// models, so the panel keeps one height) and their total.
        func modelLines(for period: UsageSpendPeriod, customRange: UsageSpendRange?) -> ([UsageModelLine], Double) {
            let from = self.periodStarts[period] ?? ""
            let includes: (String) -> Bool = { key in customRange?.contains(key) ?? (key >= from) }
            let split = UsageOverviewSpend.sum(self.days.filter { includes($0.key) }.map(\.uses))
            let plan = UsageOverviewSpend.rowPlan(
                split: split,
                order: self.order,
                hasOther: self.order.count > UsageOverviewSpend.namedRows + 1,
                palette: self.palette)
            var lines = plan.named.map { key in
                UsageModelLine(
                    id: key,
                    label: self.labels[key] ?? key,
                    color: plan.colors[key] ?? .other,
                    use: split[key] ?? UsageModelUse(),
                    unpriced: self.unpriced.contains(key))
            }
            if !plan.rest.isEmpty {
                lines.append(UsageModelLine(
                    id: "other", label: "Other", color: .other,
                    use: plan.rest.reduce(UsageModelUse()) { $0 + (split[$1] ?? UsageModelUse()) }))
            }
            return (lines, split.values.reduce(0) { $0 + $1.usd })
        }
    }

    /// A Claude account of the day panel's Claude line.
    struct ClaudeAccount: Sendable, Equatable {
        let id: String
        let name: String
    }

    // MARK: Values

    /// The first tile: the rolling last 24 hours, or calendar today in older summaries.
    public let last24hOrToday: UsageModelUse
    /// True: `last24hOrToday` is the collector's rolling 24 hours ("Last 24 hours").
    public let usesRolling24h: Bool
    public let today: UsageModelUse
    public let week: UsageModelUse
    /// The periods worth a button: up to the first one that covers the whole history.
    public let offered: [UsageSpendPeriod]
    /// Some day of some provider has spend or tokens.
    public let hasSpend: Bool
    /// Claude, Codex, Antigravity: always all three.
    public let providers: [ProviderSummary]
    /// Display name of every model key.
    let labels: [String: String]
    /// The providers with data in the chart, in order.
    let shownKinds: [UsageOverviewProviderKind]
    let claudeAccounts: [ClaudeAccount]
    private let periods: [Period]
    private let days: [Day]
    private let dayIndex: [String: Int]
    private let dayTotals: [UsageDayTotal]
    /// Every model of the history (180 days), most spend first.
    private let order: [String]
    /// Stable model colors assigned once from the 180-day ranking so a model keeps one color across periods and days.
    private let palette: [String: UsageSeriesColor]
    private let hasOther: Bool
    private let unpriced: Set<String>

    public init(state: UsagePanelState, now: Date) {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        var labels: [String: String] = [:]
        var unpriced = Set<String>()
        // Per provider: day key → model key → use.
        var perProvider: [UsageOverviewProviderKind: [String: [String: UsageModelUse]]] = [:]
        func add(_ kind: UsageOverviewProviderKind, day: String, model: String, _ use: UsageModelUse) {
            guard !use.isZero else { return }
            // In place, through the default subscripts: no dictionary is copied.
            perProvider[kind, default: [:]][day, default: [:]][model, default: UsageModelUse()].add(use)
        }

        // Claude: every account that has numbers, by model family.
        let accounts = state.accounts.filter { !$0.isUnavailable }
        let claudeAccounts = accounts.map { ClaudeAccount(id: $0.id, name: $0.displayName) }
        var accountDays: [String: [UsageModelUse]] = [:]
        for family in UsageModelFamily.allCases {
            labels[Self.claudeKey(family)] = family == .other ? "Claude other" : family.title
        }
        for (index, account) in accounts.enumerated() {
            for day in account.daily ?? [] {
                let split = day.split
                for family in UsageModelFamily.allCases {
                    add(.claude, day: day.day, model: Self.claudeKey(family), split[family])
                }
                let total = split.total
                guard !total.isZero else { continue }
                accountDays[day.day, default: Array(repeating: UsageModelUse(), count: accounts.count)][index].add(total)
            }
        }

        // Codex and Antigravity: the block's models under the names of their pages.
        var trackedSince: [Date] = state.trackedSince.map { [$0] } ?? []
        var blocks: [UsageOverviewProviderKind: UsageProviderBlock] = [:]
        for kind in [UsageOverviewProviderKind.codex, .antigravity] {
            guard let spec = kind.spec, let block = spec.block(in: state), block.error == nil else { continue }
            blocks[kind] = block
            if let since = block.account.trackedSince {
                trackedSince.append(Date(timeIntervalSince1970: since))
            }
            var ids = Set<String>()
            for day in block.account.daily ?? [] {
                if let models = day.m, !models.isEmpty {
                    for (id, value) in models {
                        ids.insert(id)
                        add(kind, day: day.day, model: Self.key(kind, id),
                            UsageModelUse(usd: value.first ?? 0, tokens: value.count > 1 ? value[1] : 0))
                    }
                } else {
                    ids.insert(UsageModelNaming.unknown)
                    add(kind, day: day.day, model: Self.key(kind, UsageModelNaming.unknown),
                        UsageModelUse(usd: day.total, tokens: day.tokens ?? 0))
                }
                for id in (day.unpriced ?? [:]).keys {
                    unpriced.insert(Self.key(kind, id))
                }
            }
            for (id, stats) in block.models where stats.priced == false {
                unpriced.insert(Self.key(kind, id))
            }
            let names = block.modelLabels(spec: spec).merging(spec.models.labels(for: ids.sorted())) { known, _ in known }
            for (id, name) in names {
                labels[Self.key(kind, id)] = name
            }
        }

        // Days of all providers together.
        let shownKinds = UsageOverviewProviderKind.allCases.filter { kind in
            kind == .claude ? !accounts.isEmpty : blocks[kind] != nil
        }
        var keys = Set<String>()
        for days in perProvider.values {
            keys.formUnion(days.keys)
        }
        let days: [Day] = keys.sorted().compactMap { key in
            guard let date = UsageDayKey.date(key) else { return nil }
            var byProvider: [UsageOverviewProviderKind: UsageModelUse] = [:]
            var byModel: [String: UsageModelUse] = [:]
            for kind in UsageOverviewProviderKind.allCases {
                guard let uses = perProvider[kind]?[key] else { continue }
                byProvider[kind] = uses.values.reduce(UsageModelUse(), +)
                byModel.merge(uses) { $0 + $1 }
            }
            return Day(
                key: key, date: date, byProvider: byProvider, byModel: byModel,
                byAccount: accountDays[key] ?? Array(repeating: UsageModelUse(), count: accounts.count))
        }

        func sum(lastDays count: Int, _ select: (Day) -> [String: UsageModelUse]) -> [String: UsageModelUse] {
            let from = UsageDayKey.start(days: count, now: now)
            return Self.sum(days.filter { $0.key >= from }.map(select))
        }
        func whole(_ split: [String: UsageModelUse]) -> UsageModelUse {
            split.values.reduce(UsageModelUse(), +)
        }
        let today = whole(sum(lastDays: 1, \.byModel))
        self.today = today
        self.week = whole(sum(lastDays: 7, \.byModel))
        // The collector's rolling 24 hours; calendar today only for a summary written before it had them.
        let rolling24h = state.rolling24hUsd
        let usesRolling = rolling24h != nil
        self.last24hOrToday = rolling24h.map { UsageModelUse(usd: $0, tokens: state.rolling24hTokens ?? 0) } ?? today
        self.usesRolling24h = usesRolling
        self.hasSpend = !days.isEmpty

        // Models of the longest period, most spend first: each period's leaders are picked from these, and
        // their colors are fixed once here so models keep one identity across periods, zooms and day panels.
        let splits = Dictionary(uniqueKeysWithValues: UsageSpendPeriod.allCases.map { ($0, sum(lastDays: $0.days, \.byModel)) })
        let longest = splits[.d180] ?? [:]
        let order = Self.ranked(Array(longest.keys), by: longest)
        let palette = Self.colors(for: order)
        let hasOther = order.count > Self.namedRows + 1

        // The history starts at the first call on record of any provider.
        let firstUse = days.first { !$0.total.isZero }.map(\.date)
        let firstDay = (trackedSince.map { calendar.startOfDay(for: $0) } + [firstUse].compactMap(\.self)).min()
        var offered: [UsageSpendPeriod] = []
        for period in UsageSpendPeriod.allCases {
            offered.append(period)
            let start = calendar.date(byAdding: .day, value: -(period.days - 1), to: todayStart) ?? todayStart
            if firstDay.map({ $0 >= start }) ?? true {
                break
            }
        }

        self.offered = offered
        self.labels = labels
        self.shownKinds = shownKinds
        self.claudeAccounts = claudeAccounts
        self.days = days
        self.dayIndex = Dictionary(days.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { _, last in last })
        self.dayTotals = days.map { UsageDayTotal(key: $0.key, date: $0.date, use: $0.total) }
        self.order = order
        self.palette = palette
        self.hasOther = hasOther
        self.unpriced = unpriced

        let periodStarts = Dictionary(uniqueKeysWithValues: UsageSpendPeriod.allCases.map {
            ($0, UsageDayKey.start(days: $0.days, now: now))
        })
        let firstAsked = Self.hint(firstDay: firstDay, now: now)
        self.periods = UsageSpendPeriod.allCases.map { period in
            let domain = Self.domain(period: period, firstDay: firstDay, now: now)
            let from = UsageDayKey.string(domain.lowerBound)
            return Self.makePeriod(
                period: period,
                range: nil,
                split: splits[period] ?? [:],
                domain: domain,
                includes: { $0 >= from },
                hint: firstAsked(period),
                days: days,
                order: order,
                palette: palette,
                labels: labels,
                hasOther: hasOther,
                shownKinds: shownKinds,
                unpriced: unpriced)
        }

        // The three rows.
        self.providers = UsageOverviewProviderKind.allCases.map { kind in
            let providerDays: [ProviderDay] = (perProvider[kind] ?? [:]).compactMap { key, uses in
                UsageDayKey.date(key).map { ProviderDay(key: key, date: $0, uses: uses) }
            }.sorted { $0.key < $1.key }
            return Self.summary(
                kind: kind,
                state: state,
                block: blocks[kind],
                days: providerDays,
                labels: labels,
                palette: palette,
                unpriced: unpriced,
                periodStarts: periodStarts,
                usesRolling24h: usesRolling,
                now: now)
        }
    }

    // MARK: Reading

    public subscript(period: UsageSpendPeriod) -> Period {
        self.periods.first { $0.period == period } ?? self.periods[0]
    }

    /// The period to show for the menu-wide choice: the chosen one if offered, else the longest offered one.
    public func effective(_ chosen: UsageSpendPeriod) -> UsageSpendPeriod {
        UsageSpendPeriod.effective(chosen, offered: self.offered)
    }

    public func provider(_ kind: UsageOverviewProviderKind) -> ProviderSummary? {
        self.providers.first { $0.kind == kind }
    }

    /// Row slots of the model rows: the same in every period and zoom.
    var rowCount: Int {
        self.hasOther ? Self.namedRows + 1 : self.order.count
    }

    /// Row slots of the day panel's model section.
    var dayRowCount: Int {
        self.hasOther ? Self.dayNamedRows + 1 : self.order.count
    }

    // MARK: Zoom

    /// The layer of a zoom: the same charts and rows as a period, over the span's days only.
    public func period(range: UsageSpendRange) -> Period {
        Self.makePeriod(
            period: range.coveringPeriod,
            range: range,
            split: Self.sum(self.days.filter { range.contains($0.key) }.map(\.byModel)),
            domain: range.domain,
            includes: { range.contains($0) },
            hint: UsageSpendDigest.zoomHint,
            days: self.days,
            order: self.order,
            palette: self.palette,
            labels: self.labels,
            hasOther: self.hasOther,
            shownKinds: self.shownKinds,
            unpriced: self.unpriced)
    }

    /// The zoomed header's tiles: the span's total, daily average and busiest day.
    public func customSummary(for range: UsageSpendRange) -> UsageCustomRangeSummary {
        UsageDayStats.summary(range: range, days: self.dayTotals)
    }

    // MARK: Day panel

    /// Overview's day panel: the day by provider (Claude with its accounts under it) and by model.
    public func dayDetailCatalog(chartID: String = UsageOverviewSpend.defaultChartID, now: Date) -> UsageDayDetailCatalog {
        let spend = self
        let todayKey = UsageDayKey.string(now)
        return UsageDayDetailCatalog(
            chartID: chartID,
            defaultDayKey: todayKey,
            fixedSection1Rows: UsageOverviewProviderKind.allCases.count,
            fixedSection2Rows: self.dayRowCount,
            section1NameWidth: 66,
            section2NameWidth: 66,
            reservesNoteLine: self.hasOther,
            dayDetail: { key, period, range in
                spend.dayDetail(key, period: spend.effective(period), range: range, todayKey: todayKey)
            },
            rangePreview: { range in
                spend.rangePreview(range)
            })
    }

    func dayDetail(_ key: String, period: UsageSpendPeriod, range: UsageSpendRange?, todayKey: String) -> UsageDayDetail {
        let domain = range?.domain ?? self[period].providerChart.domain
        let context = UsageDayStats.context(dayKey: key, domain: domain, days: self.dayTotals)
        // The models of the shown period or zoom, so the colors match the chart.
        let base = range.map { range in
            Self.rowPlan(
                split: Self.sum(self.days.filter { range.contains($0.key) }.map(\.byModel)),
                order: self.order,
                hasOther: self.hasOther,
                palette: self.palette)
        } ?? self[period].plan
        let day = self.dayIndex[key].map { self.days[$0] }
        let uses = day?.byModel ?? [:]
        let plan = self.dayPlan(base, uses: uses)
        let total = day?.total ?? UsageModelUse()
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
            section1Title: "By provider",
            section1Rows: self.providerRows(day?.byProvider ?? [:], accounts: day?.byAccount ?? [], fine: true),
            section2Title: "By model",
            section2Rows: self.modelRows(plan, uses: uses),
            otherNote: self.otherNote(plan, uses: uses))
    }

    func rangePreview(_ range: UsageSpendRange) -> UsageRangeDetailPreview {
        let inside = self.days.filter { range.contains($0.key) }
        let split = Self.sum(inside.map(\.byModel))
        var byProvider: [UsageOverviewProviderKind: UsageModelUse] = [:]
        var byAccount = Array(repeating: UsageModelUse(), count: self.claudeAccounts.count)
        for day in inside {
            byProvider.merge(day.byProvider) { $0 + $1 }
            for (index, use) in day.byAccount.enumerated() where byAccount.indices.contains(index) {
                byAccount[index] = byAccount[index] + use
            }
        }
        let base = Self.rowPlan(split: split, order: self.order, hasOther: self.hasOther, palette: self.palette)
        let plan = self.dayPlan(base, uses: split)
        let summary = UsageDayStats.summary(range: range, days: self.dayTotals)
        return UsageRangeDetailPreview(
            range: range,
            totalUsd: summary.total.usd,
            totalTokens: summary.total.tokens,
            dailyAverageUsd: summary.dailyAverage.usd,
            busiestDay: summary.busiestDay,
            section1Title: "By provider",
            section1Rows: self.providerRows(byProvider, accounts: byAccount, fine: false),
            section2Title: "By model",
            section2Rows: self.modelRows(plan, uses: split))
    }

    /// Claude, Codex, Antigravity, always all three; under Claude its accounts with use, when there are several.
    private func providerRows(
        _ uses: [UsageOverviewProviderKind: UsageModelUse],
        accounts: [UsageModelUse],
        fine: Bool) -> [UsageDayDetail.Row]
    {
        UsageOverviewProviderKind.allCases.map { kind in
            let use = uses[kind] ?? UsageModelUse()
            var subtitle: String?
            if kind == .claude, self.claudeAccounts.count >= 2 {
                let parts = self.claudeAccounts.enumerated().compactMap { index, account -> String? in
                    let usd = accounts.indices.contains(index) ? accounts[index].usd : 0
                    guard usd >= 0.005 else { return nil }
                    let text = fine ? UsageFormat.usdFine(usd) : UsageFormat.usd(usd)
                    return "\(account.name) \(text)"
                }
                // Kept on every day, so the panel keeps one height.
                subtitle = parts.isEmpty ? "No Claude calls" : parts.joined(separator: " · ")
            }
            return UsageDayDetail.Row(
                id: kind.rawValue, label: kind.title, color: kind.seriesColor, usd: use.usd, tokens: use.tokens,
                subtitle: subtitle)
        }
    }

    /// Active models on this day (or dragged span) come first, biggest spend first, keeping their stable
    /// Overview colors; unused slots are filled from the period's leaders so the panel keeps one height.
    private func dayPlan(_ base: RowPlan, uses: [String: UsageModelUse]) -> RowPlan {
        let active = Self.ranked(self.order.filter { !(uses[$0]?.isZero ?? true) }, by: uses)
        let fallback = base.named + self.order.filter { !base.named.contains($0) }
        let ordered = active + fallback.filter { !active.contains($0) }
        let named = self.hasOther ? Array(ordered.prefix(Self.dayNamedRows)) : ordered
        let colors = Self.colors(for: named, preferred: self.palette)
        return RowPlan(named: named, rest: self.order.filter { !named.contains($0) }, colors: colors)
    }

    private func modelRows(_ plan: RowPlan, uses: [String: UsageModelUse]) -> [UsageDayDetail.Row] {
        var rows = plan.named.map { key in
            let use = uses[key] ?? UsageModelUse()
            return UsageDayDetail.Row(
                id: key,
                label: self.labels[key] ?? key,
                color: plan.colors[key] ?? .other,
                usd: use.usd,
                tokens: use.tokens,
                unpriced: self.unpriced.contains(key))
        }
        if !plan.rest.isEmpty {
            let other = plan.rest.reduce(UsageModelUse()) { $0 + (uses[$1] ?? UsageModelUse()) }
            rows.append(UsageDayDetail.Row(id: "other", label: "Other", color: .other, usd: other.usd, tokens: other.tokens))
        }
        return rows
    }

    /// "Other: Astra $4.70, Sol 5.6 $1.20 and 2 more." for the models inside "Other" with use that day.
    private func otherNote(_ plan: RowPlan, uses: [String: UsageModelUse]) -> String? {
        let used = Self.ranked(plan.rest.filter { !(uses[$0]?.isZero ?? true) }, by: uses)
        guard !used.isEmpty else { return nil }
        let named = used.prefix(2).map { key in
            "\(self.labels[key] ?? key) \(UsageProviderSpend.cost(uses[key]?.usd ?? 0, unpriced: self.unpriced.contains(key)))"
        }
        let rest = used.count - named.count
        return "Other: " + named.joined(separator: ", ") + (rest > 0 ? " and \(rest) more." : ".")
    }

    // MARK: Building

    static func claudeKey(_ family: UsageModelFamily) -> String {
        "claude:\(family.rawValue)"
    }

    static func key(_ kind: UsageOverviewProviderKind, _ id: String) -> String {
        "\(kind.rawValue):\(id)"
    }

    static func sum(_ splits: [[String: UsageModelUse]]) -> [String: UsageModelUse] {
        var total: [String: UsageModelUse] = [:]
        for split in splits {
            total.merge(split) { $0 + $1 }
        }
        return total
    }

    /// Most dollars first, then most tokens, then by key: the same order on every build.
    static func ranked(_ keys: [String], by split: [String: UsageModelUse]) -> [String] {
        keys.sorted { lhs, rhs in
            let a = split[lhs] ?? UsageModelUse()
            let b = split[rhs] ?? UsageModelUse()
            if a.usd != b.usd { return a.usd > b.usd }
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            return lhs < rhs
        }
    }

    /// The split's leaders by rank, then the models without use in it in history order; past `namedRows`
    /// (with more than one model left) the rest share "Other".
    static func rowPlan(
        split: [String: UsageModelUse],
        order: [String],
        hasOther: Bool,
        palette: [String: UsageSeriesColor] = [:]) -> RowPlan
    {
        let used = Self.ranked(order.filter { !(split[$0]?.isZero ?? true) }, by: split)
        let ranked = used + order.filter { !used.contains($0) }
        let named = hasOther ? Array(ranked.prefix(Self.namedRows)) : ranked
        return RowPlan(
            named: named,
            rest: ranked.filter { !named.contains($0) },
            colors: Self.colors(for: named, preferred: palette))
    }

    /// Opus orange and Fable violet always; other models keep their stable color from `preferred` (assigned from
    /// the 180-day ranking) when not already taken, and otherwise take the next free color.
    static func colors(for named: [String], preferred: [String: UsageSeriesColor] = [:]) -> [String: UsageSeriesColor] {
        var colors: [String: UsageSeriesColor] = [:]
        var taken = Set<UsageSeriesColor>()
        for key in named {
            if let fixed = Self.fixedColor(key) {
                colors[key] = fixed
                taken.insert(fixed)
            }
        }
        for key in named where colors[key] == nil {
            if let kept = preferred[key], kept != .other, !taken.contains(kept) {
                colors[key] = kept
                taken.insert(kept)
            }
        }
        for key in named where colors[key] == nil {
            colors[key] = Self.nextColor(for: key, taken: &taken)
        }
        return colors
    }

    private static func fixedColor(_ key: String) -> UsageSeriesColor? {
        switch key {
        case Self.claudeKey(.opus): .claude(.opus)
        case Self.claudeKey(.fable): .claude(.fable)
        default: nil
        }
    }

    /// A color not taken yet: Opus and Fable their own; Sonnet and Haiku their own when still free (as on
    /// Claude Spend); anything else the first free one; grey when none is left.
    static func nextColor(for key: String, taken: inout Set<UsageSeriesColor>) -> UsageSeriesColor {
        var preferred: [UsageSeriesColor] = []
        if let fixed = Self.fixedColor(key) {
            preferred.append(fixed)
        }
        if key == Self.claudeKey(.sonnet) {
            preferred.append(.claude(.sonnet))
        } else if key == Self.claudeKey(.haiku) {
            preferred.append(.claude(.haiku))
        }
        for color in preferred + Self.freeColors where !taken.contains(color) {
            taken.insert(color)
            return color
        }
        return .other
    }

    /// One period's (or one zoom's) charts, rows and Other note.
    private static func makePeriod(
        period: UsageSpendPeriod,
        range: UsageSpendRange?,
        split: [String: UsageModelUse],
        domain: ClosedRange<Date>,
        includes: (String) -> Bool,
        hint: String,
        days: [Day],
        order: [String],
        palette: [String: UsageSeriesColor],
        labels: [String: String],
        hasOther: Bool,
        shownKinds: [UsageOverviewProviderKind],
        unpriced: Set<String>) -> Period
    {
        let plan = Self.rowPlan(split: split, order: order, hasOther: hasOther, palette: palette)
        var providerBars: [UsageDayChartData.Bar] = []
        var modelBars: [UsageDayChartData.Bar] = []
        var notes: [String: String] = [:]
        for day in days where includes(day.key) {
            for kind in shownKinds {
                if let use = day.byProvider[kind], use.usd > 0 {
                    providerBars.append(.init(
                        key: day.key, date: day.date, series: kind.title, color: kind.seriesColor, usd: use.usd))
                }
            }
            for key in plan.named {
                if let use = day.byModel[key], use.usd > 0 {
                    modelBars.append(.init(
                        key: day.key, date: day.date, series: labels[key] ?? key, color: plan.colors[key] ?? .other,
                        usd: use.usd))
                }
            }
            let others = plan.rest.reduce(0) { $0 + (day.byModel[$1]?.usd ?? 0) }
            if others > 0 {
                modelBars.append(.init(key: day.key, date: day.date, series: "Other", color: .other, usd: others))
            }
            let tokens = day.total.tokens
            if tokens > 0 {
                notes[day.key] = "\(UsageFormat.tokens(tokens)) tokens"
            }
        }
        var rows = plan.named.map { key in
            UsageModelLine(
                id: key,
                label: labels[key] ?? key,
                color: plan.colors[key] ?? .other,
                use: split[key] ?? UsageModelUse(),
                unpriced: unpriced.contains(key))
        }
        var members: [String] = []
        var otherIsEmpty = false
        if !plan.rest.isEmpty {
            let uses = plan.rest.map { ($0, split[$0] ?? UsageModelUse()) }
            rows.append(UsageModelLine(id: "other", label: "Other", color: .other, use: uses.reduce(UsageModelUse()) { $0 + $1.1 }))
            let shown = uses.filter { !$0.1.isZero }
            if shown.isEmpty {
                otherIsEmpty = true
                members = plan.rest.map { labels[$0] ?? $0 }.sorted()
            } else {
                members = shown.map { key, use in
                    "\(labels[key] ?? key) \(UsageProviderSpend.cost(use.usd, unpriced: unpriced.contains(key)))"
                }
            }
        }
        let emptyText = range == nil
            ? "No calls recorded on this Mac in this period."
            : "No calls recorded on this Mac on these days."
        let providerChart = UsageDayChartData(
            period: period,
            domain: domain,
            bars: providerBars,
            hint: hint,
            legend: shownKinds.map { UsageDayChartData.Legend(id: $0.rawValue, name: $0.title, color: $0.seriesColor) },
            dayNotes: notes,
            emptyText: emptyText,
            chipLimit: nil,
            centsInChips: true,
            customRange: range)
        let modelChart = UsageDayChartData(
            period: period,
            domain: domain,
            bars: modelBars,
            hint: hint,
            legend: plan.named.map {
                UsageDayChartData.Legend(id: $0, name: labels[$0] ?? $0, color: plan.colors[$0] ?? .other)
            } + (plan.rest.isEmpty ? [] : [UsageDayChartData.Legend(id: "other", name: "Other", color: .other)]),
            dayNotes: notes,
            emptyText: emptyText,
            chipLimit: 3,
            centsInChips: true,
            customRange: range)
        return Period(
            period: period,
            providerChart: providerChart,
            modelChart: modelChart,
            rows: rows,
            whole: split.values.reduce(UsageModelUse(), +),
            otherMembers: members,
            otherIsEmpty: otherIsEmpty,
            customTitle: range.map { "\($0.dayCount) days" },
            range: range,
            plan: plan)
    }

    /// From the first day on record, but at least a week wide; never longer than the period.
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

    private static func hint(firstDay: Date?, now: Date) -> (UsageSpendPeriod) -> String {
        { period in
            let calendar = Calendar.current
            let asked = calendar.date(byAdding: .day, value: -(period.days - 1), to: calendar.startOfDay(for: now))
            if let asked, let firstDay, firstDay > asked {
                return "Since \(UsageFormat.format(firstDay, "MMM d")) · point at a bar or drag to zoom."
            }
            return "Point at a bar; drag across days to zoom in."
        }
    }
}

extension UsageModelUse {
    /// No dollars and no tokens.
    var isZero: Bool {
        self.usd <= 0 && self.tokens <= 0
    }

    mutating func add(_ other: UsageModelUse) {
        self = self + other
    }
}
