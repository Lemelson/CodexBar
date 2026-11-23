import Charts
import SwiftUI

// MARK: - What the subscription is worth at API prices

/// "What I pay vs. what I get": the subscription price next to what the same volume would cost through the API.
public struct UsageValueCardView: View {
    let state: UsagePanelState
    let width: CGFloat
    let now: Date
    @State private var period: Period = .month

    public init(state: UsagePanelState, width: CGFloat, now: Date = Date()) {
        self.state = state
        self.width = width
        self.now = now
    }

    enum Period: String, CaseIterable, Identifiable {
        case month = "Month"
        case week = "Week"

        var id: String {
            self.rawValue
        }
    }

    private static let weeksPerMonth = 30.44 / 7

    private func got(_ account: UsagePanelState.Account) -> Double? {
        guard let value = account.value else { return nil }
        return self.period == .month ? value.monthOpusUsd : value.weekOpusUsd
    }

    private func paid(_ account: UsagePanelState.Account) -> Double? {
        guard let price = account.planPriceUsd else { return nil }
        return self.period == .month ? price : price / Self.weeksPerMonth
    }

    public var body: some View {
        let scale = max(1, self.state.accounts.compactMap { self.got($0) }.max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("What the plan is worth")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                Picker("Period", selection: self.$period) {
                    ForEach(Period.allCases) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            UsageNote(text: "The same usage bought through the API at list prices, if the limit is used up.")
            ForEach(self.state.orderedAccounts) { account in
                self.block(for: account, scale: scale)
            }
            UsageNote(text: self.footnote)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }

    private var footnote: String {
        var text = "Measured, not fitted: the fewest of your API dollars that ever moved the limit by 1%."
        if self.state.kFable != nil || self.state.accounts.contains(where: { $0.kFable != nil }) {
            text += " $1 of Fable uses the weekly limit like $\(self.state.fableWeightText) of Opus"
                + (self.state.fableWeightText.contains("–") ? ", depending on the account." : ".")
        }
        let minor = self.state.split(lastDays: 180, now: self.now)
        text += " Sonnet and Haiku can't be rated yet: \(UsageFormat.usd(minor[.sonnet].usd)) and "
            + "\(UsageFormat.usd(minor[.haiku].usd)) of them here is too little to move a limit by 1%."
        return text
    }

    @ViewBuilder
    private func block(for account: UsagePanelState.Account, scale: Double) -> some View {
        let color = UsagePalette.account(self.state.colorIndex(of: account))
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(account.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let plan = account.planName {
                    Text(plan)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if let times = account.value?.timesPrice {
                    Text(UsageFormat.times(times))
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                }
            }
            if let got = self.got(account) {
                if let paid = self.paid(account) {
                    self.bar("You pay", value: paid, scale: scale, color: Color.secondary.opacity(0.7), strong: false)
                }
                self.bar("You get", value: got, scale: scale, color: color, strong: true)
                if let value = account.value, let week = value.weekOpusUsd {
                    self.models(value, account: account, week: week)
                }
            } else {
                UsageNote(text: "No estimate yet: it needs a few limit readings of this account.")
            }
        }
    }

    private func bar(_ label: String, value: Double, scale: Double, color: Color, strong: Bool) -> some View {
        UsageValueBar(label: label, value: value, scale: scale, color: color, strong: strong)
    }

    /// The same weekly limit spent on a single model, and what I actually used over 30 days.
    private func models(
        _ value: UsagePanelState.Value,
        account: UsagePanelState.Account,
        week: Double) -> some View
    {
        let scale = self.period == .month ? Self.weeksPerMonth : 1
        let weekPrice = (account.planPriceUsd ?? 0) / Self.weeksPerMonth
        let allFable = value.weekAllFableUsd ?? week / max(1, self.state.fableWeight(for: account))
        let cap = min(allFable, value.weekFableCapUsd ?? allFable)
        let usedWeek = account.split(lastDays: 30, now: self.now).total.usd / 30 * 7
        let fable = UsagePalette.fable
        let capNote = weekPrice > 0 && cap < allFable ? ", cap \(UsageFormat.times(cap / weekPrice))" : ""
        // The last row is always measured over the last 30 days. Month shows that total, Week shows
        // its weekly average, so the label names which one it is. Both fit the 104 pt label column unscaled.
        let usedLabel = self.period == .month ? "Real use, 30 days" : "Real use, week avg"
        let rows: [(String, [(Double, Color)], Double)] = [
            ("Opus only", [(week, UsagePalette.opus)], week),
            ("Fable only" + capNote, [(cap, fable), (allFable - cap, fable.opacity(0.35))], allFable),
            (usedLabel, [(usedWeek, UsagePalette.account(self.state.colorIndex(of: account)))], usedWeek),
        ]
        return VStack(alignment: .leading, spacing: 3) {
            // The first two rows are a ceiling (the whole limit on one model), the last one is what was
            // actually used; the caption names both so "real use" is not read as a third model.
            Text("Most the limit can buy on one model, and your real use")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.top, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.0)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: 104, alignment: .leading)
                    UsageSplitBar(parts: row.1, scale: max(1, week), height: 5)
                    Text(weekPrice > 0 ? UsageFormat.times(row.2 / weekPrice) : "")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .frame(width: 30, alignment: .trailing)
                    Text(UsageFormat.usd(row.2 * scale))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
    }
}

/// "You pay" / "You get": a labelled bar on a common scale with the amount; the strong one is an estimate.
struct UsageValueBar: View {
    let label: String
    let value: Double
    let scale: Double
    let color: Color
    let strong: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(self.label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            UsageSplitBar(parts: [(self.value, self.color)], scale: self.scale, height: self.strong ? 9 : 5)
            Text((self.strong ? "≈ " : "") + UsageFormat.usd(self.value))
                .font(.system(size: 11, weight: self.strong ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
    }
}

// MARK: - Does the weekly limit change

/// Weekly limit capacity by week. The switcher shows the same measured limit
/// in three units: Opus dollars, dollars at my actual model mix, and Fable dollars.
public struct UsageDriftCardView: View {
    let state: UsagePanelState
    let width: CGFloat
    /// Only for the PNG preview, which cannot move a pointer: draws the chart as if this week were
    /// pointed at (0 is the latest week, 1 the one before, ...). Nil in the app.
    let initialHoverIndex: Int?
    @State private var unit: Unit = .opus

    public init(state: UsagePanelState, width: CGFloat, initialHoverIndex: Int? = nil) {
        self.state = state
        self.width = width
        self.initialHoverIndex = initialHoverIndex
    }

    enum Unit: String, CaseIterable, Identifiable {
        case opus = "Opus $"
        case mix = "My mix"
        case fable = "Fable $"

        var id: String {
            self.rawValue
        }
    }

    private typealias Point = UsageDriftPoint

    /// How many dollars 100 % of the week holds in the selected unit, at this account's Fable/Opus ratio.
    private func capacity(_ point: UsagePanelState.DriftPoint, ratio: Double) -> Double? {
        switch self.unit {
        case .opus:
            return point.usdPer100
        case .fable:
            return point.usdPer100 / ratio
        case .mix:
            guard let spend = point.spend, spend.total > 0 else { return nil }
            let weighted = (spend.opus ?? 0) + (spend.other ?? 0) + ratio * (spend.fable ?? 0)
            return weighted > 0 ? point.usdPer100 * spend.total / weighted : nil
        }
    }

    private func points(for account: UsagePanelState.Account) -> [Point] {
        (account.drift ?? []).compactMap { item in
            guard let usd = self.capacity(item, ratio: self.state.fableWeight(for: account)) else { return nil }
            return Point(
                account: account.displayName,
                colorIndex: self.state.colorIndex(of: account),
                date: Date(timeIntervalSince1970: item.weekEnd),
                usd: usd)
        }
    }

    private var caption: String {
        let ratio = self.state.fableWeightText
        switch self.unit {
        case .opus:
            return "100% of the week in Opus-equivalent dollars: $1 of Fable counts as $\(ratio) of Opus, "
                + "so a Fable-heavy week does not look like a smaller limit."
        case .mix:
            return "Real API dollars a full week held at the Opus/Fable mix you actually used that week. "
                + "More Fable means fewer dollars for the same limit."
        case .fable:
            return "The same limit if it were spent on Fable only (Opus dollars ÷ \(ratio)). "
                + "Fable also has its own weekly cap."
        }
    }

    private var ratioNote: String {
        let parts = self.state.accounts.map { account -> String in
            let ratio = String(format: "%.2f", self.state.fableWeight(for: account))
            let how = switch account.kSource {
            case "share": "from the server's Fable cap share"
            case "pure": "from stretches with one model"
            case "fit": "fitted on mixed stretches"
            case "pooled": account.kFrom.map { "borrowed from \($0)" } ?? "borrowed"
            default: "default, not measured yet"
            }
            return "\(account.displayName) ×\(ratio) (\(how))"
        }
        return "Fable/Opus ratio per account: " + parts.joined(separator: ", ") + "."
    }

    public var body: some View {
        let points = self.state.accounts.flatMap { self.points(for: $0) }
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Is the weekly limit changing?")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            Picker("Unit", selection: self.$unit) {
                ForEach(Unit.allCases) { unit in
                    Text(unit.rawValue).tag(unit)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            Text(self.caption)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(height: 40, alignment: .topLeading)
            if points.isEmpty {
                UsageNote(text: "Not enough readings yet: it needs at least one full week.")
            } else {
                UsageDriftChartView(
                    points: points,
                    series: self.series,
                    initialHoverIndex: self.initialHoverIndex)
            }
            UsageNote(text: self.ratioNote)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }

    /// Legend order (the panel's account order), only accounts that have at least one week on the chart.
    private var series: [UsageDriftSeries] {
        self.state.orderedAccounts.compactMap { account in
            let points = self.points(for: account)
            guard !points.isEmpty else { return nil }
            return UsageDriftSeries(
                id: account.id,
                name: account.displayName,
                colorIndex: self.state.colorIndex(of: account),
                points: points)
        }
    }
}

// MARK: - Drift chart with a hover readout

struct UsageDriftPoint: Identifiable {
    let account: String
    let colorIndex: Int
    let date: Date
    let usd: Double

    var id: String {
        "\(self.account)-\(self.date.timeIntervalSince1970)"
    }
}

struct UsageDriftSeries: Identifiable {
    let id: String
    let name: String
    let colorIndex: Int
    let points: [UsageDriftPoint]
}

/// One week on the chart. Accounts reset on their own day and hour, so the same calendar week has
/// slightly different week ends per account (e.g. Sun 13:00 and Mon 11:00); they are grouped together.
struct UsageDriftWeek: Equatable {
    /// The latest week end in the group: the rule is drawn here and the range ends here.
    let end: Date
    let pointIDs: Set<String>

    static let length: TimeInterval = 7 * 24 * 3600

    /// Points whose week ends lie within half a week of the group's first one belong to the same week.
    static func group(_ points: [UsageDriftPoint]) -> [UsageDriftWeek] {
        var weeks: [(first: Date, end: Date, ids: Set<String>)] = []
        for point in points.sorted(by: { $0.date < $1.date }) {
            if let last = weeks.last, point.date.timeIntervalSince(last.first) <= Self.length / 2 {
                weeks[weeks.count - 1].end = point.date
                weeks[weeks.count - 1].ids.insert(point.id)
            } else {
                weeks.append((point.date, point.date, [point.id]))
            }
        }
        return weeks.map { UsageDriftWeek(end: $0.end, pointIDs: $0.ids) }
    }
}

/// The chart, a one-line readout and the legend. The hovered week is local state here, so moving the
/// pointer redraws only this part, not the card with the unit switcher, caption and ratio note.
/// While a week is pointed at, the legend rows show that week's value instead of first → last:
/// the per-account numbers reuse lines that are always there, so only the readout line is extra
/// and the menu item never changes height.
struct UsageDriftChartView: View {
    let points: [UsageDriftPoint]
    let series: [UsageDriftSeries]
    @State private var hoveredEnd: Date?

    init(points: [UsageDriftPoint], series: [UsageDriftSeries], initialHoverIndex: Int? = nil) {
        self.points = points
        self.series = series
        let weeks = UsageDriftWeek.group(points)
        if let index = initialHoverIndex, !weeks.isEmpty {
            let fromEnd = min(max(0, index), weeks.count - 1)
            self._hoveredEnd = State(initialValue: weeks[weeks.count - 1 - fromEnd].end)
        }
    }

    var body: some View {
        let weeks = UsageDriftWeek.group(self.points)
        // After a unit switch some weeks may be gone ("My mix" needs spend data): a stale hover shows nothing.
        let hovered = weeks.first { $0.end == self.hoveredEnd }
        VStack(alignment: .leading, spacing: 9) {
            self.chart(weeks: weeks, hovered: hovered)
            self.readout(hovered)
            VStack(spacing: 4) {
                ForEach(self.series) { series in
                    self.legendRow(series, hovered: hovered)
                }
            }
        }
    }

    /// One line of fixed height: a hint, or the hovered week's range.
    private func readout(_ hovered: UsageDriftWeek?) -> some View {
        Group {
            if let hovered {
                let end = hovered.end.timeIntervalSince1970
                Text("Week \(UsageFormat.dayRange(end - UsageDriftWeek.length, end))")
                    .fontWeight(.semibold)
            } else {
                Text("Point at the chart for a week's values.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13, alignment: .leading)
    }

    private func legendRow(_ series: UsageDriftSeries, hovered: UsageDriftWeek?) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(UsagePalette.account(series.colorIndex))
                .frame(width: 8, height: 8)
            Text(series.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 6)
            self.legendValue(series, hovered: hovered)
                .font(.system(size: 11))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func legendValue(_ series: UsageDriftSeries, hovered: UsageDriftWeek?) -> some View {
        if let hovered {
            if let point = series.points.last(where: { hovered.pointIDs.contains($0.id) }) {
                Text(UsageFormat.usd(point.usd))
                    .fontWeight(.semibold)
            } else {
                Text("no reading that week")
                    .foregroundStyle(.tertiary)
            }
        } else if let first = series.points.first, let last = series.points.last {
            Text(series.points.count >= 2
                ? "\(UsageFormat.usd(first.usd)) → \(UsageFormat.usd(last.usd)) · \(series.points.count) weeks"
                : "\(UsageFormat.usd(last.usd)) · 1 week so far")
                .foregroundStyle(.secondary)
        }
    }

    private func chart(weeks: [UsageDriftWeek], hovered: UsageDriftWeek?) -> some View {
        Chart {
            // Drawn first so the lines and points stay on top of it.
            if let hovered {
                RuleMark(x: .value("Week", hovered.end))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
            ForEach(self.points) { point in
                let hot = hovered?.pointIDs.contains(point.id) == true
                LineMark(
                    x: .value("Week", point.date),
                    y: .value("Dollars", point.usd),
                    series: .value("Account", point.account))
                    .foregroundStyle(UsagePalette.account(point.colorIndex))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(
                    x: .value("Week", point.date),
                    y: .value("Dollars", point.usd))
                    .foregroundStyle(UsagePalette.account(point.colorIndex))
                    .symbolSize(hot ? 80 : 24)
            }
        }
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
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(UsageFormat.format(date, "MMM d")).font(.system(size: 9))
                    }
                }
            }
        }
        .chartXScale(range: .plotDimension(startPadding: 6, endPadding: 6))
        // SwiftUI hover is unreliable while an NSMenu tracks the mouse; the AppKit tracker is not.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                UsageMouseTracker { location in
                    self.updateHover(location: location, proxy: proxy, geometry: geometry, weeks: weeks)
                }
            }
        }
        .frame(height: 130)
        .padding(.trailing, 24)
    }

    /// Snaps to the nearest week. The whole chart area counts, axis labels included: x is clamped into
    /// the plot, so the first and last weeks are easy to reach.
    private func updateHover(location: CGPoint?, proxy: ChartProxy, geometry: GeometryProxy, weeks: [UsageDriftWeek]) {
        var end: Date?
        if let location, let anchor = proxy.plotFrame {
            let frame = geometry[anchor]
            let x = min(max(location.x, frame.minX), frame.maxX) - frame.minX
            if let date = proxy.value(atX: x, as: Date.self) {
                end = weeks.min {
                    abs($0.end.timeIntervalSince(date)) < abs($1.end.timeIntervalSince(date))
                }?.end
            }
        }
        if self.hoveredEnd != end {
            self.hoveredEnd = end
        }
    }
}
