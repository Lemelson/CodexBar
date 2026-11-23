import Charts
import SwiftUI

// MARK: - Spend on this Mac: totals and per-day chart

/// Readable replacement for the "This Mac" block: three totals, spend per day (split by account or by model)
/// and models. The period is chosen with 30/60/90/180-day buttons, the split with Accounts / Models;
/// hovering a day shows its total.
///
/// Switching must feel instant, so nothing is rebuilt on a switch: all numbers come precomputed in
/// `UsageSpendDigest`, every period's two charts are laid out once in a stack, and a switch only flips which
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
            UsageSpendBreakdownRow()
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
                // The period switch is wider in the menu than in a rendering: the short form when the long
                // one would wrap.
                ViewThatFits(in: .horizontal) {
                    ForEach(["This Mac · API prices", "This Mac · API $"], id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Spacer(minLength: 6)
                UsageSegmentedControl(
                    options: Array(UsageSpendPeriod.allCases),
                    title: \.short,
                    selection: self.$selection.spendPeriod)
                    .fixedSize()
            }
            HStack(alignment: .top, spacing: 8) {
                UsageSpendTile(title: "Today", use: self.spend.today.total)
                UsageSpendTile(title: "Last 7 days", use: self.spend.week.total)
                UsageSpendTile(title: period.title, use: self.spend[period].whole.total)
            }
        }
    }
}

/// One total over the chart: span, dollars, tokens.
struct UsageSpendTile: View {
    let title: String
    let use: UsageModelUse

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(self.title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(UsageFormat.usd(self.use.usd))
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(UsageFormat.tokens(self.use.tokens)) tokens")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Per day, split by  [Accounts | Models]", right under the totals and lined up with the period buttons.
struct UsageSpendBreakdownRow: View {
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        HStack(alignment: .center) {
            Text("Per day, split by")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            UsageSegmentedControl(
                options: Array(UsageSpendBreakdown.allCases),
                title: \.title,
                selection: self.$selection.spendBreakdown)
                .fixedSize()
        }
        .padding(.top, 2)
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
                UsageSpendPeriodLayer(data: self.spend[period])
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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Hover state lives inside the chart view, so pointing at bars does not rebuild the models below.
            UsageSpendChartPair(data: self.data)
            UsageModelBlock(title: "By model · \(self.data.period.short)", split: self.data.whole)
        }
    }
}

/// The period's chart by account and by model, both laid out, one visible. Only this leaf observes
/// the breakdown, and the charts inside are equatable, so a switch changes two opacities.
struct UsageSpendChartPair: View {
    let data: UsageSpendDigest.Period
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let chosen = self.selection.spendBreakdown
        ZStack(alignment: .topLeading) {
            ForEach(UsageSpendBreakdown.allCases) { breakdown in
                let shown = breakdown == chosen
                UsageSpendChartLayer(data: self.data.chart(breakdown), breakdown: breakdown)
                    .equatable()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
    }
}

struct UsageSpendChartLayer: View, Equatable {
    let data: UsageDayChartData
    let breakdown: UsageSpendBreakdown

    var body: some View {
        UsageSpendDayChart(data: self.data, breakdown: self.breakdown)
    }
}

// MARK: - Per-day chart, shared by Claude Spend (one color per account) and Antigravity (one per model)

/// The color of one series on a per-day chart. An index rather than a `Color`, so the chart data stays
/// cheaply equatable (a dynamic `Color` compares by identity).
enum UsageSeriesColor: Hashable, Sendable {
    /// A Claude account, in Claude Switcher order.
    case account(Int)
    /// A Gemini model, in the order of `UsageAntigravitySpend`.
    case model(Int)
    /// A Claude model.
    case claude(UsageModelFamily)
    /// Everything without a color of its own.
    case other

    var color: Color {
        switch self {
        case let .account(index): UsagePalette.account(index)
        case let .model(index): UsagePalette.model(index)
        case let .claude(family): family.color
        case .other: UsagePalette.others
        }
    }
}

/// One period of a per-day spend chart, laid out once: bars (one per series and day), range, the hint
/// above the chart, the legend, and the grey note after a pointed-at day's total.
struct UsageDayChartData: Sendable, Equatable {
    struct Bar: Identifiable, Sendable, Equatable {
        let key: String
        let date: Date
        /// Account or model name: the chip of a pointed-at day.
        let series: String
        let color: UsageSeriesColor
        let usd: Double

        var id: String {
            "\(self.key)-\(self.series)"
        }
    }

    struct Legend: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        let color: UsageSeriesColor
    }

    let period: UsageSpendPeriod
    let domain: ClosedRange<Date>
    let bars: [Bar]
    let hint: String
    let legend: [Legend]
    /// By day key: "Opus $5 · Fable $2" (Claude) or "259M tokens" (Antigravity).
    let dayNotes: [String: String]
    /// Shown in place of the chart when the period has no bars.
    let emptyText: String
    /// The most chips a pointed-at day lists before "+N more"; nil for no limit.
    let chipLimit: Int?
    /// A pointed-at day shows cents below $10 ("$0.11"), so a small model does not read as "$0".
    let centsInChips: Bool

    func amount(_ usd: Double) -> String {
        self.centsInChips ? UsageFormat.usdFine(usd) : UsageFormat.usd(usd)
    }
}

/// Caption and per-day chart of one period; owns the hovered day.
struct UsageSpendDayChart: View {
    let data: UsageDayChartData
    /// The periods the page offers; a layer tracks the mouse while its period is the one shown.
    var offered: [UsageSpendPeriod] = UsageSpendPeriod.allCases
    /// Claude Spend lays out one chart per breakdown: only the shown one may track the mouse.
    var breakdown: UsageSpendBreakdown?
    @State private var pointedDay: String?
    @Environment(\.usagePreviewHoveredDay) private var previewDay

    private var hoveredDay: String? {
        self.pointedDay ?? self.previewDay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            self.caption
            if self.data.bars.isEmpty {
                UsageNote(text: self.data.emptyText)
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
                let note = self.data.dayNotes[first.key].map { "  \($0)" } ?? ""
                (Text(UsageFormat.format(first.date, "EEE, MMM d")).fontWeight(.semibold)
                    + Text(" · \(self.data.amount(total))").fontWeight(.semibold)
                    + Text(note)
                    .foregroundStyle(.secondary))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .lineLimit(1)
                let limit = self.data.chipLimit ?? hovered.count
                let shown = hovered.prefix(limit)
                HStack(spacing: 10) {
                    ForEach(shown) { bar in
                        UsageChip(color: bar.color.color, text: "\(bar.series) \(self.data.amount(bar.usd))")
                    }
                    if hovered.count > shown.count {
                        Text("+\(hovered.count - shown.count) more")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(self.data.hint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HStack(spacing: 10) {
                    ForEach(self.data.legend) { series in
                        UsageChip(color: series.color.color, text: series.name)
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
                .foregroundStyle(bar.color.color)
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
                UsageSpendActiveTracker(period: self.data.period, offered: self.offered, breakdown: self.breakdown) { location in
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
        if self.pointedDay != key {
            self.pointedDay = key
        }
    }
}

/// Mouse tracking for a view inside one stacked period layer. An `NSTrackingArea` ignores SwiftUI opacity
/// and hit testing, so hidden layers must not have one at all: the tracker exists only while `period`
/// is the chosen one. This leaf observes the selection itself, which keeps the view around it independent
/// of the selection. When the layer gets hidden it reports the mouse as gone, so no hover state stays behind.
/// A page that offers fewer periods (Antigravity with a short history) passes them as `offered`: the layer
/// shown for a period it lacks is the longest one it has.
struct UsageSpendActiveTracker: View {
    let period: UsageSpendPeriod
    var offered: [UsageSpendPeriod] = UsageSpendPeriod.allCases
    /// Set for a chart that is one of the Accounts / Models pair: it tracks only while its breakdown is shown.
    var breakdown: UsageSpendBreakdown?
    let onMoved: (CGPoint?) -> Void
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let active = UsageSpendPeriod.effective(self.selection.spendPeriod, offered: self.offered) == self.period
            && (self.breakdown == nil || self.breakdown == self.selection.spendBreakdown)
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
            // An account the collector failed on has no spend to show: zeros would read as data.
            if let unavailable = self.account.unavailableNote {
                UsageUnavailableLine(text: unavailable)
            } else {
                HStack(spacing: 0) {
                    self.cell("Today", days: 1)
                    self.cell("7 days", days: 7)
                    self.cell("\(period.days) days", days: period.days)
                }
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
                UsageSegmentedControl(
                    options: accounts.map(\.id),
                    title: { id in
                        accounts.first(where: { $0.id == id }).map(Self.tabTitle) ?? ""
                    },
                    selection: self.$selected,
                    fillWidth: true)
            }
            // All accounts are stacked on top of each other and only one is visible: the panel height does not jump when switching.
            ZStack(alignment: .topLeading) {
                ForEach(accounts) { account in
                    let shown = account.id == self.selected
                    UsageSpendAccountContent(
                        account: account,
                        now: self.now,
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
    let now: Date
    /// How many times faster a Fable dollar uses up the weekly limit than an Opus dollar.
    let fableWeight: Double
    let totals: UsageSpendAccountTotals
    let isShown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let unavailable = self.account.unavailableNote {
                UsagePanelTitle(
                    title: "\(self.account.displayName) · your Claude Code spend",
                    subtitle: "This Mac only, dollars at API prices.")
                UsageUnavailableLine(text: unavailable)
            } else {
                UsageSpendWeekList(
                    account: self.account, fableWeight: self.fableWeight, isShown: self.isShown, now: self.now)
                Divider()
                UsageSpendAccountModels(totals: self.totals)
            }
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
            families: self.totals.split(lastDays: UsageSpendPeriod.allCases.map(\.days).max() ?? 180).shownFamilies)
    }
}

/// Horizontal bar made of parts on a common scale.
struct UsageSplitBar: View {
    let parts: [(Double, Color)]
    let scale: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            // The 1 pt gaps between parts come out of the width, so parts that fill the scale end at the
            // bar's end instead of running past it into the rounded clip.
            let drawn = self.parts.filter { $0.0 > 0 }
            let usable = max(0, proxy.size.width - CGFloat(max(0, drawn.count - 1)))
            HStack(spacing: 1) {
                ForEach(Array(drawn.enumerated()), id: \.offset) { _, part in
                    Rectangle()
                        .fill(part.1)
                        .frame(width: max(1.5, usable * CGFloat(min(1, part.0 / self.scale))))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: self.height)
        .background(UsagePalette.track)
        .clipShape(Capsule())
    }
}
