import SwiftUI

// Overview: what every subscription on this Mac costs at API prices, in the parts of Claude Spend.
//
//   UsageOverviewSummaryView        `UsageSpendHeader` (Last 24 hours / Last 7 days / the period), the
//                                   Providers | Models switch, `UsagePeriodStack` of per-day charts and models
//   UsageOverviewProviderRowView    one row per subscription (Claude, Codex, Antigravity), as an account row of
//                                   Claude Spend, with the tightest weekly limit at its right
//   UsageOverviewProviderPanelView  that row's hover panel: its limits and its models
//
// As on Claude Spend, a switch never rebuilds a chart: every period's two charts are laid out once, only small
// leaves observe the selections, and a switch flips opacities.

// MARK: - Spend

public struct UsageOverviewSummaryView: View {
    let spend: UsageOverviewSpend
    let width: CGFloat
    let chartID: String

    /// The labels above the tiles, longest first: the first that fits next to the period switch is shown.
    static let labels = ["All subscriptions · API prices", "API prices"]

    public init(spend: UsageOverviewSpend, width: CGFloat, chartID: String = UsageOverviewSpend.defaultChartID) {
        self.spend = spend
        self.width = width
        self.chartID = chartID
    }

    public var body: some View {
        let spend = self.spend
        let chartID = self.chartID
        VStack(alignment: .leading, spacing: 9) {
            if spend.hasSpend {
                UsageSpendHeader(
                    labels: Self.labels,
                    offered: spend.offered,
                    today: spend.last24hOrToday,
                    week: spend.week,
                    periods: Dictionary(uniqueKeysWithValues: spend.offered.map { ($0, spend[$0].whole) }),
                    firstTileTitle: spend.usesRolling24h ? "Last 24 hours" : "Today",
                    customSummary: { spend.customSummary(for: $0) })
                UsageOverviewBreakdownRow()
                UsagePeriodStack(
                    offered: spend.offered,
                    customLayer: { range in
                        UsageOverviewPeriodLayer(data: spend.period(range: range), chartID: chartID)
                    }) { period in
                    UsageOverviewPeriodLayer(data: spend[period], chartID: chartID)
                }
            } else {
                Text("Spend")
                    .font(.system(size: 12.5, weight: .semibold))
                UsageNote(text: "No Claude Code, Codex or Antigravity calls recorded on this Mac yet.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }
}

/// "Per day, split by  [Providers | Models]", right under the totals and lined up with the period buttons.
struct UsageOverviewBreakdownRow: View {
    @ObservedObject private var selection = UsageOverviewSelection.shared

    var body: some View {
        HStack(alignment: .center) {
            Text("Per day, split by")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            UsageSegmentedControl(
                options: Array(UsageOverviewBreakdown.allCases),
                title: \.title,
                selection: self.$selection.breakdown)
                .fixedSize()
        }
        .padding(.top, 2)
    }
}

/// One period (or one zoom): the chart pair and the model rows. Pure data in, so `.equatable()` skips it on a
/// switch. Every layer has the same number of model rows and a one-line note, so they all have one height.
struct UsageOverviewPeriodLayer: View, Equatable {
    let data: UsageOverviewSpend.Period
    let chartID: String

    /// Provider model names ("Hydrogen", "Auto Review") are longer than Claude's.
    static let nameWidth: CGFloat = 66

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            UsageOverviewChartPair(data: self.data, chartID: self.chartID)
            UsageModelRows(
                title: "By model · \(self.data.customTitle ?? self.data.period.short)",
                lines: self.data.rows,
                total: self.data.whole.usd,
                nameWidth: Self.nameWidth,
                notes: (0...self.data.otherMembers.count).reversed().compactMap { self.data.otherNote(naming: $0) })
        }
    }
}

/// The period's chart by provider and by model, both laid out, one visible. Only this leaf observes the split.
struct UsageOverviewChartPair: View {
    let data: UsageOverviewSpend.Period
    let chartID: String
    @ObservedObject private var selection = UsageOverviewSelection.shared
    @Environment(\.usageChartLayerShown) private var layerShown

    var body: some View {
        let chosen = self.selection.breakdown
        ZStack(alignment: .topLeading) {
            ForEach(UsageOverviewBreakdown.allCases) { breakdown in
                let shown = breakdown == chosen
                UsageOverviewChartLayer(data: self.data.chart(breakdown), chartID: self.chartID)
                    .equatable()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                    .environment(\.usageChartLayerShown, self.layerShown && shown)
            }
        }
    }
}

struct UsageOverviewChartLayer: View, Equatable {
    let data: UsageDayChartData
    let chartID: String

    /// A little lower than Claude Spend's: Overview has three provider rows under it.
    static let plotHeight: CGFloat = 96

    var body: some View {
        UsageSpendDayChart(data: self.data, chartID: self.chartID, plotHeight: Self.plotHeight)
    }
}

// MARK: - Provider row

/// Claude, Codex or Antigravity: name, plan or accounts, the weekly limit left; then 24 hours, 7 days and the
/// period (or the zoom). The paddings and type of `UsageSpendAccountRowView`, so the page reads as one.
public struct UsageOverviewProviderRowView: View {
    let provider: UsageOverviewSpend.ProviderSummary
    let offered: [UsageSpendPeriod]
    let width: CGFloat
    @ObservedObject private var selection = UsagePanelSelection.shared
    @Environment(\.usageRowHighlighted) private var highlighted

    public init(provider: UsageOverviewSpend.ProviderSummary, offered: [UsageSpendPeriod], width: CGFloat) {
        self.provider = provider
        self.offered = offered
        self.width = width
    }

    public var body: some View {
        let provider = self.provider
        let period = UsageSpendPeriod.effective(self.selection.spendPeriod, offered: self.offered)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(provider.kind.color)
                    .frame(width: 8, height: 8)
                Text(provider.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(UsageInk.primary(self.highlighted))
                    .lineLimit(1)
                    .layoutPriority(2)
                if !provider.subtitle.isEmpty {
                    // Never cut: the status at the right gives way (it scales down a little) instead.
                    Text(provider.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(UsageInk.secondary(self.highlighted))
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 6)
                Text(provider.statusText)
                    .font(.system(size: 10.5, weight: provider.statusIsAlert ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(self.statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // A provider without numbers says why in one quiet line: zeros would read as data.
            if let unavailable = provider.unavailableNote {
                UsageUnavailableLine(text: unavailable)
            } else {
                // Columns as wide as their numbers get: a period of a busy month runs to "$12,488".
                HStack(spacing: 0) {
                    self.cell(provider.firstCellTitle, usd: provider.usd24h)
                        .frame(width: Self.firstCellWidth, alignment: .leading)
                    self.cell("7 days", usd: provider.usd7d)
                        .frame(width: Self.weekCellWidth, alignment: .leading)
                    // A zoom (dragged on a per-day chart) replaces the period.
                    if let range = self.selection.customRange {
                        self.cell("\(range.dayCount)d", usd: provider.spend(in: range).usd)
                    } else {
                        self.cell("\(period.days) days", usd: provider.periodUsd[period] ?? 0)
                    }
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 30)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
    }

    static let firstCellWidth: CGFloat = 66
    static let weekCellWidth: CGFloat = 88

    private var statusColor: Color {
        if self.highlighted {
            return .white
        }
        switch self.provider.statusTone {
        case .good: return UsagePalette.paceGood
        case .warning: return UsagePalette.warning
        case .bad: return UsagePalette.paceBad
        case .neutral: return .secondary
        }
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

// MARK: - Provider panel

/// The hover panel of a provider row: its limits (each Claude account's weekly limit; Codex's and Antigravity's
/// session and weekly limits), then its models in the shown period. Only the models observe the period.
public struct UsageOverviewProviderPanelView: View {
    let provider: UsageOverviewSpend.ProviderSummary
    let offered: [UsageSpendPeriod]
    let width: CGFloat

    public init(provider: UsageOverviewSpend.ProviderSummary, offered: [UsageSpendPeriod], width: CGFloat) {
        self.provider = provider
        self.offered = offered
        self.width = width
    }

    public var body: some View {
        let provider = self.provider
        VStack(alignment: .leading, spacing: 10) {
            UsagePanelTitle(title: provider.title, subtitle: self.subtitle)
            if let unavailable = provider.unavailableNote {
                UsageNote(text: unavailable)
            }
            if !provider.limits.isEmpty {
                Divider()
                UsageSectionLabel(text: provider.limitsTitle)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(provider.limits) { limit in
                        UsageOverviewLimitLine(limit: limit, color: provider.kind.color)
                    }
                }
            }
            if provider.unavailableNote == nil {
                Divider()
                UsageOverviewProviderModels(provider: provider, offered: self.offered)
            }
            Divider()
            UsageNote(text: "Click the row to open \(provider.title).")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }

    /// "3 accounts · spend on this Mac at API prices", "Plus · spend on this Mac at API prices".
    private var subtitle: String {
        let what = "spend on this Mac at API prices"
        return self.provider.subtitle.isEmpty ? what.prefix(1).uppercased() + what.dropFirst()
            : "\(self.provider.subtitle) · \(what)"
    }
}

/// "Lemelson   ▬▬▬▬▬▬▬▬▬▬▬▬   26%   Enough", and under it the reset time or "Paused · VPN".
struct UsageOverviewLimitLine: View {
    let limit: UsageOverviewSpend.ProviderSummary.Limit
    /// The provider's color for the bar; red once the limit will not last.
    let color: Color

    static let nameWidth: CGFloat = 72

    var body: some View {
        let limit = self.limit
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(limit.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(width: Self.nameWidth, alignment: .leading)
                UsageSplitBar(
                    parts: limit.usedPct.map { [(min(100, max(0, $0)), limit.tone == .bad ? UsagePalette.paceBad : self.color)] } ?? [],
                    scale: 100)
                Text(limit.usedPct.map { UsageFormat.percent(max(0, $0)) } ?? "—")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                Text(limit.verdict)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(self.toneColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 86, alignment: .trailing)
            }
            if let detail = limit.detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, Self.nameWidth + 8)
            }
        }
    }

    private var toneColor: Color {
        switch self.limit.tone {
        case .good: UsagePalette.paceGood
        case .warning: UsagePalette.warning
        case .bad: UsagePalette.paceBad
        case .neutral: .secondary
        }
    }
}

/// The only part of the provider panel that depends on the period or the zoom.
struct UsageOverviewProviderModels: View {
    let provider: UsageOverviewSpend.ProviderSummary
    let offered: [UsageSpendPeriod]
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let period = UsageSpendPeriod.effective(self.selection.spendPeriod, offered: self.offered)
        let range = self.selection.customRange
        if self.provider.hasSpend {
            let models = self.provider.modelLines(for: period, customRange: range)
            UsageModelRows(
                title: "By model · \(range.map { "\($0.dayCount) days" } ?? period.short)",
                lines: models.0,
                total: models.1,
                nameWidth: UsageOverviewPeriodLayer.nameWidth)
        } else {
            UsageSectionLabel(text: "By model")
            UsageNote(text: "No \(self.provider.title) calls recorded on this Mac yet.")
        }
    }
}
