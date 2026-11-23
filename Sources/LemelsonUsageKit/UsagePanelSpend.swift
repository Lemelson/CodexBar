import Charts
import SwiftUI

// MARK: - Spend on this Mac: totals and per-day chart

/// Readable replacement for the "This Mac" block: three totals, spend per day (each account in its own color) and models.
/// The period is chosen with 30/60/90/180-day buttons; hovering a day shows its total.
///
/// Switching the period must feel instant, so nothing is rebuilt on a switch: all numbers come precomputed
/// in `UsageSpendDigest`, every period's chart is laid out once in a stack, and the switch only flips which
/// layer is visible. Only small leaf views observe the shared selection.
public struct UsageSpendSummaryView: View {
    let spend: UsageSpendDigest
    let width: CGFloat

    public init(state: UsagePanelState, now: Date, width: CGFloat, spend: UsageSpendDigest? = nil) {
        self.spend = spend ?? UsageSpendDigest(state: state, now: now)
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            UsageSpendSummaryHeader(spend: self.spend)
            UsageSpendPeriodStack(spend: self.spend)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }
}

/// Title, period picker and the three totals. Cheap to rebuild, so it may observe the selection directly.
struct UsageSpendSummaryHeader: View {
    let spend: UsageSpendDigest
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let period = self.selection.spendPeriod
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                Text("This Mac · API prices")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Picker("Period", selection: self.$selection.spendPeriod) {
                    ForEach(UsageSpendPeriod.allCases) { period in
                        Text(period.short).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            HStack(alignment: .top, spacing: 8) {
                self.tile("Today", self.spend.today.total)
                self.tile("Last 7 days", self.spend.week.total)
                self.tile(period.title, self.spend[period].whole.total)
            }
        }
    }

    private func tile(_ title: String, _ use: UsageModelUse) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(UsageFormat.usd(use.usd))
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(UsageFormat.tokens(use.tokens)) tokens")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// All four periods stacked, one visible. The layers are equatable and do not observe the selection,
/// so a switch re-evaluates only this stack and the opacity of two layers, never a chart.
/// Every layer has the same fixed-height parts, so the stack (and the cached menu row height) never
/// depends on the period.
struct UsageSpendPeriodStack: View {
    let spend: UsageSpendDigest
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let chosen = self.selection.spendPeriod
        ZStack(alignment: .topLeading) {
            ForEach(UsageSpendPeriod.allCases) { period in
                let shown = period == chosen
                UsageSpendPeriodLayer(data: self.spend[period], legend: self.spend.legend)
                    .equatable()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
    }
}

/// One period: caption, chart and models. Pure data in, so `.equatable()` skips it on a switch.
struct UsageSpendPeriodLayer: View, Equatable {
    let data: UsageSpendDigest.Period
    let legend: [UsageSpendDigest.Legend]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Hover state lives inside the chart view, so pointing at bars does not rebuild the models below.
            UsageSpendDayChart(data: self.data, legend: self.legend)
            UsageModelBlock(
                title: "By model · \(self.data.period.short)",
                split: self.data.whole,
                trackingPeriod: self.data.period)
        }
    }
}

/// Caption and per-day chart of one period; owns the hovered day.
struct UsageSpendDayChart: View {
    let data: UsageSpendDigest.Period
    let legend: [UsageSpendDigest.Legend]
    @State private var hoveredDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            self.caption
            if self.data.bars.isEmpty {
                UsageNote(text: "No Claude Code spend on this Mac in this period.")
                    .frame(height: 104, alignment: .topLeading)
            } else {
                self.chart
            }
        }
    }

    /// Two lines of fixed height: hovering changes the text, not the menu item height.
    private var caption: some View {
        let hovered = self.hoveredDay.map { key in self.data.bars.filter { $0.key == key } } ?? []
        return VStack(alignment: .leading, spacing: 3) {
            if let first = hovered.first {
                let total = hovered.reduce(0) { $0 + $1.usd }
                let opus = hovered.reduce(0) { $0 + $1.opus }
                let fable = hovered.reduce(0) { $0 + $1.fable }
                (Text(UsageFormat.format(first.date, "EEE, MMM d")).fontWeight(.semibold)
                    + Text(" · \(UsageFormat.usd(total))").fontWeight(.semibold)
                    + Text("  Opus \(UsageFormat.usd(opus)) · Fable \(UsageFormat.usd(fable))")
                    .foregroundStyle(.secondary))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .lineLimit(1)
                HStack(spacing: 10) {
                    ForEach(hovered) { bar in
                        UsageChip(
                            color: UsagePalette.account(bar.colorIndex),
                            text: "\(bar.account) \(UsageFormat.usd(bar.usd))")
                    }
                }
            } else {
                Text(self.data.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 10) {
                    ForEach(self.legend) { account in
                        UsageChip(color: UsagePalette.account(account.colorIndex), text: account.name)
                    }
                }
            }
        }
        .frame(height: 30, alignment: .topLeading)
    }

    private var chart: some View {
        Chart(self.data.bars) { bar in
            BarMark(
                x: .value("Day", bar.date, unit: .day),
                y: .value("Dollars", bar.usd))
                .foregroundStyle(UsagePalette.account(bar.colorIndex))
                .opacity(self.hoveredDay == nil || self.hoveredDay == bar.key ? 1 : 0.4)
        }
        .chartXScale(domain: self.data.domain)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
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
        .chartOverlay { proxy in
            GeometryReader { geometry in
                // The tracker leaf decides by itself whether this period is visible, so the chart
                // does not depend on the selection and is not rebuilt when it changes.
                UsageSpendActiveTracker(period: self.data.period) { location in
                    self.updateHover(location: location, proxy: proxy, geometry: geometry)
                }
            }
        }
        .frame(height: 104)
        .padding(.trailing, 22)
    }

    private func updateHover(location: CGPoint?, proxy: ChartProxy, geometry: GeometryProxy) {
        var key: String?
        if let location, let anchor = proxy.plotFrame {
            let frame = geometry[anchor]
            if frame.contains(location), let date = proxy.value(atX: location.x - frame.minX, as: Date.self) {
                key = UsageDayKey.string(date)
            }
        }
        if self.hoveredDay != key {
            self.hoveredDay = key
        }
    }
}

/// Mouse tracking for a view inside one stacked period layer. An `NSTrackingArea` ignores SwiftUI opacity
/// and hit testing, so hidden layers must not have one at all: the tracker exists only while `period`
/// is the chosen one. This leaf observes the selection itself, which keeps the view around it independent
/// of the selection. When the layer gets hidden it reports the mouse as gone, so no hover state stays behind.
struct UsageSpendActiveTracker: View {
    let period: UsageSpendPeriod
    let onMoved: (CGPoint?) -> Void
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let active = self.selection.spendPeriod == self.period
        ZStack {
            if active {
                UsageMouseTracker(onMoved: self.onMoved)
            }
        }
        .onChange(of: active) { _, isActive in
            if !isActive {
                self.onMoved(nil)
            }
        }
    }
}

// MARK: - Account row

/// Spend of one account. Hovering opens a panel with the weekly windows and models.
public struct UsageSpendAccountRowView: View {
    let account: UsagePanelState.Account
    let colorIndex: Int
    let width: CGFloat
    let totals: UsageSpendAccountTotals
    @ObservedObject private var selection = UsagePanelSelection.shared
    @Environment(\.usageRowHighlighted) private var highlighted

    public init(
        account: UsagePanelState.Account,
        colorIndex: Int,
        width: CGFloat,
        now: Date = Date(),
        totals: UsageSpendAccountTotals? = nil)
    {
        self.account = account
        self.colorIndex = colorIndex
        self.width = width
        self.totals = totals ?? UsageSpendAccountTotals(account: account, now: now)
    }

    public var body: some View {
        let period = self.selection.spendPeriod
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(UsagePalette.account(self.colorIndex))
                    .frame(width: 8, height: 8)
                Text(self.account.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(UsageInk.primary(self.highlighted))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let plan = self.account.planName {
                    Text(plan)
                        .font(.system(size: 10.5))
                        .foregroundStyle(UsageInk.secondary(self.highlighted))
                }
            }
            HStack(spacing: 0) {
                self.cell("Today", days: 1)
                self.cell("7 days", days: 7)
                self.cell("\(period.days) days", days: period.days)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 30)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
    }

    private func cell(_ title: String, days: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(UsageInk.secondary(self.highlighted))
            Text(UsageFormat.usd(self.totals.split(lastDays: days).total.usd))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(UsageInk.primary(self.highlighted))
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Account panel: weekly windows and models

/// Slides out when hovering an account row. A switcher on top gives the same breakdown for any account.
///
/// An opened panel is kept alive by its submenu even while closed, so it must not observe the period:
/// only the small "By model" leaf does, and a period switch leaves the week lists alone.
public struct UsageSpendAccountPanelView: View {
    let state: UsagePanelState
    let now: Date
    let width: CGFloat
    let spend: UsageSpendDigest
    @State private var selected: String

    public init(
        state: UsagePanelState,
        account: UsagePanelState.Account,
        now: Date,
        width: CGFloat,
        spend: UsageSpendDigest? = nil)
    {
        self.state = state
        self.now = now
        self.width = width
        self.spend = spend ?? UsageSpendDigest(state: state, now: now)
        self._selected = State(initialValue: account.id)
    }

    /// A name with a parenthesized note does not fit in the button: the switcher shows the name without parentheses.
    private static func tabTitle(_ account: UsagePanelState.Account) -> String {
        account.displayName
    }

    public var body: some View {
        let accounts = self.state.orderedAccounts
        VStack(alignment: .leading, spacing: 10) {
            if accounts.count > 1 {
                Picker("Account", selection: self.$selected) {
                    ForEach(accounts) { account in
                        Text(Self.tabTitle(account)).tag(account.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            // All accounts are stacked on top of each other and only one is visible: the panel height does not jump when switching.
            ZStack(alignment: .topLeading) {
                ForEach(accounts) { account in
                    let shown = account.id == self.selected
                    UsageSpendAccountContent(
                        account: account,
                        fableWeight: self.state.fableWeight(for: account),
                        totals: self.spend.totals(for: account)
                            ?? UsageSpendAccountTotals(account: account, now: self.now),
                        isShown: shown)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }
}

struct UsageSpendAccountContent: View {
    let account: UsagePanelState.Account
    /// How many times faster a Fable dollar uses up the weekly limit than an Opus dollar.
    let fableWeight: Double
    let totals: UsageSpendAccountTotals
    let isShown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageSpendWeekList(account: self.account, fableWeight: self.fableWeight, isShown: self.isShown)
            Divider()
            UsageSpendAccountModels(totals: self.totals)
        }
    }
}

/// The only part of the account panel that depends on the period.
struct UsageSpendAccountModels: View {
    let totals: UsageSpendAccountTotals
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let period = self.selection.spendPeriod
        UsageModelBlock(
            title: "By model · \(period.short)",
            split: self.totals.split(lastDays: period.days),
            expanded: true)
    }
}

/// Title, weekly limit windows and the breakdown of the hovered week.
struct UsageSpendWeekList: View {
    let account: UsagePanelState.Account
    let fableWeight: Double
    /// Hidden accounts in the stack must not track the mouse: tracking areas ignore SwiftUI opacity,
    /// so a hidden account would follow the pointer over the visible one's weeks.
    let isShown: Bool
    @State private var hoveredWeek: Double?

    private var weeks: [UsagePanelState.Week] {
        self.account.weeks ?? []
    }

    /// How many Opus dollars this account's weekly limit holds.
    private var capacity: Double? {
        self.account.rates?["7d"]?.usdPer100
    }

    var body: some View {
        let weeks = self.weeks
        let maxWeek = max(1, weeks.map(\.split.total.usd).max() ?? 1)
        let shown = weeks.first { $0.id == self.hoveredWeek } ?? weeks.first
        VStack(alignment: .leading, spacing: 10) {
            UsagePanelTitle(
                title: "\(self.account.displayName) · your Claude Code spend",
                subtitle: "This Mac only, dollars at API prices.")
            if let shown {
                UsageSectionLabel(text: "By weekly limit window · point at a week")
                VStack(spacing: 1) {
                    ForEach(weeks) { week in
                        self.weekRow(week, maxUsd: maxWeek, selected: week.id == shown.id)
                            .overlay {
                                if self.isShown {
                                    UsageMouseTracker { location in
                                        self.hover(week.id, inside: location != nil)
                                    }
                                }
                            }
                    }
                }
                self.weekDetail(shown)
            } else {
                UsageNote(text: "Weekly windows appear after the first limit reading of this account.")
            }
        }
        .onChange(of: self.isShown) { _, isShown in
            if !isShown, self.hoveredWeek != nil {
                self.hoveredWeek = nil
            }
        }
    }

    private func hover(_ id: Double, inside: Bool) {
        if inside {
            if self.hoveredWeek != id {
                self.hoveredWeek = id
            }
        } else if self.hoveredWeek == id {
            self.hoveredWeek = nil
        }
    }

    private func weekRow(_ week: UsagePanelState.Week, maxUsd: Double, selected: Bool) -> some View {
        let split = week.split
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(UsageFormat.dayRange(week.start, week.end))
                    .font(.system(size: 11, weight: .medium))
                if week.current == true {
                    Text("now")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(UsagePalette.you.opacity(0.22), in: Capsule())
                }
                Spacer(minLength: 6)
                Text("\(UsageFormat.usd(split.total.usd)) · \(UsageFormat.tokens(split.total.tokens))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            HStack(spacing: 8) {
                UsageSplitBar(
                    parts: [
                        (split[.opus].usd, UsagePalette.opus),
                        (split[.fable].usd, UsagePalette.fable),
                        (split.minor.usd, UsagePalette.others),
                    ],
                    scale: maxUsd)
                Text(week.peakPct.map { "limit \(UsageFormat.percent($0))" } ?? "limit —")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            Color.primary.opacity(selected ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, -6)
    }

    /// Breakdown of the selected week: each model in tokens, dollars and percent of the weekly limit.
    private func weekDetail(_ week: UsagePanelState.Week) -> some View {
        let split = week.split
        let reached = week.peakPct.map { "limit reached \(UsageFormat.percent($0)), all sources" }
            ?? "no limit readings"
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(UsageFormat.dayRange(week.start, week.end)) · \(reached)")
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            self.detailRow("Opus", split[.opus], weight: 1, color: UsagePalette.opus)
            self.detailRow("Fable", split[.fable], weight: self.fableWeight, color: UsagePalette.fable)
            self.detailRow("Other", split.minor, weight: 1, color: UsagePalette.others)
            Text(split.minorText)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if let capacity = self.capacity {
                Text("“Of limit” is your part of this account's weekly limit: a full week holds "
                    + "≈ \(UsageFormat.usd(capacity)) of Opus, and $1 of Fable counts as "
                    + "$\(String(format: "%.2f", self.fableWeight)).")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func detailRow(_ name: String, _ use: UsageModelUse, weight: Double, color: Color) -> some View {
        let share = self.capacity.map { use.usd * weight / max(1, $0) * 100 }
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(name)
                .font(.system(size: 11))
                .frame(width: 36, alignment: .leading)
            Text("\(UsageFormat.tokens(use.tokens)) tok")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
            Text(UsageFormat.usdFine(use.usd))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
            Spacer(minLength: 4)
            if let share {
                Text("≈ \(UsageFormat.percentFine(share)) of limit")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

/// Horizontal bar made of parts on a common scale.
struct UsageSplitBar: View {
    let parts: [(Double, Color)]
    let scale: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(Array(self.parts.enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        Rectangle()
                            .fill(part.1)
                            .frame(width: max(1.5, proxy.size.width * CGFloat(min(1, part.0 / self.scale))))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: self.height)
        .background(UsagePalette.track)
        .clipShape(Capsule())
    }
}
