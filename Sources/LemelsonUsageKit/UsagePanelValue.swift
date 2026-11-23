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
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            UsageSplitBar(parts: [(value, color)], scale: scale, height: strong ? 9 : 5)
            Text((strong ? "≈ " : "") + UsageFormat.usd(value))
                .font(.system(size: 11, weight: strong ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
        }
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
        let rows: [(String, [(Double, Color)], Double)] = [
            ("Opus only", [(week, UsagePalette.opus)], week),
            ("Fable only" + capNote, [(cap, fable), (allFable - cap, fable.opacity(0.35))], allFable),
            ("You used, 30 days", [(usedWeek, UsagePalette.account(self.state.colorIndex(of: account)))], usedWeek),
        ]
        return VStack(alignment: .leading, spacing: 3) {
            Text("The same limit spent on one model, and what you really took")
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

// MARK: - Does the weekly limit change

/// Weekly limit capacity by week. The switcher shows the same measured limit
/// in three units: Opus dollars, dollars at my actual model mix, and Fable dollars.
public struct UsageDriftCardView: View {
    let state: UsagePanelState
    let width: CGFloat
    @State private var unit: Unit = .opus

    public init(state: UsagePanelState, width: CGFloat) {
        self.state = state
        self.width = width
    }

    enum Unit: String, CaseIterable, Identifiable {
        case opus = "Opus $"
        case mix = "My mix"
        case fable = "Fable $"

        var id: String {
            self.rawValue
        }
    }

    private struct Point: Identifiable {
        let account: String
        let colorIndex: Int
        let date: Date
        let usd: Double

        var id: String {
            "\(self.account)-\(self.date.timeIntervalSince1970)"
        }
    }

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
                self.chart(points: points)
                VStack(spacing: 4) {
                    ForEach(self.state.orderedAccounts) { account in
                        self.legendRow(for: account)
                    }
                }
            }
            UsageNote(text: self.ratioNote)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }

    @ViewBuilder
    private func legendRow(for account: UsagePanelState.Account) -> some View {
        let points = self.points(for: account)
        if let first = points.first, let last = points.last {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(UsagePalette.account(self.state.colorIndex(of: account)))
                    .frame(width: 8, height: 8)
                Text(account.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(points.count >= 2
                    ? "\(UsageFormat.usd(first.usd)) → \(UsageFormat.usd(last.usd)) · \(points.count) weeks"
                    : "\(UsageFormat.usd(last.usd)) · 1 week so far")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chart(points: [Point]) -> some View {
        Chart(points) { point in
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
                .symbolSize(24)
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
        .frame(height: 130)
        .padding(.trailing, 24)
    }
}
