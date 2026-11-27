import AppKit
import Charts
import SwiftUI

// MARK: - Spend on this Mac: totals and per-day chart

/// Readable replacement for the "This Mac" block: three totals, spend per day (split by account or by model)
/// and models. The period is chosen with 30/60/90/180-day buttons, the split with Accounts / Models;
/// hovering a day shows its total and, left of the menu, the day panel; dragging across days zooms into them.
///
/// Switching must feel instant, so nothing is rebuilt on a switch: all numbers come precomputed in
/// `UsageSpendDigest`, every period's two charts are laid out once in a stack, and a switch only flips which
/// layer is visible. Only small leaf views observe the shared selection. A zoom adds one layer for its span.
public struct UsageSpendSummaryView: View {
    let spend: UsageSpendDigest
    let width: CGFloat
    let chartID: String

    public init(
        state: UsagePanelState,
        now: Date,
        width: CGFloat,
        spend: UsageSpendDigest? = nil,
        chartID: String = UsageSpendDigest.defaultChartID)
    {
        self.spend = spend ?? UsageSpendDigest(state: state, now: now)
        self.width = width
        self.chartID = chartID
    }

    /// The day panel of this view's chart, to register with the hover panel under `catalog.panelKey`.
    public func dayDetailCatalog(now: Date) -> UsageDayDetailCatalog {
        self.spend.dayDetailCatalog(chartID: self.chartID, now: now)
    }

    public var body: some View {
        let spend = self.spend
        let chartID = self.chartID
        VStack(alignment: .leading, spacing: 9) {
            UsageSpendHeader(
                labels: UsageSpendHeader.claudeLabels,
                offered: UsageSpendPeriod.allCases,
                today: spend.today.total,
                week: spend.week.total,
                periods: Dictionary(uniqueKeysWithValues: UsageSpendPeriod.allCases.map {
                    ($0, spend[$0].whole.total)
                }),
                customSummary: { spend.customSummary(for: $0) })
            UsageSpendBreakdownRow()
            UsagePeriodStack(
                offered: UsageSpendPeriod.allCases,
                customLayer: { range in
                    UsageSpendPeriodLayer(data: spend.period(range: range), chartID: chartID, families: spend.families)
                }) { period in
                UsageSpendPeriodLayer(data: spend[period], chartID: chartID)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }
}

/// The top of every spend section (Claude Spend and the provider pages): what the dollars are, the period
/// switch, and Today / Last 7 days / the period. Cheap to rebuild, so it may observe the selection directly.
///
/// Zoomed (`UsagePanelSelection.customRange`, on a page that passes `customSummary`): a chip with the span and
/// a ✕ in place of the label, no period button lit (any of them zooms out), and the span's total, daily
/// average and busiest day as the tiles.
struct UsageSpendHeader: View {
    /// Longest first: the period switch is wider in the menu than in a rendering, so the first label that
    /// fits on one line is shown.
    let labels: [String]
    /// The periods worth a button; one period shows no switch.
    let offered: [UsageSpendPeriod]
    let today: UsageModelUse
    let week: UsageModelUse
    let periods: [UsageSpendPeriod: UsageModelUse]
    /// The first tile's title ("Today"; Overview may name it otherwise).
    let firstTileTitle: String
    /// The zoomed tiles; nil for a page without zoom.
    let customSummary: ((UsageSpendRange) -> UsageCustomRangeSummary)?
    @ObservedObject private var selection = UsagePanelSelection.shared

    static let claudeLabels = ["This Mac · API prices", "API prices"]

    init(
        labels: [String],
        offered: [UsageSpendPeriod],
        today: UsageModelUse,
        week: UsageModelUse,
        periods: [UsageSpendPeriod: UsageModelUse],
        firstTileTitle: String = "Today",
        customSummary: ((UsageSpendRange) -> UsageCustomRangeSummary)? = nil)
    {
        self.labels = labels
        self.offered = offered
        self.today = today
        self.week = week
        self.periods = periods
        self.firstTileTitle = firstTileTitle
        self.customSummary = customSummary
    }

    /// A provider's labels: short next to a switch, the full price name without one.
    static func labels(prices: String, hasSwitch: Bool) -> [String] {
        hasSwitch ? ["This Mac · API prices", "API prices"]
            : ["This Mac · estimate at \(prices)", "Estimate at \(prices)"]
    }

    var body: some View {
        let period = UsageSpendPeriod.effective(self.selection.spendPeriod, offered: self.offered)
        let zoom: UsageCustomRangeSummary? = self.selection.customRange.flatMap { range in
            self.customSummary.map { $0(range) }
        }
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                if let zoom {
                    UsageRangePillButton(title: zoom.range.compactTitle, fullTitle: zoom.range.shortTitle) {
                        UsagePanelSelection.shared.clearCustomRange()
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        ForEach(self.labels, id: \.self) { label in
                            Text(label)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                Spacer(minLength: 6)
                if self.offered.count > 1 {
                    UsageSegmentedControl(
                        options: self.offered,
                        title: \.short,
                        selection: Binding(
                            get: { UsageSpendPeriod.effective(self.selection.spendPeriod, offered: self.offered) },
                            set: { UsagePanelSelection.shared.selectPeriod($0) }),
                        deselected: zoom != nil,
                        onSelect: { UsagePanelSelection.shared.selectPeriod($0) })
                        .fixedSize()
                }
            }
            // As tall as the period switch, so the zoom chip appearing never changes the row's height (the
            // menu caches it), also on a page without a switch.
            .frame(minHeight: 20)
            HStack(alignment: .top, spacing: 8) {
                if let zoom {
                    UsageSpendTile(title: "Selected · \(zoom.range.dayCount)d", use: zoom.total)
                    UsageSpendTile(title: "Daily average", use: zoom.dailyAverage)
                    UsageSpendTile(
                        title: zoom.busiestDay.map { "Busiest · \(UsageFormat.format($0.date, "MMM d"))" } ?? "Busiest day",
                        use: zoom.busiestDay?.use ?? UsageModelUse())
                } else {
                    UsageSpendTile(title: self.firstTileTitle, use: self.today)
                    UsageSpendTile(title: "Last 7 days", use: self.week)
                    UsageSpendTile(title: period.title, use: self.periods[period] ?? UsageModelUse())
                }
            }
        }
    }
}

/// The zoom chip: "Nov 3 – Nov 14  ⊗". An AppKit button, so a click inside the menu reaches it (rows with
/// interactive controls hand clicks over AppKit controls to them) and the menu stays open.
struct UsageRangePillButton: NSViewRepresentable {
    let title: String
    var fullTitle: String?
    let action: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PillButton {
        let button = PillButton(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        context.coordinator.action = self.action
        self.apply(to: button)
        return button
    }

    func updateNSView(_ button: PillButton, context: Context) {
        context.coordinator.action = self.action
        self.apply(to: button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PillButton, context _: Context) -> CGSize? {
        let natural = nsView.pillSize
        let width = proposal.width.map { min(natural.width, $0) } ?? natural.width
        return CGSize(width: max(width, 24), height: natural.height)
    }

    private func apply(to button: PillButton) {
        let full = self.fullTitle ?? self.title
        button.setPillTitle(self.title, fullTitle: full)
    }

    final class PillButton: NSButton {
        private var lastTitle = ""
        private static let pillFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        private static let closeImage: NSImage? = {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            return NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }()

        init(target: AnyObject?, action: Selector?) {
            super.init(frame: .zero)
            self.target = target
            self.action = action
            self.isBordered = false
            self.setButtonType(.momentaryChange)
            self.controlSize = .small
            self.lineBreakMode = .byTruncatingMiddle
            self.image = Self.closeImage
            self.imagePosition = .imageTrailing
            self.imageHugsTitle = true
            self.contentTintColor = .secondaryLabelColor
            self.wantsLayer = true
            self.layer?.cornerRadius = 5
            self.layer?.borderWidth = 0.5
            self.setContentHuggingPriority(.required, for: .horizontal)
            self.setContentHuggingPriority(.required, for: .vertical)
            self.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            self.setContentCompressionResistancePriority(.required, for: .vertical)
            self.updatePillAppearance()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            nil
        }

        var pillSize: CGSize {
            let intrinsic = self.intrinsicContentSize
            return CGSize(width: ceil(intrinsic.width) + 8, height: 19)
        }

        func setPillTitle(_ title: String, fullTitle: String) {
            guard title != self.lastTitle else { return }
            self.lastTitle = title
            self.attributedTitle = NSAttributedString(
                string: title + " ",
                attributes: [
                    .font: Self.pillFont,
                    .foregroundColor: NSColor.labelColor,
                ])
            self.toolTip = "\(fullTitle) — Click to zoom out"
            self.setAccessibilityLabel("Zoomed to \(fullTitle). Zoom out")
            self.invalidateIntrinsicContentSize()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            self.updatePillAppearance()
        }

        override func layout() {
            super.layout()
            self.updatePillAppearance()
        }

        private func updatePillAppearance() {
            let dark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            self.layer?.backgroundColor = (dark
                ? NSColor(white: 1, alpha: 0.13)
                : NSColor(white: 0, alpha: 0.065)).cgColor
            self.layer?.borderColor = (dark
                ? NSColor(white: 1, alpha: 0.20)
                : NSColor(white: 0, alpha: 0.14)).cgColor
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: (@MainActor () -> Void)?

        @objc func clicked(_: NSButton) {
            self.action?()
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

/// Every offered period stacked, one visible. The layers are equatable and do not observe the selection,
/// so a switch re-evaluates only this stack and the opacity of two layers, never a chart. Every layer has the
/// same fixed-height parts, so the stack (and the cached menu row height) never depends on the period.
/// A period the page does not offer shows the longest one it has.
///
/// With `customLayer`, a zoom (`UsagePanelSelection.customRange`) lays out one more layer for its span on
/// top and hides the period layers; it has the same fixed parts, so the row height does not change either.
/// Each layer learns whether it is the visible one from `\.usageChartLayerShown`: only that one's chart
/// tracks the pointer.
struct UsagePeriodStack<Layer: View & Equatable>: View {
    let offered: [UsageSpendPeriod]
    let layer: (UsageSpendPeriod) -> Layer
    let customLayer: ((UsageSpendRange) -> Layer)?
    @ObservedObject private var selection = UsagePanelSelection.shared

    init(
        offered: [UsageSpendPeriod],
        customLayer: ((UsageSpendRange) -> Layer)? = nil,
        @ViewBuilder layer: @escaping (UsageSpendPeriod) -> Layer)
    {
        self.offered = offered
        self.customLayer = customLayer
        self.layer = layer
    }

    var body: some View {
        let chosen = UsageSpendPeriod.effective(self.selection.spendPeriod, offered: self.offered)
        let range = self.customLayer == nil ? nil : self.selection.customRange
        ZStack(alignment: .topLeading) {
            ForEach(self.offered) { period in
                let shown = range == nil && period == chosen
                self.layer(period)
                    .equatable()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                    .environment(\.usageChartLayerShown, shown)
            }
            if let range, let customLayer = self.customLayer {
                customLayer(range)
                    .equatable()
                    .id(range)
                    .environment(\.usageChartLayerShown, true)
            }
        }
    }
}

/// One period (or one zoom): caption, chart and models. Pure data in, so `.equatable()` skips it on a switch.
struct UsageSpendPeriodLayer: View, Equatable {
    let data: UsageSpendDigest.Period
    var chartID: String = UsageSpendDigest.defaultChartID
    /// The model rows; by default the period's own. A zoom passes those of the longest period, so its layer
    /// is never taller than the period layers.
    var families: [UsageModelFamily]?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Hover state lives in leaves inside the chart view, so pointing at bars does not rebuild the models.
            UsageSpendChartPair(data: self.data, chartID: self.chartID)
            UsageModelBlock(
                title: self.data.range.map { "By model · \($0.dayCount) days" } ?? "By model · \(self.data.period.short)",
                split: self.data.whole,
                families: self.families)
        }
    }
}

/// The period's chart by account and by model, both laid out, one visible. Only this leaf observes
/// the breakdown, and the charts inside are equatable, so a switch changes two opacities.
struct UsageSpendChartPair: View {
    let data: UsageSpendDigest.Period
    let chartID: String
    @ObservedObject private var selection = UsagePanelSelection.shared
    @Environment(\.usageChartLayerShown) private var layerShown

    var body: some View {
        let chosen = self.selection.spendBreakdown
        ZStack(alignment: .topLeading) {
            ForEach(UsageSpendBreakdown.allCases) { breakdown in
                let shown = breakdown == chosen
                UsageSpendChartLayer(data: self.data.chart(breakdown), chartID: self.chartID)
                    .equatable()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                    .environment(\.usageChartLayerShown, self.layerShown && shown)
            }
        }
    }
}

struct UsageSpendChartLayer: View, Equatable {
    let data: UsageDayChartData
    let chartID: String

    var body: some View {
        UsageSpendDayChart(data: self.data, chartID: self.chartID)
    }
}

// MARK: - Per-day chart, shared by Claude Spend (one color per account) and the provider pages (one per model)

/// The color of one series on a per-day chart. An index rather than a `Color`, so the chart data stays
/// cheaply equatable (a dynamic `Color` compares by identity).
public enum UsageSeriesColor: Hashable, Sendable {
    /// A Claude account, in Claude Switcher order.
    case account(Int)
    /// A provider's model, in the order of `UsageProviderSpend`.
    case model(Int)
    /// A Claude model.
    case claude(UsageModelFamily)
    /// A provider on Overview: 0 Claude (orange), 1 Codex (blue), 2 Antigravity (lime), the account colors,
    /// which stay apart on a warm screen.
    case provider(Int)
    /// Everything without a color of its own.
    case other

    public var color: Color {
        switch self {
        case let .account(index): UsagePalette.account(index)
        case let .model(index): UsagePalette.model(index)
        case let .claude(family): family.color
        case let .provider(index): UsagePalette.account(index)
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
    /// By day key: "Opus $5 · Fable $2" (Claude) or "259M tokens" (a provider page).
    let dayNotes: [String: String]
    /// Shown in place of the chart when the period has no bars.
    let emptyText: String
    /// The most chips a pointed-at day lists before "+N more"; nil for no limit.
    let chipLimit: Int?
    /// A pointed-at day shows cents below $10 ("$0.11"), so a small model does not read as "$0".
    let centsInChips: Bool
    /// Set on a zoom's chart: the span it shows (`period` is then the smallest preset covering it).
    var customRange: UsageSpendRange?

    func amount(_ usd: Double) -> String {
        self.centsInChips ? UsageFormat.usdFine(usd) : UsageFormat.usd(usd)
    }

    /// Dollars of the bars inside a span: the caption during a drag.
    func total(in range: UsageSpendRange) -> Double {
        self.bars.reduce(0) { range.contains($1.key) ? $0 + $1.usd : $0 }
    }
}

/// Caption and per-day chart of one period. Three parts, so scrubbing never lays the chart out again:
/// the caption (`UsageSpendChartCaption`, a leaf that follows `UsageDayFocus`), the bars
/// (`UsageSpendBarsCanvas`, equatable, never depends on the pointer) and, over the plot, the highlight and the
/// pointer registration (`UsageSpendChartInteractionOverlay`).
///
/// `chartID` is the page's chart: the period layers of one page share it (only the shown one tracks the
/// pointer), and its day panel is registered with the hover panel under `panelKey` (`chartID + ":day"`).
struct UsageSpendDayChart: View {
    let data: UsageDayChartData
    let chartID: String
    /// The plot's height: Claude Spend has a page of its own, a provider page shares one with its limits.
    let plotHeight: CGFloat
    let panelKey: String

    static let defaultPlotHeight: CGFloat = 104

    init(data: UsageDayChartData, chartID: String, plotHeight: CGFloat = 104, panelKey: String? = nil) {
        self.data = data
        self.chartID = chartID
        self.plotHeight = plotHeight
        self.panelKey = panelKey ?? UsageDayDetailCatalog.panelKey(for: chartID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            UsageSpendChartCaption(data: self.data, chartID: self.chartID)
            if self.data.bars.isEmpty, self.data.customRange == nil {
                UsageNote(text: self.data.emptyText)
                    .frame(height: self.plotHeight, alignment: .topLeading)
            } else {
                ZStack(alignment: .topLeading) {
                    UsageSpendBarsCanvas(
                        data: self.data, chartID: self.chartID, panelKey: self.panelKey, plotHeight: self.plotHeight)
                        .equatable()
                    if self.data.bars.isEmpty {
                        UsageNote(text: self.data.emptyText)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

/// Two lines of fixed height above the chart: at rest the hint and the legend, on a day its total and chips,
/// during a drag the span and its total. Hovering changes the text, not the menu item height.
struct UsageSpendChartCaption: View {
    let data: UsageDayChartData
    let chartID: String
    @ObservedObject private var focus = UsageDayFocus.shared
    @Environment(\.usageChartLayerShown) private var shown
    @Environment(\.usagePreviewHoveredDay) private var previewDay
    @Environment(\.usagePreviewDragRange) private var previewRange

    var body: some View {
        let mine = self.shown && self.focus.activeChartID == self.chartID
        let dragged = self.previewRange ?? (mine && self.focus.isDragging ? self.focus.dragRange : nil)
        let range = dragged.flatMap { $0.dayCount >= 2 ? $0 : nil }
        let day = (mine ? self.focus.hoveredDayKey : nil) ?? self.previewDay
        let hovered = day.map { key in self.data.bars.filter { $0.key == key } } ?? []
        VStack(alignment: .leading, spacing: 3) {
            if let range {
                (Text(range.shortTitle).fontWeight(.semibold)
                    + Text(" · \(range.dayCount) days · \(UsageFormat.usd(self.data.total(in: range)))")
                    .fontWeight(.semibold))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .lineLimit(1)
                Text("Release to zoom")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let first = hovered.first {
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
                let chips = hovered.prefix(limit)
                HStack(spacing: 10) {
                    ForEach(chips) { bar in
                        UsageChip(color: bar.color.color, text: "\(bar.series) \(self.data.amount(bar.usd))")
                    }
                    if hovered.count > chips.count {
                        Text("+\(hovered.count - chips.count) more")
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
        .transaction { $0.animation = nil }
    }
}

/// The bars and axes. Depends on its data only: hovering and dragging never re-run Swift Charts' layout.
struct UsageSpendBarsCanvas: View, Equatable {
    let data: UsageDayChartData
    let chartID: String
    let panelKey: String
    let plotHeight: CGFloat

    var body: some View {
        Chart(self.data.bars) { bar in
            BarMark(
                x: .value("Day", bar.date, unit: .day),
                y: .value("Dollars", bar.usd))
                .foregroundStyle(bar.color.color)
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
            if let dates = self.customXAxisDates {
                AxisMarks(preset: .aligned, values: dates) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(UsageFormat.format(date, "MMM d")).font(.system(size: 9))
                        }
                    }
                }
            } else {
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self), date < self.data.domain.upperBound {
                            Text(UsageFormat.format(date, "MMM d")).font(.system(size: 9))
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            UsageSpendChartInteractionOverlay(
                proxy: proxy, domain: self.data.domain, chartID: self.chartID, panelKey: self.panelKey)
        }
        .frame(height: self.plotHeight)
        .padding(.trailing, 22)
    }

    /// Explicit tick dates strictly inside the zoomed span (`startDate...endDate`) so the exclusive upper bound
    /// (`endDate + 1 day`) is never labelled on the axis.
    private var customXAxisDates: [Date]? {
        guard let range = self.data.customRange else { return nil }
        let days = range.dayCount
        let calendar = Calendar.current
        let step = max(1, Int(ceil(Double(days) / 4.0)))
        var dates: [Date] = []
        var offset = 0
        while offset < days {
            if let date = calendar.date(byAdding: .day, value: offset, to: range.startDate) {
                dates.append(date)
            }
            offset += step
        }
        return dates
    }
}

/// Over the plot: the highlight of the pointed-at day or the dragged span, and the chart's registration with
/// `UsageChartPointer` while its layer is the visible one.
struct UsageSpendChartInteractionOverlay: View {
    let proxy: ChartProxy
    let domain: ClosedRange<Date>
    let chartID: String
    let panelKey: String

    var body: some View {
        GeometryReader { geometry in
            let plot = self.proxy.plotFrame.map { geometry[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                UsageSpendChartHighlight(proxy: self.proxy, plot: plot, chartID: self.chartID)
                UsageSpendChartRegistrar(
                    proxy: self.proxy, plot: plot, domain: self.domain, chartID: self.chartID, panelKey: self.panelKey)
            }
        }
    }
}

/// Registers the chart with the pointer router while its layer is the visible one. An anchor view that is
/// not there has no tracking area and is not hit, so hidden layers never react to the pointer.
struct UsageSpendChartRegistrar: View {
    let proxy: ChartProxy
    let plot: CGRect
    let domain: ClosedRange<Date>
    let chartID: String
    let panelKey: String
    @Environment(\.usageChartLayerShown) private var shown

    var body: some View {
        if self.shown {
            // Fills the overlay, so its coordinates are the overlay's (and `plot` is in them).
            UsageChartAnchor(chartID: self.chartID, handlers: self.handlers)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var handlers: UsageChartPointer.Handlers {
        let proxy = self.proxy
        let plot = self.plot
        let domain = self.domain
        return UsageChartPointer.Handlers(
            panelKey: self.panelKey,
            plotBoundsInView: { plot },
            dayKey: { localX in
                guard plot.width > 1 else { return nil }
                let x = min(max(localX, plot.minX), plot.maxX - 0.01) - plot.minX
                guard let date = proxy.value(atX: x, as: Date.self) else { return nil }
                // The last instant of the domain is the midnight after its last day.
                let last = domain.upperBound.addingTimeInterval(-1)
                return UsageDayKey.string(min(max(date, domain.lowerBound), max(domain.lowerBound, last)))
            },
            onDragEnded: { range in
                UsagePanelSelection.shared.customRange = range
            },
            onDoubleClick: {
                UsagePanelSelection.shared.clearCustomRange()
            })
    }
}

/// The pointed-at day (a column, the rest gently washed out) or the dragged span (washed out outside, a
/// light band inside, crisp edges). Drawn by luminance, so it reads on a warm screen too. Never animated.
struct UsageSpendChartHighlight: View {
    let proxy: ChartProxy
    let plot: CGRect
    let chartID: String
    @ObservedObject private var focus = UsageDayFocus.shared
    @Environment(\.usageChartLayerShown) private var shown
    @Environment(\.usagePreviewHoveredDay) private var previewDay
    @Environment(\.usagePreviewDragRange) private var previewRange

    var body: some View {
        let marked = self.marked
        let span = marked.span
        let isRange = marked.isRange
        let plot = self.plot
        Canvas { context, _ in
            guard let span, plot.width > 1 else { return }
            let wash = GraphicsContext.Shading.color(UsagePalette.chartWash.opacity(isRange ? 0.55 : 0.45))
            context.fill(
                Path(CGRect(x: plot.minX, y: plot.minY, width: max(0, span.lower - plot.minX), height: plot.height)),
                with: wash)
            context.fill(
                Path(CGRect(x: span.upper, y: plot.minY, width: max(0, plot.maxX - span.upper), height: plot.height)),
                with: wash)
            guard isRange else { return }
            let band = CGRect(x: span.lower, y: plot.minY, width: max(0, span.upper - span.lower), height: plot.height)
            context.fill(Path(band), with: .color(Color.primary.opacity(0.08)))
            let edge = GraphicsContext.Shading.color(Color.primary.opacity(0.55))
            context.fill(Path(CGRect(x: band.minX, y: band.minY, width: 1, height: band.height)), with: edge)
            context.fill(Path(CGRect(x: band.maxX - 1, y: band.minY, width: 1, height: band.height)), with: edge)
        }
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }

    /// What to mark: the dragged span (two days or more) or else the pointed-at day, as an x extent.
    private var marked: (span: (lower: CGFloat, upper: CGFloat)?, isRange: Bool) {
        let mine = self.shown && self.focus.activeChartID == self.chartID
        let dragged = self.previewRange ?? (mine && self.focus.isDragging ? self.focus.dragRange : nil)
        if let range = dragged, range.dayCount >= 2 {
            return (self.extent(from: range.startDate, to: range.domain.upperBound), true)
        }
        guard let day = (mine ? self.focus.hoveredDayKey : nil) ?? self.previewDay,
              let start = UsageDayKey.date(day)
        else { return (nil, false) }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        return (self.extent(from: start, to: end), false)
    }

    /// The x extent of a span of time inside the plot, in the overlay's coordinates; nil when it is off the plot.
    private func extent(from start: Date, to end: Date) -> (lower: CGFloat, upper: CGFloat)? {
        guard let lower = self.proxy.position(forX: start), let upper = self.proxy.position(forX: end) else { return nil }
        let left = min(max(self.plot.minX + lower, self.plot.minX), self.plot.maxX)
        let right = min(max(self.plot.minX + upper, self.plot.minX), self.plot.maxX)
        guard right > left else { return nil }
        return (left, right)
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
                    self.cell("Today", usd: self.totals.split(lastDays: 1).total.usd)
                        .frame(width: 72, alignment: .leading)
                    self.cell("7 days", usd: self.totals.split(lastDays: 7).total.usd)
                        .frame(width: 86, alignment: .leading)
                    // A zoom (dragged on a per-day chart) replaces the period.
                    if let range = self.selection.customRange {
                        self.cell("\(range.dayCount)d", usd: self.account.split(in: range).total.usd)
                    } else {
                        self.cell("\(period.days) days", usd: self.totals.split(lastDays: period.days).total.usd)
                    }
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 30)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
    }

    private func cell(_ title: String, usd: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(UsageInk.secondary(self.highlighted))
            Text(UsageFormat.usd(usd))
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(UsageInk.primary(self.highlighted))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
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
                UsageSpendAccountModels(account: self.account, totals: self.totals)
            }
        }
    }
}

/// The only part of the account panel that depends on the period.
struct UsageSpendAccountModels: View {
    let account: UsagePanelState.Account
    let totals: UsageSpendAccountTotals
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let period = self.selection.spendPeriod
        let families = self.totals.split(lastDays: UsageSpendPeriod.allCases.map(\.days).max() ?? 180).shownFamilies
        if let range = self.selection.customRange {
            UsageModelBlock(
                title: "By model · \(range.dayCount) days",
                split: self.account.split(in: range),
                families: families)
        } else {
            UsageModelBlock(
                title: "By model · \(period.short)",
                split: self.totals.split(lastDays: period.days),
                families: families)
        }
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
