import SwiftUI

// MARK: - Models: Opus, Fable, Sonnet and Haiku, anything else as "Other"

public enum UsageModelFamily: String, CaseIterable, Sendable, Identifiable {
    case opus, fable, sonnet, haiku, other

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .opus: "Opus"
        case .fable: "Fable"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        case .other: "Other"
        }
    }

    public var color: Color {
        UsagePalette.claudeModel(self)
    }
}

/// Spend of one model: dollars at API prices and tokens.
public struct UsageModelUse: Sendable, Equatable {
    public var usd: Double
    public var tokens: Double

    public init(usd: Double = 0, tokens: Double = 0) {
        self.usd = usd
        self.tokens = tokens
    }

    public static func + (lhs: UsageModelUse, rhs: UsageModelUse) -> UsageModelUse {
        UsageModelUse(usd: lhs.usd + rhs.usd, tokens: lhs.tokens + rhs.tokens)
    }
}

/// Spend by model family over some period.
public struct UsageModelSplit: Sendable, Equatable {
    private var parts: [UsageModelFamily: UsageModelUse] = [:]

    public init() {}

    /// From the collector summary: `{"opus": [dollars, tokens], ...}`.
    public init(raw: [String: [Double]]) {
        for (key, value) in raw {
            self.add(
                UsageModelFamily(rawValue: key) ?? .other,
                UsageModelUse(usd: value.first ?? 0, tokens: value.count > 1 ? value[1] : 0))
        }
    }

    public mutating func add(_ family: UsageModelFamily, _ use: UsageModelUse) {
        self.parts[family] = self[family] + use
    }

    public mutating func add(_ other: UsageModelSplit) {
        for (family, use) in other.parts {
            self.add(family, use)
        }
    }

    public subscript(family: UsageModelFamily) -> UsageModelUse {
        self.parts[family] ?? UsageModelUse()
    }

    public var total: UsageModelUse {
        self.parts.values.reduce(UsageModelUse(), +)
    }

    /// The four models always, "Other" only when there is some.
    public var shownFamilies: [UsageModelFamily] {
        let other = self[.other]
        let hasOther = other.usd >= 0.005 || other.tokens > 0
        return UsageModelFamily.allCases.filter { $0 != .other || hasOther }
    }
}

extension UsageFormat {
    /// Dollars with cents for small amounts: a week of Haiku spend can be under a dollar.
    public static func usdFine(_ value: Double) -> String {
        value < 10 ? String(format: "$%.2f", value) : self.usd(value)
    }

    /// Percentages with tenths for small shares.
    public static func percentFine(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%%", value) : self.percent(value)
    }
}

// MARK: - Days

/// Day key "2026-11-23" in local time: this is how days are stored in the collector summary.
public enum UsageDayKey {
    public static func string(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// First day of a span of `days` calendar days, counting today.
    public static func start(days: Int, now: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return self.string(calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today)
    }
}

extension UsagePanelState.Day {
    public var split: UsageModelSplit {
        if let models = self.m {
            return UsageModelSplit(raw: models)
        }
        var split = UsageModelSplit()
        split.add(.opus, UsageModelUse(usd: self.opus ?? 0))
        split.add(.fable, UsageModelUse(usd: self.fable ?? 0))
        split.add(.other, UsageModelUse(usd: self.other ?? 0))
        return split
    }
}

extension UsagePanelState.Week {
    public var split: UsageModelSplit {
        if let models = self.m {
            return UsageModelSplit(raw: models)
        }
        var split = UsageModelSplit()
        split.add(.opus, UsageModelUse(usd: self.usd?.opus ?? 0))
        split.add(.fable, UsageModelUse(usd: self.usd?.fable ?? 0))
        split.add(.other, UsageModelUse(usd: self.usd?.other ?? 0, tokens: self.tokens ?? 0))
        return split
    }
}

extension UsagePanelState.Account {
    /// My spend over the last `days` calendar days, counting today.
    public func split(lastDays days: Int, now: Date) -> UsageModelSplit {
        let from = UsageDayKey.start(days: days, now: now)
        var split = UsageModelSplit()
        for day in self.daily ?? [] where day.day >= from {
            split.add(day.split)
        }
        return split
    }
}

extension UsagePanelState {
    public func split(lastDays days: Int, now: Date) -> UsageModelSplit {
        var split = UsageModelSplit()
        for account in self.accounts {
            split.add(account.split(lastDays: days, now: now))
        }
        return split
    }

    /// The day from which Claude Code logs exist on this Mac: earlier spend is unknown.
    public var trackedSince: Date? {
        self.accounts.compactMap(\.trackedSince).min().map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - Spend period

public enum UsageSpendPeriod: Int, CaseIterable, Identifiable, Sendable {
    case d30 = 30
    case d60 = 60
    case d90 = 90
    case d180 = 180

    public var id: Int {
        self.rawValue
    }

    public var days: Int {
        self.rawValue
    }

    public var short: String {
        "\(self.rawValue)d"
    }

    public var title: String {
        "Last \(self.rawValue) days"
    }
}

/// What the bars of the per-day spend chart are split by.
public enum UsageSpendBreakdown: String, CaseIterable, Identifiable, Sendable {
    case accounts
    case models

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .accounts: "Accounts"
        case .models: "Models"
        }
    }
}

/// What one point of the Value page's limit chart ("Is the limit changing?") stands for.
public enum UsageDriftPeriod: String, CaseIterable, Identifiable, Sendable {
    case month
    case week

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .month: "Month"
        case .week: "Week"
        }
    }
}

/// The unit of the Value page's limit chart: the same measured limit in Opus dollars, in dollars at the
/// model mix actually used, or in Fable dollars.
public enum UsageDriftUnit: String, CaseIterable, Identifiable, Sendable {
    case opus
    case mix
    case fable

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .opus: "Opus $"
        case .mix: "My mix"
        case .fable: "Fable $"
        }
    }
}

/// Choices shared by the spend card, the account rows and the detail panel, kept across menu opens and
/// restarts: one period and one chart breakdown for the whole menu, and the switches of the Value page
/// (Month / Week of "What the plan is worth", Month / Week and the unit of its limit chart).
@MainActor
public final class UsagePanelSelection: ObservableObject {
    public static let shared = UsagePanelSelection()
    public static let periodKey = "lemelsonSpendPeriod"
    public static let breakdownKey = "lemelsonSpendBreakdown"
    public static let driftPeriodKey = "lemelsonDriftPeriod"
    public static let driftUnitKey = "lemelsonDriftUnit"
    public static let valuePeriodKey = "lemelsonValuePeriod"

    /// Month by default: a month is what the plan is paid for, and the card above it shows a month too.
    @Published public var driftPeriod: UsageDriftPeriod {
        didSet {
            UserDefaults.standard.set(self.driftPeriod.rawValue, forKey: Self.driftPeriodKey)
        }
    }

    @Published public var driftUnit: UsageDriftUnit {
        didSet {
            UserDefaults.standard.set(self.driftUnit.rawValue, forKey: Self.driftUnitKey)
        }
    }

    /// Month or Week of "What the plan is worth".
    @Published public var valuePeriod: UsageDriftPeriod {
        didSet {
            UserDefaults.standard.set(self.valuePeriod.rawValue, forKey: Self.valuePeriodKey)
        }
    }

    @Published public var spendPeriod: UsageSpendPeriod {
        didSet {
            UserDefaults.standard.set(self.spendPeriod.rawValue, forKey: Self.periodKey)
            // Any period choice ends a zoom, also the period that was chosen before it.
            if self.customRange != nil {
                self.customRange = nil
            }
        }
    }

    /// The span a drag across a per-day chart zoomed into; nil shows `spendPeriod`. Menu-wide like the
    /// period, but not saved: a new launch starts on the period.
    @Published public var customRange: UsageSpendRange? = nil

    @Published public var spendBreakdown: UsageSpendBreakdown {
        didSet {
            UserDefaults.standard.set(self.spendBreakdown.rawValue, forKey: Self.breakdownKey)
        }
    }

    /// A period button: ends a zoom and shows `period` (also when it is the period chosen before the zoom).
    public func selectPeriod(_ period: UsageSpendPeriod) {
        if self.customRange != nil {
            self.customRange = nil
        }
        if self.spendPeriod != period {
            self.spendPeriod = period
        }
    }

    /// Zoom out to the chosen period.
    public func clearCustomRange() {
        if self.customRange != nil {
            self.customRange = nil
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        self.spendPeriod = UsageSpendPeriod(rawValue: defaults.integer(forKey: Self.periodKey)) ?? .d30
        self.spendBreakdown = defaults.string(forKey: Self.breakdownKey)
            .flatMap(UsageSpendBreakdown.init(rawValue:)) ?? .accounts
        self.driftPeriod = defaults.string(forKey: Self.driftPeriodKey)
            .flatMap(UsageDriftPeriod.init(rawValue:)) ?? .month
        self.driftUnit = defaults.string(forKey: Self.driftUnitKey).flatMap(UsageDriftUnit.init(rawValue:)) ?? .opus
        self.valuePeriod = defaults.string(forKey: Self.valuePeriodKey)
            .flatMap(UsageDriftPeriod.init(rawValue:)) ?? .month
    }
}

// MARK: - Spend numbers, computed once

/// One account's spend for every span the Spend mode shows (Today, 7 days and each period).
/// Built in a single pass over the account's days, so the rows and the detail panel only read it.
public struct UsageSpendAccountTotals: Sendable, Equatable {
    /// Today, 7 days and every selectable period.
    static let spans: [Int] = [1, 7] + UsageSpendPeriod.allCases.map(\.days)
    private let splits: [Int: UsageModelSplit]

    public init(account: UsagePanelState.Account, now: Date) {
        let starts = Self.spans.map { (days: $0, from: UsageDayKey.start(days: $0, now: now)) }
        var splits: [Int: UsageModelSplit] = [:]
        for span in Self.spans {
            splits[span] = UsageModelSplit()
        }
        // Same rule as `Account.split(lastDays:)`, in the same day order, so the sums are identical.
        for day in account.daily ?? [] {
            let matching = starts.filter { day.day >= $0.from }
            guard !matching.isEmpty else { continue }
            let split = day.split
            for span in matching {
                splits[span.days, default: UsageModelSplit()].add(split)
            }
        }
        self.splits = splits
    }

    /// Spend over the last `days` calendar days, counting today. Only the spans above are known.
    public func split(lastDays days: Int) -> UsageModelSplit {
        self.splits[days] ?? UsageModelSplit()
    }
}

/// Everything the Spend mode draws, computed once per summary: a period switch or a hover then only
/// reads ready values instead of walking the daily records and the calendar again.
/// All values depend only on the summary and on today's date.
public struct UsageSpendDigest: Sendable, Equatable {
    /// The chart id of Claude Spend's per-day chart (its day panel: `UsageDayDetailCatalog.panelKey(for:)`).
    public static let defaultChartID = "lemelsonSpendSummary"

    /// Spend of one account on one day: one bar segment of the chart.
    public struct Bar: Identifiable, Sendable, Equatable {
        let key: String
        let date: Date
        let account: String
        let colorIndex: Int
        let usd: Double
        let opus: Double
        let fable: Double

        public var id: String {
            "\(self.key)-\(self.account)"
        }
    }

    /// An account chip under the chart when no day is hovered.
    public struct Legend: Identifiable, Sendable, Equatable {
        public let id: String
        let name: String
        let colorIndex: Int
    }

    /// What one period shows: the chart by account and by model (range, bars, hint, legend) and the
    /// whole-period split.
    public struct Period: Sendable, Equatable {
        public let period: UsageSpendPeriod
        let chart: UsageDayChartData
        let modelChart: UsageDayChartData
        let whole: UsageModelSplit
        /// Set for a zoom: the span shown (`period` is then the smallest preset period covering it).
        var range: UsageSpendRange?

        func chart(_ breakdown: UsageSpendBreakdown) -> UsageDayChartData {
            breakdown == .accounts ? self.chart : self.modelChart
        }
    }

    /// One day of all accounts together: what the day panel and a zoom read.
    struct DayRecord: Sendable, Equatable {
        let key: String
        let date: Date
        /// Parallel to `legend`: dollars as the chart's bars count them, tokens from the model split.
        let byAccount: [UsageModelUse]
        let split: UsageModelSplit

        var total: UsageModelUse {
            self.byAccount.reduce(UsageModelUse(), +)
        }
    }

    public let today: UsageModelSplit
    public let week: UsageModelSplit
    let legend: [Legend]
    /// The Claude models every layer and the day panel list: those of the longest period, so a zoom or a
    /// day never changes the number of rows.
    let families: [UsageModelFamily]
    private let periods: [Period]
    private let accounts: [String: UsageSpendAccountTotals]
    private let days: [DayRecord]
    private let dayIndex: [String: Int]
    private let dayTotals: [UsageDayTotal]
    private let chartLegend: [UsageDayChartData.Legend]
    private let accountBars: [UsageDayChartData.Bar]
    private let modelBars: [UsageDayChartData.Bar]
    private let accountNotes: [String: String]
    private let modelNotes: [String: String]

    public init(state: UsagePanelState, now: Date) {
        let totals = state.accounts.map { UsageSpendAccountTotals(account: $0, now: now) }
        // Summed in account order, as `UsagePanelState.split(lastDays:)` does.
        func whole(_ days: Int) -> UsageModelSplit {
            totals.reduce(into: UsageModelSplit()) { $0.add($1.split(lastDays: days)) }
        }
        self.today = whole(1)
        self.week = whole(7)
        // An account the collector failed on has no days: it stays out of the chart's legend.
        let shown = state.accounts.filter { !$0.isUnavailable }
        let legend = shown.map { account in
            Legend(id: account.id, name: account.displayName, colorIndex: state.colorIndex(of: account))
        }
        self.legend = legend
        var byID: [String: UsageSpendAccountTotals] = [:]
        for (account, total) in zip(state.accounts, totals) {
            byID[account.id] = total
        }
        self.accounts = byID
        self.families = whole(UsageSpendPeriod.allCases.map(\.days).max() ?? 180).shownFamilies

        // Every bar once; each period keeps the ones inside its range (the order stays as before).
        let allBars = state.accounts.flatMap { account in
            let colorIndex = state.colorIndex(of: account)
            return (account.daily ?? []).compactMap { day -> Bar? in
                guard day.total > 0, let date = UsageDayKey.date(day.day) else { return nil }
                return Bar(
                    key: day.day,
                    date: date,
                    account: account.displayName,
                    colorIndex: colorIndex,
                    usd: day.total,
                    opus: day.opus ?? 0,
                    fable: day.fable ?? 0)
            }
        }
        let accountBars = allBars.map {
            UsageDayChartData.Bar(key: $0.key, date: $0.date, series: $0.account, color: .account($0.colorIndex),
                                  usd: $0.usd)
        }
        // The grey part of a pointed-at day: that day's Opus and Fable over all accounts.
        var sums: [String: (opus: Double, fable: Double)] = [:]
        for bar in allBars {
            let sum = sums[bar.key] ?? (0, 0)
            sums[bar.key] = (sum.opus + bar.opus, sum.fable + bar.fable)
        }
        let accountNotes = sums.mapValues { "Opus \(UsageFormat.usd($0.opus)) · Fable \(UsageFormat.usd($0.fable))" }
        // The same days by model, all accounts together.
        var modelDays: [String: UsageModelSplit] = [:]
        for account in state.accounts {
            for day in account.daily ?? [] where day.total > 0 {
                modelDays[day.day, default: UsageModelSplit()].add(day.split)
            }
        }
        let modelBars = modelDays.keys.sorted().flatMap { key -> [UsageDayChartData.Bar] in
            guard let date = UsageDayKey.date(key), let split = modelDays[key] else { return [] }
            return UsageModelFamily.allCases.compactMap { family in
                let usd = split[family].usd
                guard usd >= 0.005 else { return nil }
                return UsageDayChartData.Bar(key: key, date: date, series: family.title, color: .claude(family), usd: usd)
            }
        }
        let modelNotes = modelDays.mapValues { "\(UsageFormat.tokens($0.total.tokens)) tokens" }
        let chartLegend = legend.map { UsageDayChartData.Legend(id: $0.id, name: $0.name, color: .account($0.colorIndex)) }
        self.accountBars = accountBars
        self.modelBars = modelBars
        self.accountNotes = accountNotes
        self.modelNotes = modelNotes
        self.chartLegend = chartLegend

        // Every day with use, all accounts together, for the day panel and a zoom.
        var records: [String: (split: UsageModelSplit, byAccount: [UsageModelUse])] = [:]
        for (index, account) in shown.enumerated() {
            for day in account.daily ?? [] {
                let split = day.split
                let tokens = split.total.tokens
                guard day.total > 0 || tokens > 0 else { continue }
                var record = records[day.day]
                    ?? (split: UsageModelSplit(), byAccount: Array(repeating: UsageModelUse(), count: shown.count))
                record.split.add(split)
                record.byAccount[index] = record.byAccount[index] + UsageModelUse(usd: day.total, tokens: tokens)
                records[day.day] = record
            }
        }
        let days = records.keys.sorted().compactMap { key -> DayRecord? in
            guard let record = records[key], let date = UsageDayKey.date(key) else { return nil }
            return DayRecord(key: key, date: date, byAccount: record.byAccount, split: record.split)
        }
        self.days = days
        self.dayIndex = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.key, $0) })
        self.dayTotals = days.map { UsageDayTotal(key: $0.key, date: $0.date, use: $0.total) }

        let trackedSince = state.trackedSince
        self.periods = UsageSpendPeriod.allCases.map { period in
            let domain = Self.domain(period: period, trackedSince: trackedSince, now: now)
            let from = UsageDayKey.string(domain.lowerBound)
            let split = whole(period.days)
            let charts = Self.charts(
                period: period,
                domain: domain,
                includes: { $0 >= from },
                hint: Self.hint(period: period, domain: domain, now: now),
                split: split,
                accountBars: accountBars,
                modelBars: modelBars,
                legend: chartLegend,
                accountNotes: accountNotes,
                modelNotes: modelNotes,
                range: nil)
            return Period(period: period, chart: charts.accounts, modelChart: charts.models, whole: split)
        }
    }

    public subscript(period: UsageSpendPeriod) -> Period {
        self.periods.first { $0.period == period } ?? self.periods[0]
    }

    public func totals(for account: UsagePanelState.Account) -> UsageSpendAccountTotals? {
        self.accounts[account.id]
    }

    // MARK: Zoom

    /// The layer of a zoom: the same charts and models as a period, over the span's days only.
    public func period(range: UsageSpendRange) -> Period {
        var split = UsageModelSplit()
        for day in self.days where range.contains(day.key) {
            split.add(day.split)
        }
        let covering = range.coveringPeriod
        let charts = Self.charts(
            period: covering,
            domain: range.domain,
            includes: { range.contains($0) },
            hint: Self.zoomHint,
            split: split,
            accountBars: self.accountBars,
            modelBars: self.modelBars,
            legend: self.chartLegend,
            accountNotes: self.accountNotes,
            modelNotes: self.modelNotes,
            range: range)
        return Period(period: covering, chart: charts.accounts, modelChart: charts.models, whole: split, range: range)
    }

    /// The zoomed header's tiles: the span's total, daily average and busiest day.
    public func customSummary(for range: UsageSpendRange) -> UsageCustomRangeSummary {
        UsageDayStats.summary(range: range, days: self.dayTotals)
    }

    // MARK: Day panel

    /// The day panel of Claude Spend's chart: by account and by model, whichever split the chart shows.
    public func dayDetailCatalog(chartID: String = UsageSpendDigest.defaultChartID, now: Date) -> UsageDayDetailCatalog {
        let digest = self
        let todayKey = UsageDayKey.string(now)
        return UsageDayDetailCatalog(
            chartID: chartID,
            defaultDayKey: todayKey,
            fixedSection1Rows: self.legend.count,
            fixedSection2Rows: self.families.count,
            section1NameWidth: 66,
            // `UsageModelRow.claudeNameWidth`: room for "Sonnet".
            section2NameWidth: 40,
            dayDetail: { key, period, range in
                digest.dayDetail(key, period: period, range: range, todayKey: todayKey)
            },
            rangePreview: { range in
                digest.rangePreview(range)
            })
    }

    func dayDetail(_ key: String, period: UsageSpendPeriod, range: UsageSpendRange?, todayKey: String) -> UsageDayDetail {
        let domain = range?.domain ?? self[period].chart.domain
        let context = UsageDayStats.context(dayKey: key, domain: domain, days: self.dayTotals)
        let record = self.dayIndex[key].map { self.days[$0] }
        let total = record?.total ?? UsageModelUse()
        return UsageDayDetail(
            dayKey: key,
            date: record?.date ?? UsageDayKey.date(key) ?? domain.lowerBound,
            isToday: key == todayKey,
            totalUsd: total.usd,
            totalTokens: total.tokens,
            periodDays: context.count,
            periodLabel: UsageDayStats.label(days: context.count, isCustom: range != nil),
            isCustomRange: range != nil,
            periodDailyAverageUsd: context.average,
            rankInPeriod: context.rank,
            section1Title: "By account",
            section1Rows: self.accountRows(record?.byAccount ?? []),
            section2Title: "By model",
            section2Rows: self.familyRows(record?.split ?? UsageModelSplit()))
    }

    func rangePreview(_ range: UsageSpendRange) -> UsageRangeDetailPreview {
        var byAccount = Array(repeating: UsageModelUse(), count: self.legend.count)
        var split = UsageModelSplit()
        for day in self.days where range.contains(day.key) {
            split.add(day.split)
            for (index, use) in day.byAccount.enumerated() where byAccount.indices.contains(index) {
                byAccount[index] = byAccount[index] + use
            }
        }
        let summary = UsageDayStats.summary(range: range, days: self.dayTotals)
        return UsageRangeDetailPreview(
            range: range,
            totalUsd: summary.total.usd,
            totalTokens: summary.total.tokens,
            dailyAverageUsd: summary.dailyAverage.usd,
            busiestDay: summary.busiestDay,
            section1Title: "By account",
            section1Rows: self.accountRows(byAccount),
            section2Title: "By model",
            section2Rows: self.familyRows(split))
    }

    private func accountRows(_ uses: [UsageModelUse]) -> [UsageDayDetail.Row] {
        self.legend.enumerated().map { index, account in
            let use = uses.indices.contains(index) ? uses[index] : UsageModelUse()
            return UsageDayDetail.Row(
                id: account.id, label: account.name, color: .account(account.colorIndex), usd: use.usd,
                tokens: use.tokens)
        }
    }

    private func familyRows(_ split: UsageModelSplit) -> [UsageDayDetail.Row] {
        self.families.map { family in
            UsageDayDetail.Row(
                id: family.rawValue, label: family.title, color: .claude(family), usd: split[family].usd,
                tokens: split[family].tokens)
        }
    }

    // MARK: Building

    /// One period's (or one zoom's) chart by account and by model.
    private static func charts(
        period: UsageSpendPeriod,
        domain: ClosedRange<Date>,
        includes: (String) -> Bool,
        hint: String,
        split: UsageModelSplit,
        accountBars: [UsageDayChartData.Bar],
        modelBars: [UsageDayChartData.Bar],
        legend: [UsageDayChartData.Legend],
        accountNotes: [String: String],
        modelNotes: [String: String],
        range: UsageSpendRange?) -> (accounts: UsageDayChartData, models: UsageDayChartData)
    {
        let emptyText = range == nil
            ? "No Claude Code spend on this Mac in this period."
            : "No Claude Code spend on this Mac on these days."
        let accounts = UsageDayChartData(
            period: period,
            domain: domain,
            bars: accountBars.filter { includes($0.key) },
            hint: hint,
            legend: legend,
            dayNotes: accountNotes.filter { includes($0.key) },
            emptyText: emptyText,
            chipLimit: nil,
            centsInChips: false,
            customRange: range)
        let models = UsageDayChartData(
            period: period,
            domain: domain,
            bars: modelBars.filter { includes($0.key) },
            hint: hint,
            legend: split.shownFamilies.map {
                UsageDayChartData.Legend(id: $0.rawValue, name: $0.title, color: .claude($0))
            },
            dayNotes: modelNotes.filter { includes($0.key) },
            emptyText: emptyText,
            chipLimit: nil,
            centsInChips: true,
            customRange: range)
        return (accounts, models)
    }

    /// Claude Code logs on this Mac do not go back forever: the empty part of the chart is not drawn.
    private static func domain(period: UsageSpendPeriod, trackedSince: Date?, now: Date) -> ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var start = calendar.date(byAdding: .day, value: -(period.days - 1), to: today) ?? today
        let shortest = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        if let tracked = trackedSince.map({ calendar.startOfDay(for: $0) }), tracked > start {
            start = min(tracked, shortest)
        }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return start...end
    }

    private static func hint(period: UsageSpendPeriod, domain: ClosedRange<Date>, now: Date) -> String {
        let calendar = Calendar.current
        let asked = calendar.date(byAdding: .day, value: -(period.days - 1), to: calendar.startOfDay(for: now))
        if let asked, domain.lowerBound > asked {
            return "Since \(UsageFormat.format(domain.lowerBound, "MMM d")) · point at a bar or drag to zoom."
        }
        return "Point at a bar; drag across days to zoom in."
    }

    /// The caption of a zoomed chart at rest.
    static let zoomHint = "Double-click the chart or pick a period to zoom out."
}

// MARK: - Shared rows

/// Model row: share bar, tokens, dollars, share of spend.
struct UsageModelRow: View {
    let name: String
    let use: UsageModelUse
    let total: Double
    let color: Color
    /// Provider model names such as "Hydrogen" need more than the default.
    var nameWidth: CGFloat = 36
    /// Cents below $10 ("$0.42"): a single day of a small model.
    var fine: Bool = false
    /// Model has tokens but no API price in the collector: show "no price" instead of "$0".
    var unpriced: Bool = false
    /// Empty day placeholder: hide bar and show em-dashes while preserving row height.
    var placeholder: Bool = false

    /// Room for "Sonnet".
    static let claudeNameWidth: CGFloat = 40

    static let tokensWidth: CGFloat = 42
    static let usdWidth: CGFloat = 50
    static let shareWidth: CGFloat = 30

    private var showsUnpriced: Bool {
        !self.placeholder && self.unpriced && self.use.usd < 0.005 && self.use.tokens > 0
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(self.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: self.nameWidth, alignment: .leading)
            UsageSplitBar(
                parts: self.placeholder ? [] : [(self.use.usd, self.color)],
                scale: max(0.01, self.total))
            Text(self.placeholder ? "—" : UsageFormat.tokens(self.use.tokens))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.tokensWidth, alignment: .trailing)
            if self.placeholder {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.usdWidth, alignment: .trailing)
            } else if self.showsUnpriced {
                Text("no price")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: Self.usdWidth, alignment: .trailing)
            } else {
                Text(self.fine ? UsageFormat.usdFine(self.use.usd) : UsageFormat.usd(self.use.usd))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: Self.usdWidth, alignment: .trailing)
            }
            Text(self.placeholder || self.showsUnpriced
                ? "—"
                : UsageFormat.percent(self.use.usd / max(0.01, self.total) * 100))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.shareWidth, alignment: .trailing)
        }
    }
}

/// Column labels above the model rows.
struct UsageModelHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            UsageSectionLabel(text: self.title)
            Spacer(minLength: 0)
            Group {
                Text("tokens").frame(width: UsageModelRow.tokensWidth, alignment: .trailing)
                Text("cost").frame(width: UsageModelRow.usdWidth, alignment: .trailing)
                Text("share").frame(width: UsageModelRow.shareWidth, alignment: .trailing)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        }
    }
}

/// One line of a "By model" block: a Claude family or a provider's model (or its "Other").
struct UsageModelLine: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let color: UsageSeriesColor
    let use: UsageModelUse
    var unpriced: Bool = false
}

/// The "By model" block of every spend section: column labels, one row per model, and an optional quiet
/// note under them (what "Other" consists of), on one line: the first of `notes` that fits is shown, so the
/// text is never cut in the middle of a word and the block keeps one height.
struct UsageModelRows: View {
    let title: String
    let lines: [UsageModelLine]
    let total: Double
    var nameWidth: CGFloat = UsageModelRow.claudeNameWidth
    /// Longest first; the last one should be short enough to fit any width.
    var notes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            UsageModelHeader(title: self.title)
            ForEach(self.lines) { line in
                UsageModelRow(
                    name: line.label,
                    use: line.use,
                    total: self.total,
                    color: line.color.color,
                    nameWidth: self.nameWidth,
                    unpriced: line.unpriced)
            }
            if !self.notes.isEmpty {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(self.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .fixedSize()
                    }
                    // Nothing fits: the shortest one, cut at its end.
                    Text(self.notes.last ?? "")
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// One row per Claude model: Opus, Fable, Sonnet, Haiku, and "Other" when there is some.
struct UsageModelBlock: View {
    let title: String
    let split: UsageModelSplit
    /// The rows to show; by default the split's own. A block whose period changes in place (the account
    /// panel, measured once) passes the rows of its longest period, so a switch never changes its height.
    var families: [UsageModelFamily]?

    var body: some View {
        UsageModelRows(
            title: self.title,
            lines: (self.families ?? self.split.shownFamilies).map { family in
                UsageModelLine(id: family.rawValue, label: family.title, color: .claude(family), use: self.split[family])
            },
            total: self.split.total.usd)
    }
}
