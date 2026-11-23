import Charts
import SwiftUI

// MARK: - Weeks of the limit chart turned into calendar months

/// One calendar month of one account on the Month chart of "Is the limit changing?".
///
/// Built only from the week values the Week chart draws, so the two positions cannot disagree:
/// - Every measured week covers the seven days before its end, cut at the summary's time (the days of the
///   current week that have not happened are not counted). Each of those days takes the week's value.
/// - A month's average week is the average of its covered days, so a week split between two months counts
///   in both, by its days in each.
/// - The month is that average week × 30.44 / 7 (≈ 4.35), the factor "You get" of the card above uses.
/// - Under half a week of days measured the month is left out (that week belongs to the neighbour month);
///   under two weeks it is preliminary and drawn faded with a solid top edge.
struct UsageDriftMonth: Identifiable, Equatable {
    let account: String
    let colorIndex: Int
    /// "2026-09": the x value of the chart.
    let key: String
    /// The first moment of the month.
    let start: Date
    /// A month of full weekly limits in the chosen unit.
    let usd: Double
    /// Days of the month covered by measured weeks.
    let days: Double
    /// Days the month has (only the days so far for the current month).
    let ofDays: Double
    let current: Bool

    var preliminary: Bool {
        self.days < UsageDriftMonths.finalDays
    }

    var id: String {
        "\(self.account)-\(self.key)"
    }
}

enum UsageDriftMonths {
    /// The same factor as "You get" in the card above (and the collector's `monthOpusUsd`).
    static let weeksPerMonth = 30.44 / 7
    /// Less than this many measured days: the month is not shown.
    static let shownDays = 3.5
    /// Less than this many measured days: the month is preliminary.
    static let finalDays = 14.0

    /// The months of one account's weeks, oldest first. `until` is the time of the summary.
    static func months(
        of points: [UsageDriftPoint],
        until: Date,
        calendar: Calendar = .current) -> [UsageDriftMonth]
    {
        guard let first = points.first else { return [] }
        // Month start → (Σ value × seconds, Σ seconds).
        var sums: [Date: (usd: Double, seconds: Double)] = [:]
        for point in points {
            let from = point.date.addingTimeInterval(-UsageDriftWeek.length)
            let to = min(point.date, until)
            guard to > from, var month = calendar.dateInterval(of: .month, for: from) else { continue }
            while month.start < to {
                let overlap = min(to, month.end).timeIntervalSince(max(from, month.start))
                if overlap > 0 {
                    let sum = sums[month.start] ?? (0, 0)
                    sums[month.start] = (sum.usd + point.usd * overlap, sum.seconds + overlap)
                }
                guard let next = calendar.dateInterval(of: .month, for: month.end) else { break }
                month = next
            }
        }
        let day = 24.0 * 3600
        return sums.keys.sorted().compactMap { start in
            guard let sum = sums[start], sum.seconds / day >= Self.shownDays,
                  let month = calendar.dateInterval(of: .month, for: start)
            else { return nil }
            let current = month.contains(until)
            let ofDays = (current ? until.timeIntervalSince(month.start) : month.duration) / day
            return UsageDriftMonth(
                account: first.account,
                colorIndex: first.colorIndex,
                key: UsageFormat.format(start, "yyyy-MM"),
                start: start,
                usd: sum.usd / sum.seconds * Self.weeksPerMonth,
                days: sum.seconds / day,
                ofDays: max(1, ofDays),
                current: current)
        }
    }
}

struct UsageDriftMonthSeries: Identifiable {
    let id: String
    let name: String
    let colorIndex: Int
    let months: [UsageDriftMonth]
    /// The account has weeks in the chosen unit (it may still have no month with enough of them).
    var hasWeeks = true
}

// MARK: - Month chart with a hover readout

/// Grouped bars, one per account in each month, with the same readout line and legend rows as the
/// Week chart: pointing at a month shows that month's values in the legend rows, so nothing changes height.
/// Bars rather than a line: with three or four months a line is two or three segments and a single
/// month a lone dot, while bars from zero show the size of each month at a glance.
struct UsageDriftMonthChartView: View {
    let series: [UsageDriftMonthSeries]
    @State private var hoveredKey: String?

    init(series: [UsageDriftMonthSeries], initialHoverIndex: Int? = nil) {
        self.series = series
        let keys = Self.keys(series)
        if let index = initialHoverIndex, !keys.isEmpty {
            let fromEnd = min(max(0, index), keys.count - 1)
            self._hoveredKey = State(initialValue: keys[keys.count - 1 - fromEnd])
        }
    }

    private static func keys(_ series: [UsageDriftMonthSeries]) -> [String] {
        Array(Set(series.flatMap { $0.months.map(\.key) })).sorted()
    }

    var body: some View {
        let keys = Self.keys(self.series)
        // After a unit switch a month may be gone ("My mix" needs spend data): a stale hover shows nothing.
        let hovered = self.hoveredKey.flatMap { keys.contains($0) ? $0 : nil }
        VStack(alignment: .leading, spacing: 9) {
            self.chart(keys: keys, hovered: hovered)
            self.readout(hovered)
            VStack(spacing: 4) {
                ForEach(self.series) { series in
                    UsageDriftLegendRow(name: series.name, colorIndex: series.colorIndex) {
                        self.legendValue(series, hovered: hovered)
                    }
                }
            }
        }
    }

    private func month(_ key: String) -> UsageDriftMonth? {
        self.series.lazy.compactMap { $0.months.first { $0.key == key } }.first
    }

    /// One line of fixed height: a hint, or the hovered month.
    private func readout(_ hovered: String?) -> some View {
        Group {
            if let hovered, let month = self.month(hovered) {
                let days = Int(month.ofDays.rounded())
                Text(UsageFormat.format(month.start, "MMMM yyyy") + (month.current
                        ? ", \(days) days so far"
                        : ", \(days) days"))
                    .fontWeight(.semibold)
            } else {
                Text("Point at the chart for a month's values.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13, alignment: .leading)
    }

    @ViewBuilder
    private func legendValue(_ series: UsageDriftMonthSeries, hovered: String?) -> some View {
        if let hovered {
            if let month = series.months.first(where: { $0.key == hovered }) {
                // Short enough for the row next to a long account name: "$13,198 · 13 days, prelim."
                let days = "\(Int(month.days.rounded())) days" + (month.preliminary ? ", prelim." : " measured")
                HStack(spacing: 0) {
                    Text(UsageFormat.usd(month.usd)).fontWeight(.semibold)
                    Text(" · " + days)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("no reading that month")
                    .foregroundStyle(.tertiary)
            }
        } else if let first = series.months.first, let last = series.months.last {
            Text(series.months.count >= 2
                ? "\(UsageFormat.usd(first.usd)) → \(UsageFormat.usd(last.usd)) · \(series.months.count) months"
                : "\(UsageFormat.usd(last.usd)) · " + (last.preliminary
                    ? "\(Int(last.days.rounded())) days, prelim."
                    : "1 month so far"))
                .foregroundStyle(.secondary)
        } else if series.hasWeeks {
            // Every week of this account lies in a month with under half a week measured.
            Text("under half a week so far")
                .foregroundStyle(.tertiary)
        } else {
            Text(UsageDriftSeries.noValueText)
                .foregroundStyle(.tertiary)
        }
    }

    private func chart(keys: [String], hovered: String?) -> some View {
        // Legend order first, so each account keeps its place inside every month's group.
        let bars = self.series.flatMap(\.months)
        // A preliminary bar is faded with a solid top edge: on a dark or warm screen a faded bar alone
        // sinks into the background, the edge keeps where its value is.
        let edge = (bars.map(\.usd).max() ?? 0) * 0.02
        return Chart {
            ForEach(bars) { month in
                let color = UsagePalette.account(month.colorIndex)
                BarMark(
                    x: .value("Month", month.key),
                    y: .value("Dollars", month.usd),
                    width: .ratio(0.85))
                    .position(by: .value("Account", month.account))
                    .foregroundStyle(month.preliminary ? color.opacity(0.4) : color)
                    .cornerRadius(2)
                if month.preliminary {
                    BarMark(
                        x: .value("Month", month.key),
                        yStart: .value("Dollars", max(0, month.usd - edge)),
                        yEnd: .value("Dollars", month.usd),
                        width: .ratio(0.85))
                        .position(by: .value("Account", month.account))
                        .foregroundStyle(color)
                        .cornerRadius(1)
                }
            }
        }
        .chartXScale(domain: keys)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(UsageFormat.usd(amount)).font(.system(size: 9))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let month = self.month(key) {
                        Text(UsageFormat.format(month.start, "MMM"))
                            .font(.system(size: 9, weight: key == hovered ? .semibold : .regular))
                    }
                }
            }
        }
        // The pointed-at month: a band behind its bars, the full height of the plot.
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let hovered, let index = keys.firstIndex(of: hovered), let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    let band = frame.width / CGFloat(keys.count)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: band - 4, height: frame.height)
                        .position(x: frame.minX + band * (CGFloat(index) + 0.5), y: frame.midY)
                }
            }
        }
        // SwiftUI hover is unreliable while an NSMenu tracks the mouse; the AppKit tracker is not.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                UsageMouseTracker { location in
                    self.updateHover(location: location, proxy: proxy, geometry: geometry, keys: keys)
                }
            }
        }
        .frame(height: 130)
        .padding(.trailing, 24)
    }

    /// The month whose band holds the pointer. The whole chart area counts, axis labels included: x is
    /// clamped into the plot, so the first and last months are easy to reach.
    private func updateHover(location: CGPoint?, proxy: ChartProxy, geometry: GeometryProxy, keys: [String]) {
        var key: String?
        if let location, let anchor = proxy.plotFrame, !keys.isEmpty {
            let frame = geometry[anchor]
            let x = min(max(location.x, frame.minX), frame.maxX - 0.5) - frame.minX
            let index = Int(x / (frame.width / CGFloat(keys.count)))
            key = keys[min(max(0, index), keys.count - 1)]
        }
        if self.hoveredKey != key {
            self.hoveredKey = key
        }
    }
}

/// An account row under a limit chart: swatch, name, and a value that the chart fills in.
struct UsageDriftLegendRow<Value: View>: View {
    let name: String
    let colorIndex: Int
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(UsagePalette.account(self.colorIndex))
                .frame(width: 8, height: 8)
            Text(self.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            self.value()
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}
