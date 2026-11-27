import Foundation

// MARK: - A custom span of days, picked by dragging across a per-day spend chart

/// An inclusive span of calendar days ("2026-11-03" through "2026-11-14"), the zoom a drag across a per-day
/// chart picks. Days are the summary's day keys (`UsageDayKey`), so comparing keys as strings compares days.
/// Not saved anywhere: a zoom lives until a period button, the ✕ on the range chip or a double click.
public struct UsageSpendRange: Equatable, Hashable, Sendable {
    /// First day, inclusive.
    public let startDay: String
    /// Last day, inclusive; never before `startDay`.
    public let endDay: String
    /// Midnight of `startDay`, local time.
    public let startDate: Date
    /// Midnight of `endDay`, local time.
    public let endDate: Date

    /// The two days in either order; nil when either is not a day key.
    public init?(startDay: String, endDay: String) {
        let first = min(startDay, endDay)
        let last = max(startDay, endDay)
        guard let start = UsageDayKey.date(first), let end = UsageDayKey.date(last) else { return nil }
        self.startDay = first
        self.endDay = last
        self.startDate = start
        self.endDate = end
    }

    /// The calendar days of two moments, in either order.
    public init?(startDate: Date, endDate: Date) {
        self.init(startDay: UsageDayKey.string(startDate), endDay: UsageDayKey.string(endDate))
    }

    /// Calendar days in the span, both ends counted; at least 1.
    public var dayCount: Int {
        let days = Calendar.current.dateComponents([.day], from: self.startDate, to: self.endDate).day ?? 0
        return max(1, days + 1)
    }

    /// The chart's x domain: from the first midnight to the midnight after the last day, as the preset
    /// periods' domains (bars are drawn with the `.day` unit).
    public var domain: ClosedRange<Date> {
        let after = Calendar.current.date(byAdding: .day, value: 1, to: self.endDate) ?? self.endDate
        return self.startDate...max(self.startDate, after)
    }

    /// "Nov 3 – Nov 14"; across a new year "Dec 28, 2025 – Jan 4, 2026"; one day "Nov 3".
    public var shortTitle: String {
        if self.startDay == self.endDay {
            return UsageFormat.format(self.startDate, "MMM d")
        }
        let calendar = Calendar.current
        if calendar.component(.year, from: self.startDate) == calendar.component(.year, from: self.endDate) {
            return "\(UsageFormat.format(self.startDate, "MMM d")) – \(UsageFormat.format(self.endDate, "MMM d"))"
        }
        return "\(UsageFormat.format(self.startDate, "MMM d, yyyy")) – \(UsageFormat.format(self.endDate, "MMM d, yyyy"))"
    }

    /// Compact form for the range chip next to the period switcher: "Dec 28 '25 – Jan 4 '26" across a new year,
    /// otherwise identical to `shortTitle`.
    public var compactTitle: String {
        if self.startDay == self.endDay {
            return UsageFormat.format(self.startDate, "MMM d")
        }
        let calendar = Calendar.current
        if calendar.component(.year, from: self.startDate) == calendar.component(.year, from: self.endDate) {
            return self.shortTitle
        }
        return "\(UsageFormat.format(self.startDate, "MMM d ''yy"))–\(UsageFormat.format(self.endDate, "MMM d ''yy"))"
    }

    /// Whether the day key lies inside the span.
    public func contains(_ dayKey: String) -> Bool {
        dayKey >= self.startDay && dayKey <= self.endDay
    }

    /// The smallest preset period that covers the span (the longest when none does): what the span stands in
    /// for where a preset period is needed (an account's spans, row layout).
    var coveringPeriod: UsageSpendPeriod {
        UsageSpendPeriod.allCases.first { $0.days >= self.dayCount } ?? .d180
    }
}

extension UsageSpendRange {
    /// Calendar days of a chart domain (its upper bound is the midnight after its last day).
    static func dayCount(of domain: ClosedRange<Date>) -> Int {
        max(1, Calendar.current.dateComponents([.day], from: domain.lowerBound, to: domain.upperBound).day ?? 1)
    }

    /// The days of a chart domain as a range: first day to the day before the upper bound.
    static func of(domain: ClosedRange<Date>) -> UsageSpendRange? {
        let last = Calendar.current.date(byAdding: .day, value: -1, to: domain.upperBound) ?? domain.upperBound
        return UsageSpendRange(startDate: domain.lowerBound, endDate: max(domain.lowerBound, last))
    }
}

extension UsagePanelState.Account {
    /// My spend on the days of `range`.
    public func split(in range: UsageSpendRange) -> UsageModelSplit {
        var split = UsageModelSplit()
        for day in self.daily ?? [] where range.contains(day.day) {
            split.add(day.split)
        }
        return split
    }
}
