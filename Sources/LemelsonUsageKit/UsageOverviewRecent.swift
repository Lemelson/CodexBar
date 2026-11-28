import Foundation
import SwiftUI

// Overview → Limits, the top row: what every account used lately, you against others, added up from the
// start of the range (`state.overviewTimeline`, `usage/timeline.py`).
//
//   UsageOverviewRecent           the model, computed once per summary: one `Layer` per span and unit
//   UsageOverviewRecentView       title and [24h | 72h | 7d], "Cumulative in" [API $ | Quotas], and the layers
//   UsageOverviewRecentLayerView  three tiles, the hint line and the chart of one span in one unit
//   UsageOverviewRecentChart      the areas, lines and axes: a Canvas that depends on its layer only
//   UsageOverviewRecentPanelView  the hover panel: every account at the pointed-at time
//
// As on Spend, a switch never rebuilds a chart: all six layers are laid out once, only small leaves observe
// the selections and the pointer, and a switch flips opacities. The chart is only pointed at: there is no
// drag and no zoom (`UsageChartPointer.Handlers.hoverOnly`).

// MARK: - What the page and the chart are switched by

/// Overview's two pages: every account's limits, or what the subscriptions cost.
public enum UsageOverviewMode: String, CaseIterable, Identifiable, Sendable {
    case limits, spend

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .limits: "Limits"
        case .spend: "Spend"
        }
    }

    /// Where the last shown mode is kept.
    public static let defaultsKey = "lemelsonOverviewMode"
    /// `defaults write com.steipete.codexbar lemelsonOverviewLimits off` brings back the Spend-only Overview
    /// without a mode row.
    public static let enabledKey = "lemelsonOverviewLimits"

    /// False after the rollback above: Overview is then the one Spend page it was.
    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: self.enabledKey) else { return true }
        if let text = value as? String {
            return !["off", "no", "false", "0"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return (value as? Bool) ?? true
    }

    /// The mode Overview opens in: the last one shown, Limits the first time.
    public static func stored(in defaults: UserDefaults = .standard) -> UsageOverviewMode {
        defaults.string(forKey: self.defaultsKey).flatMap(UsageOverviewMode.init(rawValue:)) ?? .limits
    }
}

/// How far back the cumulative chart goes; the raw value is the range's name in `overviewTimeline.ranges`.
public enum UsageOverviewRecentSpan: String, CaseIterable, Identifiable, Sendable {
    case h24 = "24h"
    case h72 = "72h"
    case d7 = "7d"

    public var id: String {
        self.rawValue
    }

    public var title: String {
        self.rawValue
    }

    /// "24 hours", "7 days".
    public var long: String {
        switch self {
        case .h24: "24 hours"
        case .h72: "72 hours"
        case .d7: "7 days"
        }
    }
}

/// What the cumulative chart counts.
public enum UsageOverviewRecentUnit: String, CaseIterable, Identifiable, Sendable {
    /// Dollars at API prices: this Mac's spend, and others' use at each account's measured rate.
    case usd
    /// Whole weekly limits: every account's points of its weekly limit, divided by 100 and added up. Shown
    /// as "2.22 limits", never as weeks: 5.17 over seven days is five accounts' limits, not five weeks.
    case quotas

    public var id: String {
        self.rawValue
    }

    public var title: String {
        switch self {
        case .usd: "API $"
        case .quotas: "Quotas"
        }
    }
}

extension EnvironmentValues {
    /// Only for the PNG preview, which cannot move a pointer: the cumulative chart draws this sample as
    /// pointed at. Nil in the app.
    @Entry public var usagePreviewHoveredRecent: Int? = nil
}

// MARK: - The model

public struct UsageOverviewRecent: Sendable, Equatable {
    /// The chart's id with the pointer router and the row id of the chart in the menu; its hover panel is
    /// registered under `panelKey`.
    public static let chartID = "lemelsonOverview-limits-recent"
    public static let panelKey = UsageDayDetailCatalog.panelKey(for: UsageOverviewRecent.chartID)
    public static let unavailableNote = "Cumulative timeline appears after the next collector update."

    /// The cumulative use at one grid point, in the layer's unit.
    public struct Point: Sendable, Equatable {
        public let time: Double
        public let you: Double
        public let others: Double
        public let unknown: Double

        public var total: Double {
            self.you + self.others + self.unknown
        }
    }

    public struct Tile: Sendable, Equatable, Identifiable {
        public enum Swatch: Sendable, Equatable {
            case you, others, none
        }

        public let id: String
        public let title: String
        public let swatch: Swatch
        /// "$569", "≈$142", "0.42".
        public let value: String
        /// What `value` counts when it is no dollars: "limits", "limit". Drawn smaller, after the number.
        public let unit: String?
        public let caption: String

        /// "$569", "0.42 limits".
        public var text: String {
            self.unit.map { "\(self.value) \($0)" } ?? self.value
        }
    }

    public struct Tick: Sendable, Equatable, Identifiable {
        public let time: Double
        public let label: String

        public var id: Double {
            self.time
        }
    }

    /// One span in one unit: everything its tiles, hint and chart draw.
    public struct Layer: Sendable, Equatable, Identifiable {
        public let span: UsageOverviewRecentSpan
        public let unit: UsageOverviewRecentUnit
        public let points: [Point]
        /// The top of the Y axis: a round number at or above the highest total.
        public let top: Double
        public let from: Double
        public let to: Double
        public let tiles: [Tile]
        public let ticks: [Tick]

        public var id: String {
            "\(self.span.rawValue)-\(self.unit.rawValue)"
        }

        /// The sample nearest to `index`, when the layer has any.
        public func point(at index: Int) -> Point? {
            guard !self.points.isEmpty else { return nil }
            return self.points[min(max(0, index), self.points.count - 1)]
        }

        /// "Sat 14:30 · You $312 · Others ≈$80"; in quotas "Sat 14:30 · You 0.16 · Others 0.40 · 0.40 not
        /// split · limits": the unit once, so the line fits.
        public func hint(at index: Int) -> String? {
            guard let point = self.point(at: index) else { return nil }
            let unit = self.unit
            var parts = [UsageFormat.weekdayTime(point.time)]
            switch unit {
            case .usd:
                parts.append("You \(UsageFormat.usd(point.you))")
                parts.append("Others ≈\(UsageFormat.usd(point.others))")
            case .quotas:
                parts.append("You \(UsageOverviewRecent.number(point.you))")
                parts.append("Others \(UsageOverviewRecent.number(point.others))")
                if point.unknown >= 0.005 {
                    parts.append("\(UsageOverviewRecent.number(point.unknown)) not split")
                }
                parts.append("limits")
            }
            return parts.joined(separator: " · ")
        }

        /// The axis marks: zero, half-way and the top.
        public var axisMarks: [Double] {
            [0, self.top / 2, self.top]
        }

        /// "$0", "$600", "$1,200" (the way Spend's charts write dollars); "0", "0.25", "0.5", "2.5", "5".
        public func axisLabel(_ value: Double) -> String {
            switch self.unit {
            case .usd: "$" + UsageOverviewRecent.axisNumber(value, grouped: true)
            case .quotas: UsageOverviewRecent.axisNumber(value)
            }
        }

        /// Room for the Y labels at the left: as wide as the longest one needs ("$600" fits the usual 30 pt,
        /// "$12,000" gets more), so a label is never cut at the chart's edge.
        public var gutter: CGFloat {
            let longest = self.axisMarks.map { self.axisLabel($0).count }.max() ?? 0
            return max(30, CGFloat(longest) * 5.4 + 7)
        }
    }

    /// One account of the hover panel.
    public struct AccountLine: Sendable, Equatable, Identifiable {
        /// The account's key in the timeline: "claude:<uuid>".
        public let id: String
        public let name: String
        /// "Claude", "Codex", "Antigravity".
        public let providerTitle: String
        /// "Max 20x", "Pro 5x"; nil without a plan name.
        public let plan: String?
        public let rated: Bool
        /// The time of the last reading the account's quota series reaches; nil without one.
        public let quotaThrough: Double?

        public init(
            id: String, name: String, providerTitle: String, plan: String?, rated: Bool,
            quotaThrough: Double? = nil)
        {
            self.id = id
            self.name = name
            self.providerTitle = providerTitle
            self.plan = plan
            self.rated = rated
            self.quotaThrough = quotaThrough
        }

        /// The account is the provider's only one and carries its name ("Antigravity"), so the provider is
        /// not said twice.
        public var isNamedAfterProvider: Bool {
            UsageOverviewRecent.sameName(self.name, self.providerTitle)
        }

        /// "Claude Max 20x", "Codex Pro 5x"; "Ultra 5x" after the name "Antigravity".
        public var subtitle: String {
            UsageOverviewRecent.subtitle(name: self.name, providerTitle: self.providerTitle, plan: self.plan)
        }

        /// The account in a sentence: "Misha (Codex)"; "Antigravity" when the name is the provider's.
        public var mention: String {
            self.isNamedAfterProvider ? self.name : "\(self.name) (\(self.providerTitle))"
        }
    }

    public let timeline: UsagePanelState.OverviewTimeline?
    /// Six layers (three spans in two units) with a timeline, none without one.
    public let layers: [Layer]
    public let accounts: [AccountLine]

    /// The timeline has at least one range with samples: without one there is no chart to switch or point at.
    public var isAvailable: Bool {
        self.layers.contains { !$0.points.isEmpty }
    }

    public init(state: UsagePanelState, accounts: [UsageOverviewLimitAccount] = []) {
        let timeline = state.overviewTimeline
        self.timeline = timeline
        guard let timeline else {
            self.layers = []
            self.accounts = []
            return
        }
        var layers: [Layer] = []
        for span in UsageOverviewRecentSpan.allCases {
            for unit in UsageOverviewRecentUnit.allCases {
                layers.append(Self.layer(
                    span: span, unit: unit, range: timeline.range(span.rawValue), entries: timeline.accounts))
            }
        }
        self.layers = layers
        let known = Dictionary(accounts.map { ($0.timelineKey, $0) }, uniquingKeysWith: { first, _ in first })
        self.accounts = timeline.accounts.map { entry in
            if let account = known[entry.key] {
                return AccountLine(
                    id: entry.key, name: account.name, providerTitle: account.provider.title, plan: account.plan,
                    rated: entry.rated, quotaThrough: entry.quotaThrough)
            }
            let kind = UsageOverviewProviderKind(rawValue: entry.provider)
            return AccountLine(
                id: entry.key,
                name: entry.short ?? String((entry.uuid ?? entry.key).prefix(8)),
                providerTitle: kind?.title ?? entry.provider.capitalized,
                plan: kind?.spec?.shortPlan(entry.planName) ?? entry.planName,
                rated: entry.rated,
                quotaThrough: entry.quotaThrough)
        }
    }

    /// The account of a timeline key, as the hover panel names it.
    public func account(_ key: String) -> AccountLine? {
        self.accounts.first { $0.id == key }
    }

    public func layer(_ span: UsageOverviewRecentSpan, _ unit: UsageOverviewRecentUnit) -> Layer? {
        self.layers.first { $0.span == span && $0.unit == unit }
    }
}

// MARK: - Building a layer

extension UsageOverviewRecent {
    static func layer(
        span: UsageOverviewRecentSpan,
        unit: UsageOverviewRecentUnit,
        range: UsagePanelState.OverviewTimeline.Range?,
        entries: [UsagePanelState.OverviewTimeline.Entry] = []) -> Layer
    {
        guard let range else {
            return Layer(span: span, unit: unit, points: [], top: 1, from: 0, to: 0, tiles: self.tiles(
                unit: unit, combined: nil, last: nil, entries: []), ticks: [])
        }
        let combined = range.combined
        let available = unit == .usd ? combined.usdYou.count : combined.quota.count
        let count = available == 0 ? 0 : range.count
        let points: [Point] = (0..<count).map { index in
            let time = range.time(at: index)
            switch unit {
            case .usd:
                return Point(
                    time: time,
                    you: combined.usdYou(at: index) ?? 0,
                    others: combined.usdOthers(at: index) ?? 0,
                    unknown: 0)
            case .quotas:
                let sample = combined.sample(at: index)
                return Point(
                    time: time,
                    you: sample?.you ?? 0,
                    others: sample?.others ?? 0,
                    unknown: sample?.unknown ?? 0)
            }
        }
        let highest = points.map(\.total).max() ?? 0
        return Layer(
            span: span,
            unit: unit,
            points: points,
            top: self.roundTop(highest, floor: unit == .usd ? 1 : 0.1),
            from: range.from,
            to: range.to,
            tiles: self.tiles(unit: unit, combined: combined, last: points.last, entries: entries),
            ticks: self.ticks(span: span, from: range.from, to: range.to))
    }

    /// The closest round number at or above `value`, whose half is round too: 569 → 600, 0.61 → 0.8.
    static func roundTop(_ value: Double, floor: Double) -> Double {
        let value = max(value, floor)
        guard value.isFinite else { return floor }
        let magnitude = pow(10, Foundation.floor(log10(value)))
        for multiple in [1, 1.2, 1.6, 2, 3, 4, 5, 6, 8, 10] where magnitude * multiple >= value * (1 - 1e-9) {
            return magnitude * multiple
        }
        return magnitude * 10
    }

    /// A weekly-limits count without its unit: "0.42", "12.3".
    static func number(_ value: Double) -> String {
        String(format: value >= 9.995 ? "%.1f" : "%.2f", value)
    }

    /// Whole weekly limits: "0.42 limits", "2.22 limits", "1.00 limit", "12.3 limits".
    static func limits(_ value: Double) -> String {
        "\(self.number(value)) \(self.limitsUnit(value))"
    }

    /// "limit" for exactly one as written ("1.00"), else "limits".
    static func limitsUnit(_ value: Double) -> String {
        self.number(value) == "1.00" ? "limit" : "limits"
    }

    /// A number of the Y axis written in full, never rounded to another one: 2.5 is "2.5" (not "2"), 0.25 is
    /// "0.25" (not "0.2"), 0.5 is "0.5", 1200 is "1,200" when `grouped`.
    static func axisNumber(_ value: Double, grouped: Bool = false) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        if abs(value - value.rounded()) < 0.005 {
            let whole = String(format: "%.0f", value)
            return grouped ? self.grouping(whole) : whole
        }
        if value < 1 {
            let text = String(format: "%.2f", value)
            return text.hasSuffix("0") ? String(text.dropLast()) : text
        }
        let text = String(format: "%.1f", value)
        guard grouped, let dot = text.firstIndex(of: ".") else { return text }
        return self.grouping(String(text[..<dot])) + text[dot...]
    }

    /// "12000" → "12,000".
    private static func grouping(_ digits: String) -> String {
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 {
                result.append(",")
            }
            result.append(character)
        }
        return String(result.reversed())
    }

    static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(rhs) == .orderedSame
    }

    /// "Claude Max 20x"; without the provider when the account's name already is it: "Ultra 5x" after
    /// "Antigravity", never "Antigravity  Antigravity Ultra 5x".
    static func subtitle(name: String, providerTitle: String, plan: String?) -> String {
        let plan = plan.flatMap { $0.isEmpty ? nil : $0 }
        if self.sameName(name, providerTitle) {
            return plan ?? ""
        }
        return [providerTitle, plan].compactMap(\.self).joined(separator: " ")
    }

    private static func tiles(
        unit: UsageOverviewRecentUnit,
        combined: UsagePanelState.OverviewTimeline.Series?,
        last: Point?,
        entries: [UsagePanelState.OverviewTimeline.Entry]) -> [Tile]
    {
        func tile(
            _ id: String, _ title: String, _ swatch: Tile.Swatch, _ value: String, _ caption: String,
            unit: String? = nil) -> Tile
        {
            Tile(id: id, title: title, swatch: swatch, value: value, unit: unit, caption: caption)
        }
        guard let combined else {
            return [
                tile("you", "You", .you, "—", " "),
                tile("others", "Others", .others, "—", " "),
                tile("total", "Total", .none, "—", "no data for this range"),
            ]
        }
        // Accounts with a share nobody can be given yet (nil: an older collector that does not say).
        let unsplitAccounts = Set(combined.unknownAccounts ?? [])
        switch unit {
        case .usd:
            let you = combined.totalYouUsd ?? last?.you ?? 0
            let others = combined.totalOthersUsd ?? last?.others ?? 0
            let unrated = Set(combined.unratedAccounts)
            // An account with a rate and an unsplit share: that share may be others' and is in no dollar
            // figure, so Others is low there too.
            let rated = Set(entries.filter(\.rated).map(\.key))
            let low = unsplitAccounts.subtracting(unrated).filter { entries.isEmpty || rated.contains($0) }.count
            let othersCaption: String = switch (unrated.count, low) {
            case (0, 0): "estimate"
            case (let count, 0): "excl. \(count) account\(count == 1 ? "" : "s")"
            case (0, _): "excl. unsplit use"
            case let (count, _): "excl. \(count) + unsplit"
            }
            return [
                tile("you", "You", .you, UsageFormat.usd(you), combined.totalYouTokens.map {
                    "\(UsageFormat.tokens($0)) tokens"
                } ?? "this Mac"),
                tile("others", "Others", .others, "≈" + UsageFormat.usd(others), othersCaption),
                tile("total", "Total", .none, "≈" + UsageFormat.usd(you + others),
                     unrated.isEmpty && low == 0 ? "all accounts" : "what has a price"),
            ]
        case .quotas:
            let you = combined.totalYouQuota ?? last?.you ?? 0
            let others = combined.totalOthersQuota ?? last?.others ?? 0
            let unknown = combined.totalUnknownQuota ?? last?.unknown ?? 0
            let total = you + others + unknown
            let unsplit = total > 0 ? unknown / total * 100 : 0
            let count = unsplitAccounts.count
            let totalCaption: String = if unsplit >= 0.5 {
                // "42% not split · 2 accts" when the collector names the accounts.
                "\(UsageFormat.percent(unsplit)) not split" + (count > 0 ? " · \(count) acct\(count == 1 ? "" : "s")" : "")
            } else if count > 0 {
                "<1% not split"
            } else {
                "weekly limits"
            }
            // With an unsplit share, what is proven is a floor for either side.
            let floor = unsplit >= 0.5
            return [
                tile("you", "You", .you, self.number(you), "this Mac", unit: self.limitsUnit(you)),
                tile("others", "Others", .others, self.number(others), floor ? "at least" : "not this Mac",
                     unit: self.limitsUnit(others)),
                tile("total", "Total", .none, self.number(total), totalCaption, unit: self.limitsUnit(total)),
            ]
        }
    }

    /// 24 hours: every six hours of the local clock. 72 hours and 7 days: every local midnight, by weekday.
    private static func ticks(span: UsageOverviewRecentSpan, from: Double, to: Double) -> [Tick] {
        guard to > from else { return [] }
        let calendar = Calendar.current
        let start = Date(timeIntervalSince1970: from)
        let end = Date(timeIntervalSince1970: to)
        var ticks: [Tick] = []
        switch span {
        case .h24:
            var date = calendar.dateInterval(of: .hour, for: start)?.start ?? start
            while date <= end, ticks.count < 12 {
                if date >= start, calendar.component(.hour, from: date) % 6 == 0 {
                    ticks.append(Tick(time: date.timeIntervalSince1970, label: UsageFormat.clock(date)))
                }
                guard let next = calendar.date(byAdding: .hour, value: 1, to: date) else { break }
                date = next
            }
        case .h72, .d7:
            var date = calendar.startOfDay(for: start)
            while date <= end, ticks.count < 12 {
                if date >= start {
                    ticks.append(Tick(time: date.timeIntervalSince1970, label: UsageFormat.weekday(date)))
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
                date = next
            }
        }
        return ticks
    }
}

// MARK: - The row

public struct UsageOverviewRecentView: View {
    let recent: UsageOverviewRecent
    let width: CGFloat

    /// The row's height with a timeline, whatever the span and the unit: the menu never measures it twice.
    public static let height: CGFloat = 236
    /// Without a timeline: the title and one note.
    public static let unavailableHeight: CGFloat = 70
    static let title = "You vs others · all accounts"

    public init(recent: UsageOverviewRecent, width: CGFloat) {
        self.recent = recent
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center) {
                Text(Self.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 6)
                if self.recent.isAvailable {
                    UsageOverviewRecentSpanControl()
                }
            }
            .frame(height: 22)
            if self.recent.isAvailable {
                HStack(alignment: .center) {
                    Text("Cumulative in")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    UsageOverviewRecentUnitControl()
                }
                .frame(height: 20)
                UsageOverviewRecentStack(recent: self.recent)
            } else {
                UsageNote(text: UsageOverviewRecent.unavailableNote)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 5)
        .frame(
            width: self.width,
            height: self.recent.isAvailable ? Self.height : Self.unavailableHeight,
            alignment: .topLeading)
    }
}

/// [24h | 72h | 7d]: a leaf of its own, so a switch re-renders nothing else.
private struct UsageOverviewRecentSpanControl: View {
    @ObservedObject private var selection = UsageOverviewSelection.shared

    var body: some View {
        UsageSegmentedControl(
            options: Array(UsageOverviewRecentSpan.allCases),
            title: \.title,
            selection: self.$selection.recentSpan)
            .fixedSize()
    }
}

/// [API $ | Quotas].
private struct UsageOverviewRecentUnitControl: View {
    @ObservedObject private var selection = UsageOverviewSelection.shared

    var body: some View {
        UsageSegmentedControl(
            options: Array(UsageOverviewRecentUnit.allCases),
            title: \.title,
            selection: self.$selection.recentUnit)
            .fixedSize()
    }
}

/// All six layers laid out, one visible. Only this leaf observes the span and the unit.
private struct UsageOverviewRecentStack: View {
    let recent: UsageOverviewRecent
    @ObservedObject private var selection = UsageOverviewSelection.shared
    @Environment(\.usageChartLayerShown) private var layerShown

    var body: some View {
        let span = self.selection.recentSpan
        let unit = self.selection.recentUnit
        ZStack(alignment: .topLeading) {
            ForEach(self.recent.layers) { layer in
                let shown = layer.span == span && layer.unit == unit
                UsageOverviewRecentLayerView(layer: layer)
                    .equatable()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                    .environment(\.usageChartLayerShown, shown && self.layerShown)
            }
        }
        .transaction { $0.animation = nil }
    }
}

// MARK: - One layer

/// Tiles, hint and chart of one span in one unit. Pure data in, so `.equatable()` skips it on a switch.
struct UsageOverviewRecentLayerView: View, Equatable {
    let layer: UsageOverviewRecent.Layer

    static let tileHeight: CGFloat = 44
    static let hintHeight: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ForEach(self.layer.tiles) { tile in
                    UsageOverviewRecentTile(tile: tile)
                }
            }
            .frame(height: Self.tileHeight)
            UsageOverviewRecentHint(layer: self.layer)
                .frame(height: Self.hintHeight)
            UsageOverviewRecentChart(layer: self.layer)
                .equatable()
                .overlay {
                    UsageOverviewRecentPointerOverlay(layer: self.layer)
                }
        }
    }
}

/// "■ You / $569 / 960M tokens": the same three lines in every tile, so every layer has one height.
private struct UsageOverviewRecentTile: View {
    let tile: UsageOverviewRecent.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                switch self.tile.swatch {
                case .you:
                    RoundedRectangle(cornerRadius: 2).fill(UsagePalette.you).frame(width: 7, height: 7)
                case .others:
                    RoundedRectangle(cornerRadius: 2).fill(UsagePalette.others).frame(width: 7, height: 7)
                case .none:
                    EmptyView()
                }
                Text(self.tile.title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(self.tile.value)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                if let unit = self.tile.unit {
                    // "limits": smaller than the number, so "0.42 limits" keeps the number's size.
                    Text(unit)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Text(self.tile.caption)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.8)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "Point at the chart for any time.", or the pointed-at time with its values. Only the visible layer's hint
/// follows the pointer (`UsageOverviewRecentLiveHint`): the five hidden layers keep the resting line and
/// observe nothing.
private struct UsageOverviewRecentHint: View {
    let layer: UsageOverviewRecent.Layer
    @Environment(\.usageChartLayerShown) private var shown
    @Environment(\.usagePreviewHoveredRecent) private var previewIndex

    var body: some View {
        if self.shown {
            UsageOverviewRecentLiveHint(layer: self.layer, previewIndex: self.previewIndex)
        } else {
            UsageOverviewRecentHintText(text: Self.resting(self.layer))
        }
    }

    static func resting(_ layer: UsageOverviewRecent.Layer) -> String {
        layer.points.isEmpty ? "No data for this range yet." : "Point at the chart for any time."
    }
}

/// The hint of the visible layer: a leaf that follows the pointer.
private struct UsageOverviewRecentLiveHint: View {
    let layer: UsageOverviewRecent.Layer
    let previewIndex: Int?
    @ObservedObject private var focus = UsageDayFocus.shared

    var body: some View {
        let index = UsageOverviewRecent.hoveredIndex(focus: self.focus, shown: true) ?? self.previewIndex
        UsageOverviewRecentHintText(
            text: index.flatMap { self.layer.hint(at: $0) } ?? UsageOverviewRecentHint.resting(self.layer))
    }
}

private struct UsageOverviewRecentHintText: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
    }
}

extension UsageOverviewRecent {
    /// The sample the pointer is over, while the cumulative chart is the pointed-at one.
    @MainActor
    static func hoveredIndex(focus: UsageDayFocus, shown: Bool) -> Int? {
        guard shown, focus.activeChartID == self.chartID else { return nil }
        return focus.hoveredDayKey.flatMap(Int.init)
    }
}

// MARK: - The chart

/// Where the plot sits inside the chart's frame: shared by the drawing, the hover marks and the pointer.
struct UsageOverviewRecentGeometry {
    static let plotHeight: CGFloat = 88
    static let axisHeight: CGFloat = 16
    /// Room for the end dot at the right.
    static let trailing: CGFloat = 6
    static let height: CGFloat = plotHeight + axisHeight

    let plot: CGRect
    let count: Int
    let top: Double

    init(size: CGSize, layer: UsageOverviewRecent.Layer) {
        // The gutter is the layer's own: as wide as its longest Y label.
        let gutter = layer.gutter
        self.plot = CGRect(
            x: gutter,
            y: 3,
            width: max(1, size.width - gutter - Self.trailing),
            height: Self.plotHeight - 3)
        self.count = layer.points.count
        self.top = layer.top
    }

    func x(_ index: Int) -> CGFloat {
        self.plot.minX + self.plot.width * CGFloat(index) / CGFloat(max(1, self.count - 1))
    }

    func x(time: Double, from: Double, to: Double) -> CGFloat {
        self.plot.minX + self.plot.width * CGFloat((time - from) / max(1, to - from))
    }

    func y(_ value: Double) -> CGFloat {
        self.plot.maxY - self.plot.height * CGFloat(min(1, max(0, value / self.top)))
    }

    /// The sample under an x position; nil outside the plot or without samples.
    func index(atX x: CGFloat) -> Int? {
        guard self.count > 0, x >= self.plot.minX - 0.5, x <= self.plot.maxX + 0.5 else { return nil }
        let share = (x - self.plot.minX) / self.plot.width
        return min(self.count - 1, max(0, Int((share * CGFloat(self.count - 1)).rounded())))
    }
}

/// You (orange area and line), others (grey band above it), not split (hatched band above that, quotas only)
/// and the total line with a dot at its end. Depends on its layer only: pointing never redraws it.
struct UsageOverviewRecentChart: View, Equatable {
    let layer: UsageOverviewRecent.Layer

    var body: some View {
        Canvas { context, size in
            let layer = self.layer
            let geometry = UsageOverviewRecentGeometry(size: size, layer: layer)
            let plot = geometry.plot
            Self.drawAxes(in: &context, layer: layer, geometry: geometry)
            let points = layer.points
            guard points.count >= 2 else { return }

            typealias Level = (UsageOverviewRecent.Point) -> Double
            func band(_ low: Level, _ high: Level) -> Path {
                var path = Path()
                for (index, point) in points.enumerated() {
                    let spot = CGPoint(x: geometry.x(index), y: geometry.y(high(point)))
                    if index == 0 { path.move(to: spot) } else { path.addLine(to: spot) }
                }
                for (index, point) in points.enumerated().reversed() {
                    path.addLine(to: CGPoint(x: geometry.x(index), y: geometry.y(low(point))))
                }
                path.closeSubpath()
                return path
            }
            func line(_ value: (UsageOverviewRecent.Point) -> Double) -> Path {
                var path = Path()
                for (index, point) in points.enumerated() {
                    let spot = CGPoint(x: geometry.x(index), y: geometry.y(value(point)))
                    if index == 0 { path.move(to: spot) } else { path.addLine(to: spot) }
                }
                return path
            }

            context.fill(band({ _ in 0 }, { $0.you }), with: .color(UsagePalette.you.opacity(0.30)))
            context.fill(
                band({ $0.you }, { $0.you + $0.others }),
                with: .color(UsagePalette.others.opacity(0.45)))
            if points.contains(where: { $0.unknown > 0 }) {
                let unsplit = band({ $0.you + $0.others }, { $0.total })
                context.fill(unsplit, with: .color(UsagePalette.track))
                var clipped = context
                clipped.clip(to: unsplit)
                UsageHatch.draw(in: clipped, rect: plot)
            }
            context.stroke(
                line { $0.you },
                with: .color(UsagePalette.you),
                style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            context.stroke(
                line { $0.total },
                with: .color(.primary),
                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            if let last = points.last {
                let center = CGPoint(x: geometry.x(points.count - 1), y: geometry.y(last.total))
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)),
                    with: .color(.primary))
            }
        }
        .frame(height: UsageOverviewRecentGeometry.height)
        .accessibilityHidden(true)
    }

    private static func drawAxes(
        in context: inout GraphicsContext,
        layer: UsageOverviewRecent.Layer,
        geometry: UsageOverviewRecentGeometry)
    {
        let plot = geometry.plot
        for mark in layer.axisMarks {
            let y = geometry.y(mark)
            context.fill(
                Path(CGRect(x: plot.minX, y: y - 0.25, width: plot.width, height: 0.5)),
                with: .color(Color.primary.opacity(mark == 0 ? 0.18 : 0.08)))
            context.draw(
                Text(layer.axisLabel(mark)).font(.system(size: 9)).foregroundStyle(.secondary),
                at: CGPoint(x: plot.minX - 4, y: y),
                anchor: .trailing)
        }
        for tick in layer.ticks {
            let x = geometry.x(time: tick.time, from: layer.from, to: layer.to)
            context.fill(
                Path(CGRect(x: x - 0.25, y: plot.maxY, width: 0.5, height: 3)),
                with: .color(Color.primary.opacity(0.18)))
            // A label at either end stays inside the plot.
            let anchor: UnitPoint = x > plot.maxX - 14 ? .topTrailing : (x < plot.minX + 14 ? .topLeading : .top)
            context.draw(
                Text(tick.label).font(.system(size: 9)).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: plot.maxY + 4),
                anchor: anchor)
        }
    }
}

/// Over the chart: the mark of the pointed-at time, and the chart's registration with the pointer router
/// while its layer is the visible one. Hidden layers have no anchor, so they never react to the pointer.
private struct UsageOverviewRecentPointerOverlay: View {
    let layer: UsageOverviewRecent.Layer
    @Environment(\.usageChartLayerShown) private var shown

    var body: some View {
        GeometryReader { proxy in
            let geometry = UsageOverviewRecentGeometry(size: proxy.size, layer: self.layer)
            ZStack(alignment: .topLeading) {
                UsageOverviewRecentMark(layer: self.layer, geometry: geometry)
                if self.shown, self.layer.points.count >= 2 {
                    UsageChartAnchor(
                        chartID: UsageOverviewRecent.chartID,
                        handlers: .hoverOnly(
                            panelKey: UsageOverviewRecent.panelKey,
                            plotBoundsInView: { geometry.plot },
                            key: { localX in geometry.index(atX: localX).map(String.init) }))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// A hairline at the pointed-at time with a dot on "you" and on the total. Only the visible layer mounts the
/// leaf that follows the pointer; a hidden layer draws nothing and observes nothing.
private struct UsageOverviewRecentMark: View {
    let layer: UsageOverviewRecent.Layer
    let geometry: UsageOverviewRecentGeometry
    @Environment(\.usageChartLayerShown) private var shown
    @Environment(\.usagePreviewHoveredRecent) private var previewIndex

    var body: some View {
        if self.shown {
            UsageOverviewRecentLiveMark(layer: self.layer, geometry: self.geometry, previewIndex: self.previewIndex)
        }
    }
}

private struct UsageOverviewRecentLiveMark: View {
    let layer: UsageOverviewRecent.Layer
    let geometry: UsageOverviewRecentGeometry
    let previewIndex: Int?
    @ObservedObject private var focus = UsageDayFocus.shared

    var body: some View {
        let index = UsageOverviewRecent.hoveredIndex(focus: self.focus, shown: true) ?? self.previewIndex
        let geometry = self.geometry
        let point = index.flatMap { self.layer.point(at: $0) }
        let spot = index.map { min(max(0, $0), max(0, self.layer.points.count - 1)) }
        Canvas { context, _ in
            guard let point, let spot else { return }
            let x = geometry.x(spot)
            let plot = geometry.plot
            context.fill(
                Path(CGRect(x: x - 0.5, y: plot.minY, width: 1, height: plot.height)),
                with: .color(Color.primary.opacity(0.35)))
            for (value, color) in [(point.you, UsagePalette.you), (point.total, Color.primary)] {
                let center = CGPoint(x: x, y: geometry.y(value))
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                    with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .transaction { $0.animation = nil }
    }
}

// MARK: - The hover panel

/// Every account at the pointed-at time: what this Mac and others used since the range began, in dollars and
/// in percent of that account's weekly limit.
public struct UsageOverviewRecentPanelView: View {
    let recent: UsageOverviewRecent
    let width: CGFloat
    /// The PNG preview cannot move a pointer: the sample it draws.
    let previewIndex: Int?
    @ObservedObject private var focus = UsageDayFocus.shared
    @ObservedObject private var selection = UsageOverviewSelection.shared

    public init(
        recent: UsageOverviewRecent,
        width: CGFloat = UsageHoverPanelController.panelWidth,
        previewIndex: Int? = nil)
    {
        self.recent = recent
        self.width = width
        self.previewIndex = previewIndex
    }

    private typealias Timeline = UsagePanelState.OverviewTimeline

    public var body: some View {
        let span = self.selection.recentSpan
        let range = self.recent.timeline?.range(span.rawValue)
        VStack(alignment: .leading, spacing: 10) {
            if let range {
                self.content(range, span: span)
            } else {
                UsagePanelTitle(title: "All accounts", subtitle: "No data for the last \(span.long) yet.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .topLeading)
        .transaction { $0.animation = nil }
    }

    /// The pointed-at sample: the preview's, the pointer's, the last one pointed at, or the end of the range.
    private func index(in range: Timeline.Range) -> Int {
        let last = max(0, range.count - 1)
        let mine = self.focus.activeChartID == UsageOverviewRecent.chartID
        let pointed = self.previewIndex
            ?? (mine ? self.focus.hoveredDayKey.flatMap(Int.init) : nil)
            ?? self.focus.lastDayKeys[UsageOverviewRecent.chartID].flatMap(Int.init)
        return min(last, max(0, pointed ?? last))
    }

    @ViewBuilder
    private func content(_ range: Timeline.Range, span: UsageOverviewRecentSpan) -> some View {
        let index = self.index(in: range)
        let combined = range.combined
        let sample = combined.sample(at: index)
        // One scale for every account's bar: the largest use at the end of the range.
        let scale = max(1, range.accounts.values.compactMap { $0.sample(at: range.count - 1)?.total }.max() ?? 1)
        UsagePanelTitle(
            title: "All accounts · \(UsageFormat.weekdayTime(range.time(at: index)))",
            subtitle: "Used since \(UsageFormat.weekdayTime(range.from)), the last \(span.long).")
        VStack(alignment: .leading, spacing: 2) {
            Text("You \(UsageFormat.usd(combined.usdYou(at: index) ?? 0)) · "
                + "Others ≈\(UsageFormat.usd(combined.usdOthers(at: index) ?? 0))")
                .font(.system(size: 11.5, weight: .semibold))
            Text(Self.quotaLine(sample))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        Divider()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(self.recent.accounts) { account in
                self.accountBlock(account, range: range, index: index, scale: scale)
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Self.notes(self.recent, range: range), id: \.self) { note in
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Weekly limits: you 0.21 · others 0.09 · 0.01 not split".
    static func quotaLine(_ sample: UsagePanelState.OverviewTimeline.Sample?) -> String {
        guard let sample else { return "No limit readings in this range yet." }
        var text = "Weekly limits: you \(UsageOverviewRecent.number(sample.you))"
            + " · others \(UsageOverviewRecent.number(sample.others))"
        if sample.unknown >= 0.005 {
            text += " · \(UsageOverviewRecent.number(sample.unknown)) not split"
        }
        return text
    }

    /// Name and plan, the account's bar, then "You $312 · 11%", "Others ≈$80 · 3%" and the unsplit part.
    /// Always three lines, so pointing along the chart never changes the panel's height.
    private func accountBlock(
        _ account: UsageOverviewRecent.AccountLine,
        range: Timeline.Range,
        index: Int,
        scale: Double) -> some View
    {
        let series = range.accounts[account.id]
        let sample = series?.sample(at: index)
        // A limit never read in this range is "—", not a measured 0%.
        let read = Self.hasReading(sample, quotaThrough: account.quotaThrough, from: range.from)
        let usdYou = series?.usdYou(at: index)
        let usdOthers = series?.usdOthers(at: index)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(account.name)
                    .font(.system(size: 11, weight: .semibold))
                if !account.subtitle.isEmpty {
                    Text(account.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(read ? Self.points(sample?.total ?? 0) : "—")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
            }
            .lineLimit(1)
            // A part the line below writes as "0%" is no part of the bar either.
            UsageSplitBar(
                parts: UsageSplitBar.withoutSlivers(
                    [
                        (sample?.you ?? 0, UsagePalette.you),
                        (sample?.others ?? 0, UsagePalette.others),
                        (sample?.unknown ?? 0, UsagePalette.unsplitStripe),
                    ],
                    under: 0.05),
                scale: scale,
                height: 5,
                hatched: [2],
                minPartWidth: UsageSegmentBar.minSegmentWidth)
            HStack(spacing: 10) {
                UsageChip(
                    color: UsagePalette.you,
                    text: "You \(UsageFormat.usd(usdYou ?? 0))" + (read ? " · \(Self.points(sample?.you ?? 0))" : ""),
                    fontSize: 10)
                UsageChip(
                    color: UsagePalette.others,
                    text: Self.othersText(
                        usd: usdOthers, points: read ? sample?.others ?? 0 : nil, rated: account.rated),
                    fontSize: 10)
                if read, let unknown = sample?.unknown, unknown >= 0.05 {
                    UsageChip(
                        color: UsagePalette.others,
                        // Just the number: the three chips share one line, and the note under the list
                        // says what hatched means.
                        text: Self.points(unknown),
                        hatched: true,
                        fontSize: 10)
                }
            }
            .monospacedDigit()
            .frame(height: 13, alignment: .leading)
        }
    }

    /// "Others ≈$80 · 3%"; without a rate "Others 3%*"; without a reading "Others —".
    static func othersText(usd: Double?, points: Double?, rated: Bool) -> String {
        guard let points else { return "Others —" }
        return "Others " + (usd.map { "≈\(UsageFormat.usd($0)) · " } ?? "") + self.points(points) + (rated ? "" : "*")
    }

    /// Whether the account's limit was read in this range. No sample, or nothing counted on a sample that is
    /// only carried over a gap, or a series whose last reading is older than the range: no reading, which is
    /// not the same as a limit that was read and did not move.
    static func hasReading(
        _ sample: UsagePanelState.OverviewTimeline.Sample?,
        quotaThrough: Double?,
        from: Double) -> Bool
    {
        guard let sample else { return false }
        guard sample.total < 0.05 else { return true }
        if sample.flags.contains(.gap) {
            return false
        }
        guard let quotaThrough else { return false }
        return quotaThrough >= from
    }

    /// Points of a weekly limit without a needless ".0": "0%", "2%", "7.6%", "27%".
    static func points(_ value: Double) -> String {
        guard value >= 0.05 else { return "0%" }
        guard value < 9.95 else { return UsageFormat.percent(value) }
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "%"
    }

    /// What the numbers mean and what is missing from them. By range, never by the pointed-at time.
    static func notes(_ recent: UsageOverviewRecent, range: UsagePanelState.OverviewTimeline.Range) -> [String] {
        var notes = ["Percent is of each account's own weekly limit; hatched is not split yet (you or others)."]
        let unrated = recent.accounts.filter { !$0.rated }
        if !unrated.isEmpty {
            notes.append("* No dollar rate yet for \(unrated.map(\.mention).joined(separator: ", ")): "
                + "others' use there is in percent only.")
        } else {
            notes.append("Others' dollars are an estimate at each account's measured rate.")
        }
        // The collector's own list of accounts with an unsplit share; an account without a rate is already named.
        let unsplit = (range.combined.unknownAccounts ?? [])
            .compactMap { key in recent.account(key) }
            .filter(\.rated)
        if !unsplit.isEmpty {
            notes.append("Not split yet on \(unsplit.map(\.mention).joined(separator: ", ")): "
                + "that use is in neither You nor Others' dollars, so Others may be low.")
        }
        let flags = range.combined.quota.reduce(into: Timeline.Flags()) { $0.formUnion($1?.flags ?? []) }
        if flags.contains(.incomplete) || !(recent.timeline?.partialProviders ?? []).isEmpty {
            notes.append("This Mac's logs do not cover the whole range, so You may be low.")
        }
        if flags.contains(.boundary) {
            notes.append("Use that began before the range and was read inside it is left out.")
        }
        return notes
    }
}
