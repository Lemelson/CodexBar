import Foundation
import SwiftUI

// MARK: - What the pointer is on: shared by the charts, their captions and the day panel

/// The day pointed at on a per-day spend chart, and the span being dragged across it. Written by
/// `UsageChartPointer` only; read by the chart's highlight overlay, its caption and the day panel, which
/// are small leaves, so scrubbing across bars never rebuilds a chart.
///
/// `activeChartID` is the page's chart id (one id for all period layers of a page: only the shown one tracks).
@MainActor
public final class UsageDayFocus: ObservableObject {
    public static let shared = UsageDayFocus()

    @Published public var activeChartID: String?
    @Published public var hoveredDayKey: String?
    /// The span under a drag, while it is being dragged; one day until the pointer crosses into another.
    @Published public var dragRange: UsageSpendRange?
    @Published public var isDragging = false

    /// The last day pointed at, by chart id. Not cleared when the pointer leaves: the day panel keeps showing
    /// that day while it fades out, so it never flashes empty.
    public private(set) var lastDayKeys: [String: String] = [:]

    public init() {}

    /// The pointer is over `dayKey` of chart `chartID` (nil: over the chart, between days or past its end).
    public func hover(chartID: String, dayKey: String?) {
        if let dayKey {
            self.lastDayKeys[chartID] = dayKey
        }
        if self.activeChartID != chartID {
            self.activeChartID = chartID
        }
        if self.hoveredDayKey != dayKey {
            self.hoveredDayKey = dayKey
        }
        if self.isDragging {
            self.isDragging = false
        }
        if self.dragRange != nil {
            self.dragRange = nil
        }
    }

    /// A drag on chart `chartID` is at `dayKey` and spans `range`.
    public func drag(chartID: String, dayKey: String, range: UsageSpendRange?) {
        self.lastDayKeys[chartID] = dayKey
        if self.activeChartID != chartID {
            self.activeChartID = chartID
        }
        if self.hoveredDayKey != dayKey {
            self.hoveredDayKey = dayKey
        }
        if !self.isDragging {
            self.isDragging = true
        }
        if self.dragRange != range {
            self.dragRange = range
        }
    }

    public func clear() {
        if self.activeChartID != nil {
            self.activeChartID = nil
        }
        if self.hoveredDayKey != nil {
            self.hoveredDayKey = nil
        }
        if self.dragRange != nil {
            self.dragRange = nil
        }
        if self.isDragging {
            self.isDragging = false
        }
    }
}

// MARK: - One day, one dragged span, one zoom

/// Everything the day panel says about one day of a chart: totals, how it compares with the shown period
/// (or the zoomed span), and up to two sections of rows (by provider or account, by model).
public struct UsageDayDetail: Sendable, Equatable {
    public struct Row: Identifiable, Sendable, Equatable {
        public let id: String
        public let label: String
        public let color: UsageSeriesColor
        public let usd: Double
        public let tokens: Double
        /// A quiet line under the row (Overview: the Claude row's accounts). Keep it non-nil on every day for a
        /// row that has one on some day, so the panel keeps its height.
        public let subtitle: String?
        /// True when the collector had no API price for this model on this day: show "no price" instead of "$0".
        public let unpriced: Bool

        public init(
            id: String,
            label: String,
            color: UsageSeriesColor,
            usd: Double,
            tokens: Double,
            subtitle: String? = nil,
            unpriced: Bool = false)
        {
            self.id = id
            self.label = label
            self.color = color
            self.usd = usd
            self.tokens = tokens
            self.subtitle = subtitle
            self.unpriced = unpriced
        }

        var use: UsageModelUse {
            UsageModelUse(usd: self.usd, tokens: self.tokens)
        }

        var isEmpty: Bool {
            self.usd < 0.005 && self.tokens <= 0
        }
    }

    public let dayKey: String
    public let date: Date
    public let isToday: Bool
    public let totalUsd: Double
    public let totalTokens: Double
    /// Days of the shown period (its chart domain) or of the zoomed span.
    public let periodDays: Int
    /// "90-day" for a preset period, "selected 12-day" for a zoom.
    public let periodLabel: String
    public let isCustomRange: Bool
    public let periodDailyAverageUsd: Double
    /// 1-based rank among the days with spend in the period; nil for a day without spend.
    public let rankInPeriod: Int?
    /// "By provider" (Overview), "By account" (Claude Spend), nil (provider pages).
    public let section1Title: String?
    public let section1Rows: [Row]
    public let section2Title: String
    public let section2Rows: [Row]
    public let otherNote: String?
    public let unpricedNote: String?

    public init(
        dayKey: String,
        date: Date,
        isToday: Bool,
        totalUsd: Double,
        totalTokens: Double,
        periodDays: Int,
        periodLabel: String,
        isCustomRange: Bool = false,
        periodDailyAverageUsd: Double,
        rankInPeriod: Int?,
        section1Title: String?,
        section1Rows: [Row],
        section2Title: String = "By model",
        section2Rows: [Row],
        otherNote: String? = nil,
        unpricedNote: String? = nil)
    {
        self.dayKey = dayKey
        self.date = date
        self.isToday = isToday
        self.totalUsd = totalUsd
        self.totalTokens = totalTokens
        self.periodDays = periodDays
        self.periodLabel = periodLabel
        self.isCustomRange = isCustomRange
        self.periodDailyAverageUsd = periodDailyAverageUsd
        self.rankInPeriod = rankInPeriod
        self.section1Title = section1Title
        self.section1Rows = section1Rows
        self.section2Title = section2Title
        self.section2Rows = section2Rows
        self.otherNote = otherNote
        self.unpricedNote = unpricedNote
    }

    /// No calls at all that day.
    public var isEmpty: Bool {
        self.totalUsd < 0.005 && self.totalTokens <= 0
    }

    /// "Today so far · Thu, Nov 27" or "Wed, Nov 26".
    public var title: String {
        let day = UsageFormat.format(self.date, "EEE, MMM d")
        return self.isToday ? "Today so far · \(day)" : day
    }

    /// "$412.30 · 1.2B tokens", or "No calls recorded this day".
    public var subtitle: String {
        if self.isEmpty {
            return "No calls recorded this day"
        }
        return "\(UsageFormat.usdFine(self.totalUsd)) · \(UsageFormat.tokens(self.totalTokens)) tokens"
    }

    /// "2.4× the 90-day daily average ($338)": a plain comparison, neither praise nor warning.
    public var comparisonLine: String {
        let average = UsageFormat.usd(self.periodDailyAverageUsd)
        if self.isEmpty {
            let label = self.periodLabel.prefix(1).uppercased() + self.periodLabel.dropFirst()
            return "\(label) daily average: \(average)"
        }
        if self.totalUsd < 0.005 {
            return "\(UsageFormat.tokens(self.totalTokens)) tokens, none of them priced."
        }
        if self.isToday {
            return "So far today · \(self.periodLabel) daily average \(average)"
        }
        guard self.periodDailyAverageUsd >= 0.005 else {
            return "The only spend of the \(self.periodLabel) span."
        }
        let ratio = self.totalUsd / self.periodDailyAverageUsd
        if (0.95...1.05).contains(ratio) {
            return "On par with the \(self.periodLabel) daily average (\(average))"
        }
        let times = if ratio < 0.1 {
            "<0.1×"
        } else if ratio < 10 {
            String(format: "%.1f×", ratio)
        } else {
            String(format: "%.0f×", ratio)
        }
        return "\(times) the \(self.periodLabel) daily average (\(average))"
    }

    /// "3rd busiest day of the last 90", "Busiest of the 12 selected days"; blank on an empty day (to keep height),
    /// "Day in progress" for today so far.
    public var rankLine: String {
        if self.isEmpty {
            return " "
        }
        if self.isToday {
            return "Day in progress"
        }
        guard let rank = self.rankInPeriod else {
            let label = self.periodLabel.prefix(1).uppercased() + self.periodLabel.dropFirst()
            return "\(label) daily average: \(UsageFormat.usd(self.periodDailyAverageUsd))"
        }
        if self.isCustomRange {
            return rank == 1
                ? "Busiest of the \(self.periodDays) selected days"
                : "\(UsageDayStats.ordinal(rank)) busiest of the \(self.periodDays) selected days"
        }
        return rank == 1
            ? "Busiest day of the last \(self.periodDays)"
            : "\(UsageDayStats.ordinal(rank)) busiest day of the last \(self.periodDays)"
    }
}

/// The busiest day of a span.
public struct UsageBusiestDay: Sendable, Equatable {
    public let date: Date
    public let use: UsageModelUse

    public init(date: Date, use: UsageModelUse) {
        self.date = date
        self.use = use
    }

    public var usd: Double {
        self.use.usd
    }
}

/// What the day panel shows while a span is dragged: its totals and sections.
public struct UsageRangeDetailPreview: Sendable, Equatable {
    public let range: UsageSpendRange
    public let totalUsd: Double
    public let totalTokens: Double
    public let dailyAverageUsd: Double
    public let busiestDay: UsageBusiestDay?
    public let section1Title: String?
    public let section1Rows: [UsageDayDetail.Row]
    public let section2Title: String
    public let section2Rows: [UsageDayDetail.Row]

    public init(
        range: UsageSpendRange,
        totalUsd: Double,
        totalTokens: Double,
        dailyAverageUsd: Double,
        busiestDay: UsageBusiestDay?,
        section1Title: String?,
        section1Rows: [UsageDayDetail.Row],
        section2Title: String = "By model",
        section2Rows: [UsageDayDetail.Row])
    {
        self.range = range
        self.totalUsd = totalUsd
        self.totalTokens = totalTokens
        self.dailyAverageUsd = dailyAverageUsd
        self.busiestDay = busiestDay
        self.section1Title = section1Title
        self.section1Rows = section1Rows
        self.section2Title = section2Title
        self.section2Rows = section2Rows
    }
}

/// The three tiles of a zoomed spend header: the span's total, its daily average and its busiest day.
public struct UsageCustomRangeSummary: Sendable, Equatable {
    public let range: UsageSpendRange
    public let total: UsageModelUse
    public let dailyAverage: UsageModelUse
    public let busiestDay: UsageBusiestDay?

    public init(range: UsageSpendRange, total: UsageModelUse, dailyAverage: UsageModelUse, busiestDay: UsageBusiestDay?) {
        self.range = range
        self.total = total
        self.dailyAverage = dailyAverage
        self.busiestDay = busiestDay
    }
}

/// Everything the day panel of one chart can ask, answered from numbers computed once per summary, so a
/// hover or a drag step costs microseconds. Built by the page's digest (`UsageSpendDigest.dayDetailCatalog`,
/// `UsageProviderSpend.dayDetailCatalog`); the hover panel registers `UsageDayDetailPanelView` under `panelKey`.
public struct UsageDayDetailCatalog: Sendable {
    public let chartID: String
    /// The hover panel entry key: `chartID + ":day"`.
    public let panelKey: String
    /// Shown before any day was pointed at (today).
    public let defaultDayKey: String
    /// A day of the shown period (the menu-wide choice, made effective by the catalog) or of the zoom.
    public let dayDetail: @Sendable (_ dayKey: String, _ period: UsageSpendPeriod, _ customRange: UsageSpendRange?) -> UsageDayDetail
    /// The span under a drag.
    public let rangePreview: @Sendable (_ range: UsageSpendRange) -> UsageRangeDetailPreview
    /// Row slots of each section, so the panel keeps one height while scrubbing; 0 leaves section 1 out.
    public let fixedSection1Rows: Int
    public let fixedSection2Rows: Int
    public let section1NameWidth: CGFloat
    public let section2NameWidth: CGFloat
    /// Keep one line for `otherNote` / `unpricedNote` on every day (pages whose days can have one).
    public let reservesNoteLine: Bool

    public init(
        chartID: String,
        defaultDayKey: String,
        fixedSection1Rows: Int,
        fixedSection2Rows: Int,
        section1NameWidth: CGFloat = 66,
        section2NameWidth: CGFloat = 40,
        reservesNoteLine: Bool = false,
        dayDetail: @escaping @Sendable (_ dayKey: String, _ period: UsageSpendPeriod, _ customRange: UsageSpendRange?) -> UsageDayDetail,
        rangePreview: @escaping @Sendable (_ range: UsageSpendRange) -> UsageRangeDetailPreview)
    {
        self.chartID = chartID
        self.panelKey = Self.panelKey(for: chartID)
        self.defaultDayKey = defaultDayKey
        self.fixedSection1Rows = fixedSection1Rows
        self.fixedSection2Rows = fixedSection2Rows
        self.section1NameWidth = section1NameWidth
        self.section2NameWidth = section2NameWidth
        self.reservesNoteLine = reservesNoteLine
        self.dayDetail = dayDetail
        self.rangePreview = rangePreview
    }

    /// The hover panel key of a chart's day panel. `UsageHoverPanelController.isShowingChartDayPanel` relies
    /// on the ":day" suffix.
    public static func panelKey(for chartID: String) -> String {
        chartID + ":day"
    }
}

// MARK: - Shared arithmetic of the digests

/// One day of a page's spend, all series together.
struct UsageDayTotal: Sendable, Equatable {
    let key: String
    let date: Date
    let use: UsageModelUse
}

enum UsageDayStats {
    /// Days, daily average and the rank of `dayKey` inside a chart domain. `days` sorted or not.
    static func context(dayKey: String, domain: ClosedRange<Date>, days: [UsageDayTotal])
        -> (count: Int, average: Double, rank: Int?)
    {
        let count = UsageSpendRange.dayCount(of: domain)
        let from = UsageDayKey.string(domain.lowerBound)
        let until = UsageDayKey.string(domain.upperBound)
        var total = 0.0
        var own = 0.0
        for day in days where day.key >= from && day.key < until {
            total += day.use.usd
            if day.key == dayKey {
                own += day.use.usd
            }
        }
        var rank: Int?
        if own >= 0.005 {
            rank = 1 + days.filter { $0.key >= from && $0.key < until && $0.use.usd > own }.count
        }
        return (count, total / Double(count), rank)
    }

    /// Total, daily average and busiest day of a span.
    static func summary(range: UsageSpendRange, days: [UsageDayTotal]) -> UsageCustomRangeSummary {
        var total = UsageModelUse()
        var busiest: UsageBusiestDay?
        for day in days where range.contains(day.key) {
            total = total + day.use
            if day.use.usd >= 0.005, day.use.usd > (busiest?.use.usd ?? 0) {
                busiest = UsageBusiestDay(date: day.date, use: day.use)
            }
        }
        let count = Double(range.dayCount)
        return UsageCustomRangeSummary(
            range: range,
            total: total,
            dailyAverage: UsageModelUse(usd: total.usd / count, tokens: total.tokens / count),
            busiestDay: busiest)
    }

    /// "90-day" for a preset period, "selected 12-day" for a zoom.
    static func label(days: Int, isCustom: Bool) -> String {
        isCustom ? "selected \(days)-day" : "\(days)-day"
    }

    /// 1st, 2nd, 3rd, 4th, 11th, 12th, 13th, 21st...
    static func ordinal(_ value: Int) -> String {
        if (11...13).contains(value % 100) {
            return "\(value)th"
        }
        switch value % 10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }
}

// MARK: - The day panel

/// Slides out left of the menu while the pointer is on a per-day chart: the pointed-at day (totals, a plain
/// comparison with the period, rows by account or provider and by model), or, during a drag, the span under it.
///
/// The hover panel lays a slot out once, so this view has one height whatever it shows: both layouts are
/// stacked (one visible), every line is one line, and the sections have fixed row slots from the catalog.
/// Changes are never animated: scrubbing across bars updates the numbers in place.
public struct UsageDayDetailPanelView: View {
    let catalog: UsageDayDetailCatalog
    let width: CGFloat
    /// The PNG preview cannot move a pointer: the day (or span) it draws.
    let previewDayKey: String?
    let previewRange: UsageSpendRange?
    @ObservedObject private var focus = UsageDayFocus.shared
    @ObservedObject private var selection = UsagePanelSelection.shared

    public init(
        catalog: UsageDayDetailCatalog,
        width: CGFloat = UsageHoverPanelController.panelWidth,
        previewDayKey: String? = nil,
        previewRange: UsageSpendRange? = nil)
    {
        self.catalog = catalog
        self.width = width
        self.previewDayKey = previewDayKey
        self.previewRange = previewRange
    }

    public var body: some View {
        let mine = self.focus.activeChartID == self.catalog.chartID
        let dragged: UsageSpendRange? = self.previewRange
            ?? (mine && self.focus.isDragging ? self.focus.dragRange : nil)
        let range = dragged.flatMap { $0.dayCount >= 2 ? $0 : nil }
        let dayKey = self.previewDayKey
            ?? (mine ? self.focus.hoveredDayKey : nil)
            ?? self.focus.lastDayKeys[self.catalog.chartID]
            ?? self.catalog.defaultDayKey
        let detail = self.catalog.dayDetail(dayKey, self.selection.spendPeriod, self.selection.customRange)
        let preview = range.map(self.catalog.rangePreview)
        ZStack(alignment: .topLeading) {
            self.dayContent(detail)
                .opacity(preview == nil ? 1 : 0)
            self.rangeContent(preview, fallback: detail)
                .opacity(preview == nil ? 0 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .topLeading)
        .transaction { $0.animation = nil }
    }

    // MARK: Day

    private func dayContent(_ detail: UsageDayDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Self.header(title: detail.title, subtitle: detail.subtitle)
            VStack(alignment: .leading, spacing: 2) {
                Self.line(detail.comparisonLine, primary: true)
                Self.line(detail.rankLine, primary: false)
            }
            self.sections(
                title1: detail.section1Title, rows1: detail.section1Rows,
                title2: detail.section2Title, rows2: detail.section2Rows,
                fine: true,
                dayEmpty: detail.isEmpty)
            if self.catalog.reservesNoteLine {
                Self.line(detail.otherNote ?? detail.unpricedNote ?? " ", primary: false, size: 10)
            }
        }
    }

    // MARK: Dragged span

    private func rangeContent(_ preview: UsageRangeDetailPreview?, fallback detail: UsageDayDetail) -> some View {
        let days = preview?.range.dayCount ?? 2
        let subtitle = preview.map {
            "\(days) days · \(UsageFormat.usd($0.totalUsd)) · \(UsageFormat.tokens($0.totalTokens)) tokens"
        } ?? " "
        return VStack(alignment: .leading, spacing: 10) {
            Self.header(title: preview?.range.shortTitle ?? " ", subtitle: subtitle)
            HStack(spacing: 14) {
                Self.stat("Daily avg", preview.map { UsageFormat.usd($0.dailyAverageUsd) } ?? "")
                if let peak = preview?.busiestDay {
                    Self.stat("Peak", "\(UsageFormat.format(peak.date, "MMM d")) (\(UsageFormat.usd(peak.usd)))")
                }
                Spacer(minLength: 0)
            }
            .frame(height: 14, alignment: .leading)
            self.sections(
                title1: preview?.section1Title ?? detail.section1Title, rows1: preview?.section1Rows ?? [],
                title2: preview?.section2Title ?? detail.section2Title, rows2: preview?.section2Rows ?? [],
                fine: false,
                dayEmpty: preview.map { $0.totalUsd < 0.005 && $0.totalTokens <= 0 } ?? false)
            Self.line("Release to zoom into these \(days) days.", primary: false, size: 10)
        }
    }

    // MARK: Parts

    private func sections(
        title1: String?, rows1: [UsageDayDetail.Row],
        title2: String, rows2: [UsageDayDetail.Row],
        fine: Bool,
        dayEmpty: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            if self.catalog.fixedSection1Rows > 0 {
                Divider()
                UsageDayDetailSection(
                    title: title1 ?? "",
                    rows: rows1,
                    slots: self.catalog.fixedSection1Rows,
                    nameWidth: self.catalog.section1NameWidth,
                    fine: fine,
                    dayEmpty: dayEmpty)
            }
            if self.catalog.fixedSection2Rows > 0 {
                Divider()
                UsageDayDetailSection(
                    title: title2,
                    rows: rows2,
                    slots: self.catalog.fixedSection2Rows,
                    nameWidth: self.catalog.section2NameWidth,
                    fine: fine,
                    dayEmpty: dayEmpty)
            }
        }
    }

    private static func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private static func line(_ text: String, primary: Bool, size: CGFloat = 10.5) -> some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(primary ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private static func stat(_ title: String, _ value: String) -> some View {
        (Text("\(title) ").foregroundStyle(.secondary) + Text(value).fontWeight(.semibold))
            .font(.system(size: 10.5))
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// One section of the day panel: column labels and exactly `slots` rows (padded with invisible ones,
/// extra ones dropped); a row without use that day is dimmed.
struct UsageDayDetailSection: View {
    let title: String
    let rows: [UsageDayDetail.Row]
    let slots: Int
    let nameWidth: CGFloat
    var fine: Bool = true
    var dayEmpty: Bool = false

    var body: some View {
        let shown = Array(self.rows.prefix(self.slots))
        let total = shown.reduce(0) { $0 + $1.usd }
        let hasSubtitles = shown.contains { $0.subtitle != nil }
        VStack(alignment: .leading, spacing: 5) {
            UsageModelHeader(title: self.title)
            ForEach(shown) { row in
                VStack(alignment: .leading, spacing: 1) {
                    UsageModelRow(
                        name: row.label,
                        use: row.use,
                        total: total,
                        color: row.color.color,
                        nameWidth: self.nameWidth,
                        fine: self.fine,
                        unpriced: row.unpriced,
                        placeholder: self.dayEmpty)
                    if let subtitle = row.subtitle {
                        Text(self.dayEmpty ? "—" : subtitle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.leading, self.nameWidth + 6)
                    }
                }
                .opacity(row.isEmpty ? 0.45 : 1)
            }
            ForEach(shown.count..<max(shown.count, self.slots), id: \.self) { _ in
                VStack(alignment: .leading, spacing: 1) {
                    UsageModelRow(name: " ", use: UsageModelUse(), total: 1, color: .clear, nameWidth: self.nameWidth)
                    if hasSubtitles {
                        Text(" ").font(.system(size: 9.5))
                    }
                }
                .hidden()
            }
        }
    }
}
