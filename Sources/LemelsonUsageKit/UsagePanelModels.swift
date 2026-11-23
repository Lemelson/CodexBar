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

// MARK: - Shared rows

/// Model row: share bar, tokens, dollars, share of spend.
struct UsageModelRow: View {
    let name: String
    let use: UsageModelUse
    let total: Double
    let color: Color

    static let tokensWidth: CGFloat = 42
    static let usdWidth: CGFloat = 50
    static let shareWidth: CGFloat = 30

    var body: some View {
        HStack(spacing: 6) {
            Text(self.name)
                .font(.system(size: 11))
                .frame(width: 36, alignment: .leading)
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
    @State private var otherHovered = false

    var body: some View {
        let total = self.split.total.usd
        VStack(alignment: .leading, spacing: 5) {
            UsageModelHeader(title: self.title)
            UsageModelRow(name: "Opus", use: self.split[.opus], total: total, color: UsagePalette.opus)
            UsageModelRow(name: "Fable", use: self.split[.fable], total: total, color: UsagePalette.fable)
            UsageModelRow(name: "Other", use: self.split.minor, total: total, color: UsagePalette.others)
                .overlay {
                    UsageMouseTracker { location in
                        let inside = location != nil
                        if self.otherHovered != inside {
                            self.otherHovered = inside
                        }
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
}
