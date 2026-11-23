import SwiftUI

// MARK: - Models: Opus and Fable in view, the rest collapsed into "Other"

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

    /// Everything the panel collapses into a single "Other" row.
    public static let minor: [UsageModelFamily] = [.sonnet, .haiku, .other]
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

    /// Sonnet, Haiku and the rest as one sum.
    public var minor: UsageModelUse {
        UsageModelFamily.minor.reduce(UsageModelUse()) { $0 + self[$1] }
    }

    /// What "Other" consists of: "Haiku $48 · 528M tok   Sonnet $102 · 352M tok".
    public var minorText: String {
        let rows = UsageModelFamily.minor
            .map { ($0, self[$0]) }
            .filter { $0.1.tokens > 0 || $0.1.usd >= 0.005 }
            .sorted { $0.1.tokens > $1.1.tokens }
        guard !rows.isEmpty else { return "No Sonnet or Haiku here." }
        return rows
            .map { "\($0.0.title) \(UsageFormat.usdFine($0.1.usd)) · \(UsageFormat.tokens($0.1.tokens)) tok" }
            .joined(separator: "   ")
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

/// A choice shared by the spend card, the account rows and the detail panel: one period for the whole menu.
@MainActor
public final class UsagePanelSelection: ObservableObject {
    public static let shared = UsagePanelSelection()
    private static let periodKey = "lemelsonSpendPeriod"

    @Published public var spendPeriod: UsageSpendPeriod {
        didSet {
            UserDefaults.standard.set(self.spendPeriod.rawValue, forKey: Self.periodKey)
        }
    }

    private init() {
        self.spendPeriod = UsageSpendPeriod(rawValue: UserDefaults.standard.integer(forKey: Self.periodKey)) ?? .d30
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

    /// What one period shows: the chart (range, bars, hint, legend) and the whole-period split.
    public struct Period: Sendable, Equatable {
        public let period: UsageSpendPeriod
        let chart: UsageDayChartData
        let whole: UsageModelSplit
    }

    public let today: UsageModelSplit
    public let week: UsageModelSplit
    let legend: [Legend]
    private let periods: [Period]
    private let accounts: [String: UsageSpendAccountTotals]

    public init(state: UsagePanelState, now: Date) {
        let totals = state.accounts.map { UsageSpendAccountTotals(account: $0, now: now) }
        // Summed in account order, as `UsagePanelState.split(lastDays:)` does.
        func whole(_ days: Int) -> UsageModelSplit {
            totals.reduce(into: UsageModelSplit()) { $0.add($1.split(lastDays: days)) }
        }
        self.today = whole(1)
        self.week = whole(7)
        self.legend = state.accounts.map { account in
            Legend(id: account.id, name: account.displayName, colorIndex: state.colorIndex(of: account))
        }
        var byID: [String: UsageSpendAccountTotals] = [:]
        for (account, total) in zip(state.accounts, totals) {
            byID[account.id] = total
        }
        self.accounts = byID

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
        let trackedSince = state.trackedSince
        let legend = self.legend.map { UsageDayChartData.Legend(id: $0.id, name: $0.name, color: .account($0.colorIndex)) }
        self.periods = UsageSpendPeriod.allCases.map { period in
            let domain = Self.domain(period: period, trackedSince: trackedSince, now: now)
            let from = UsageDayKey.string(domain.lowerBound)
            let bars = allBars.filter { $0.key >= from }
            // The grey part of a pointed-at day: that day's Opus and Fable over all accounts.
            var sums: [String: (opus: Double, fable: Double)] = [:]
            for bar in bars {
                let sum = sums[bar.key] ?? (0, 0)
                sums[bar.key] = (sum.opus + bar.opus, sum.fable + bar.fable)
            }
            let chart = UsageDayChartData(
                period: period,
                domain: domain,
                bars: bars.map {
                    UsageDayChartData.Bar(key: $0.key, date: $0.date, series: $0.account, color: .account($0.colorIndex),
                                          usd: $0.usd)
                },
                hint: Self.hint(period: period, domain: domain, now: now),
                legend: legend,
                dayNotes: sums.mapValues { "Opus \(UsageFormat.usd($0.opus)) · Fable \(UsageFormat.usd($0.fable))" },
                emptyText: "No Claude Code spend on this Mac in this period.",
                chipLimit: nil,
                centsInChips: false)
            return Period(period: period, chart: chart, whole: whole(period.days))
        }
    }

    public subscript(period: UsageSpendPeriod) -> Period {
        self.periods.first { $0.period == period } ?? self.periods[0]
    }

    public func totals(for account: UsagePanelState.Account) -> UsageSpendAccountTotals? {
        self.accounts[account.id]
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
            return "Per day since \(UsageFormat.format(domain.lowerBound, "MMM d")), the first day on record. "
                + "Point at a bar."
        }
        return "Per day. Point at a bar for that day."
    }
}

// MARK: - Shared rows

/// Model row: share bar, tokens, dollars, share of spend.
struct UsageModelRow: View {
    let name: String
    let use: UsageModelUse
    let total: Double
    let color: Color
    /// Claude's "Opus" / "Fable" / "Other" fit 36 pt; Gemini names such as "Hydrogen" need more.
    var nameWidth: CGFloat = 36

    static let tokensWidth: CGFloat = 42
    static let usdWidth: CGFloat = 50
    static let shareWidth: CGFloat = 30

    var body: some View {
        HStack(spacing: 6) {
            Text(self.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(width: self.nameWidth, alignment: .leading)
            UsageSplitBar(parts: [(self.use.usd, self.color)], scale: max(0.01, self.total))
            Text(UsageFormat.tokens(self.use.tokens))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Self.tokensWidth, alignment: .trailing)
            Text(UsageFormat.usd(self.use.usd))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(width: Self.usdWidth, alignment: .trailing)
            Text(UsageFormat.percent(self.use.usd / max(0.01, self.total) * 100))
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

/// The three main rows and the "Other" breakdown on hover (or always, if `expanded`).
struct UsageModelBlock: View {
    let title: String
    let split: UsageModelSplit
    var expanded = false
    /// Set when the block is one of the stacked period layers: only the visible layer may track the mouse,
    /// because a tracking area ignores SwiftUI opacity and hit testing.
    var trackingPeriod: UsageSpendPeriod?
    @State private var otherHovered = false

    var body: some View {
        let total = self.split.total.usd
        VStack(alignment: .leading, spacing: 5) {
            UsageModelHeader(title: self.title)
            UsageModelRow(name: "Opus", use: self.split[.opus], total: total, color: UsagePalette.opus)
            UsageModelRow(name: "Fable", use: self.split[.fable], total: total, color: UsagePalette.fable)
            UsageModelRow(name: "Other", use: self.split.minor, total: total, color: UsagePalette.others)
                .overlay {
                    // An expanded block always shows the breakdown: hovering would change nothing.
                    if !self.expanded {
                        self.otherTracker
                    }
                }
            Text(self.expanded || self.otherHovered
                ? self.split.minorText
                : "Other is Sonnet and Haiku (subagents). Point at it for the split.")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    @ViewBuilder private var otherTracker: some View {
        let onMoved: (CGPoint?) -> Void = { location in
            let inside = location != nil
            if self.otherHovered != inside {
                self.otherHovered = inside
            }
        }
        if let period = self.trackingPeriod {
            UsageSpendActiveTracker(period: period, onMoved: onMoved)
        } else {
            UsageMouseTracker(onMoved: onMoved)
        }
    }
}
