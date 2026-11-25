import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Menu row under the cursor: on the colored highlight, text and bar are drawn light.
    @Entry public var usageRowHighlighted: Bool = false
    /// Only for the PNG preview, which cannot move a pointer: per-day spend charts draw this day
    /// ("2026-11-21") as pointed at. Nil in the app.
    @Entry public var usagePreviewHoveredDay: String? = nil
}

// MARK: - Colors

/// Colors are chosen to differ in both hue and brightness: on a warm ("yellow") screen,
/// similar shades such as blue and teal or orange and peach blend together.
public enum UsagePalette {
    /// Claude Code on this Mac.
    public static let you = UsagePalette.dynamic(light: 0xE8590C, dark: 0xFF8A3D)
    /// Claude Code on the same account, but not from this Mac.
    public static let otherCode = UsagePalette.dynamic(light: 0x2563EB, dark: 0x5B9BFF)
    public static let chat = UsagePalette.dynamic(light: 0x9B4DCA, dark: 0xD08CFF)
    public static let cowork = UsagePalette.dynamic(light: 0x4D9A0E, dark: 0xA3E635)
    /// Not from this Mac, with no breakdown by source.
    public static let others = UsagePalette.dynamic(light: 0x8E8E93, dark: 0xA1A1A6)
    public static let track = Color.primary.opacity(0.10)
    public static let paceGood = UsagePalette.dynamic(light: 0x1E9E4A, dark: 0x34D058)
    public static let paceBad = UsagePalette.dynamic(light: 0xD92D20, dark: 0xFF5A4F)
    public static let warning = UsagePalette.dynamic(light: 0xB25E09, dark: 0xF2A65A)

    /// Claude models. Opus and Fable keep the orange and violet they always had. Sonnet is teal and Haiku is
    /// yellow: the two hues left free by the account colors (orange, blue, green), and on a warm screen
    /// yellow keeps apart from orange by brightness, teal from blue and green by hue.
    public static let opus = UsagePalette.you
    public static let fable = UsagePalette.chat
    public static let sonnet = UsagePalette.dynamic(light: 0x0D9488, dark: 0x2DD4BF)
    public static let haiku = UsagePalette.dynamic(light: 0xC99A06, dark: 0xFACC15)

    public static func claudeModel(_ family: UsageModelFamily) -> Color {
        switch family {
        case .opus: self.opus
        case .fable: self.fable
        case .sonnet: self.sonnet
        case .haiku: self.haiku
        case .other: self.others
        }
    }

    /// Account colors on charts: same order as in Claude Switcher.
    public static let accounts: [Color] = [
        UsagePalette.dynamic(light: 0xE8590C, dark: 0xFF8A3D),
        UsagePalette.dynamic(light: 0x2563EB, dark: 0x5B9BFF),
        UsagePalette.dynamic(light: 0x4D9A0E, dark: 0xA3E635),
        UsagePalette.dynamic(light: 0xD6409F, dark: 0xF472B6),
    ]

    public static func account(_ index: Int) -> Color {
        self.accounts[index % self.accounts.count]
    }

    /// Gemini models on the Antigravity page, most used first: the account colors in another order,
    /// so the first three differ in hue and brightness on a warm screen too. Past four: grey.
    public static let models: [Color] = [
        UsagePalette.dynamic(light: 0x2563EB, dark: 0x5B9BFF),
        UsagePalette.dynamic(light: 0x4D9A0E, dark: 0xA3E635),
        UsagePalette.dynamic(light: 0xE8590C, dark: 0xFF8A3D),
        UsagePalette.dynamic(light: 0xD6409F, dark: 0xF472B6),
    ]

    public static func model(_ index: Int) -> Color {
        self.models.indices.contains(index) ? self.models[index] : self.others
    }

    /// A limit with no split by source (Antigravity): the whole bar is one color.
    public static let single = UsagePalette.models[0]

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        })
    }
}

enum UsageInk {
    static func primary(_ highlighted: Bool) -> Color {
        highlighted ? .white : .primary
    }

    static func secondary(_ highlighted: Bool) -> Color {
        highlighted ? .white.opacity(0.84) : .secondary
    }
}

extension UsagePanelState {
    /// An account's chart color is tied to its position in the Claude Switcher list, not to the display order.
    func colorIndex(of account: Account) -> Int {
        self.accounts.firstIndex { $0.uuid == account.uuid } ?? 0
    }
}

extension UsagePanelState.Account {
    /// Time of the server's last successful answer for this account.
    var measuredAt: Double? {
        if let lastMeasuredAt {
            return lastMeasuredAt
        }
        return (self.windows ?? [:]).values.compactMap { $0.source == "poll" ? $0.measuredAt : nil }.max()
    }

    /// Limit windows that this plan has and that have a reading.
    public var visibleWindows: [(UsagePanelState.WindowKind, UsagePanelState.Window)] {
        UsagePanelState.WindowKind.allCases.compactMap { kind in
            guard let window = self.window(kind), window.pct != nil else { return nil }
            if kind == .fiveHour {
                // A plan may have no 5-hour limit: then the server does not return that window.
                if self.has5h == false {
                    return nil
                }
                if window.source != "poll", window.resetsAt == nil {
                    return nil
                }
            }
            return (kind, window)
        }
    }
}

extension UsagePanelState.WindowKind {
    public var title: String {
        switch self {
        case .fiveHour: "Session"
        case .week: "Weekly"
        case .fable: "Fable weekly"
        }
    }

    public var longTitle: String {
        switch self {
        case .fiveHour: "5-hour session limit"
        case .week: "Weekly limit"
        case .fable: "Fable weekly limit"
        }
    }

    var span: Double {
        self == .fiveHour ? 5 * 3600 : 7 * 86400
    }
}

// MARK: - Bar segments

struct UsageSegment: Identifiable {
    enum Kind: String {
        case you, code, otherCode, chat, cowork, other, others, unknown
        /// All use of a limit that has no split by source.
        case all
    }

    let kind: Kind
    /// Limit percentage for the label.
    let value: Double
    /// Percentage of the bar width.
    let barValue: Double
    var usd: Double?

    var id: String {
        self.kind.rawValue
    }

    var color: Color {
        switch self.kind {
        case .you: UsagePalette.you
        case .code, .otherCode: UsagePalette.otherCode
        case .chat: UsagePalette.chat
        case .cowork: UsagePalette.cowork
        case .other, .others, .unknown: UsagePalette.others
        case .all: UsagePalette.single
        }
    }

    var label: String {
        switch self.kind {
        case .you: "You"
        case .code: "Claude Code"
        case .otherCode: "Other Code"
        case .chat: "Chat"
        case .cowork: "Cowork"
        case .other: "Other"
        case .others: "Others"
        case .unknown: "Not split yet"
        case .all: "Used"
        }
    }

    var longLabel: String {
        switch self.kind {
        case .you: "You: Claude Code on this Mac"
        case .code: "Claude Code (all devices, yours not split yet)"
        case .otherCode: "Other Claude Code (not this Mac)"
        case .chat: "Chat (claude.ai and apps)"
        case .cowork: "Cowork"
        case .other: "Other"
        case .others: "Others (not this Mac)"
        case .unknown: "Not split yet"
        case .all: "Used"
        }
    }

    var chipText: String {
        self.kind == .unknown ? self.label : "\(self.label) \(UsageFormat.percent(self.value))"
    }

    /// Splits the window percentage into "mine" and the rest. For the week, the remainder is split by the server's breakdown.
    /// A limit with a single source is one segment.
    static func build(
        for window: UsagePanelState.Window,
        kind: UsagePanelState.WindowKind,
        sources: UsageLimitSources = .split) -> [UsageSegment]
    {
        let total = max(0, window.pct ?? 0)
        guard total > 0 else { return [] }
        if sources == .single {
            return [UsageSegment(kind: .all, value: total, barValue: total, usd: window.usd?.total)]
        }
        guard let rawMine = window.mine else {
            // No rate for this account yet, so "mine" is unknown. The weekly window still has the server's
            // own breakdown: show it instead of one grey "Not split yet" bar.
            if kind == .week, let server = window.server {
                let parts: [(Kind, Double)] = [
                    (.code, (server["claude_code"] ?? 0).rounded()),
                    (.chat, (server["chat"] ?? 0).rounded()),
                    (.cowork, (server["cowork"] ?? 0).rounded()),
                    (.other, (server["other"] ?? 0).rounded()),
                ]
                let sum = parts.reduce(0) { $0 + $1.1 }
                if sum >= 1 {
                    let scale = total / sum
                    return parts.filter { $0.1 >= 1 }.map {
                        UsageSegment(kind: $0.0, value: $0.1, barValue: $0.1 * scale)
                    }
                }
            }
            return [UsageSegment(kind: .unknown, value: total, barValue: total)]
        }
        var result: [UsageSegment] = []
        let mine = min(total, max(0, rawMine))
        // Labels must add up to the window percentage, so the remainder is computed from rounded numbers.
        let totalRounded = total.rounded()
        let mineRounded = min(totalRounded, mine.rounded())
        let spent = window.usd.map { kind == .fable ? ($0.fable ?? 0) : $0.total }
        result.append(UsageSegment(kind: .you, value: mine, barValue: mine, usd: spent))

        let room = max(0, total - mine)
        if kind == .week, let server = window.server {
            let parts: [(Kind, Double)] = [
                (.otherCode, max(0, (server["claude_code"] ?? 0).rounded() - mineRounded)),
                (.chat, (server["chat"] ?? 0).rounded()),
                (.cowork, (server["cowork"] ?? 0).rounded()),
                (.other, (server["other"] ?? 0).rounded()),
            ]
            let sum = parts.reduce(0) { $0 + $1.1 }
            // Labels are the server's numbers as is; the bar width is fitted to the measured percentage.
            let scale = sum > 0 ? room / sum : 0
            for (partKind, value) in parts where value >= 1 {
                result.append(UsageSegment(kind: partKind, value: value, barValue: value * scale))
            }
        } else if totalRounded - mineRounded >= 1 {
            result.append(UsageSegment(kind: .others, value: totalRounded - mineRounded, barValue: room))
        }
        return result
    }
}

/// Whether a limit's use can be split by where it came from.
public enum UsageLimitSources: Sendable, Equatable {
    /// Claude: this Mac, other Claude Code, chat, Cowork. The bar has a part per source and a legend line.
    case split
    /// Antigravity: one quota and no split. One bar segment, no legend line, no "Where it went".
    case single
}

// MARK: - Pace

/// Window spend pace, like the mark on the stock CodexBar bar: where spend would be at an even rate.
public struct UsagePace: Equatable {
    /// How many percent would be spent by now at an even rate.
    public let expected: Double
    /// Spent (as of the last reading) minus expected: plus is overspend, minus is reserve.
    public let delta: Double
    /// The reading is old (an account that is not being polled): the mark still compares it with even use
    /// by now, but there is no estimate of when the limit runs out.
    public let isStale: Bool
    public let lastsToReset: Bool
    /// In how many seconds the limit runs out at the current rate.
    public let runsOutIn: Double?
    /// How many seconds before the reset the limit runs out according to the collector's forecast: that long without it.
    public let earlyBy: Double?

    public static func make(
        window: UsagePanelState.Window,
        kind: UsagePanelState.WindowKind,
        now: Date) -> UsagePace?
    {
        guard window.rolled != true,
              let used = window.pct,
              let resetsAt = window.resetsAt
        else { return nil }
        let nowStamp = now.timeIntervalSince1970
        guard used < 100 else { return nil }
        let start = resetsAt - kind.span
        // Even use by now, the same number the time mark on the bar stands at (`UsageLimitTimeMark`).
        guard let even = UsageLimitTimeMark.evenUse(window: window, kind: kind, now: now) else { return nil }
        let expected = min(100, even)
        guard expected >= 3 else { return nil }
        let delta = used - expected
        // When the limit runs out is estimated only from a fresh reading: an old rate would be wrong.
        guard let measuredAt = window.measuredAt, UsageLimitReading.isFresh(measuredAt, now: now) else {
            return UsagePace(
                expected: expected, delta: delta, isStale: true, lastsToReset: true, runsOutIn: nil, earlyBy: nil)
        }
        // The collector's forecast accounts for how I usually continue a window; the straight "at this pace" line is the fallback.
        if let forecast = window.liveForecast(now: now) {
            let hit = forecast.hitAt
            return UsagePace(
                expected: expected,
                delta: delta,
                isStale: false,
                lastsToReset: hit == nil,
                runsOutIn: hit.map { max(0, $0 - nowStamp) },
                earlyBy: hit.map { max(0, resetsAt - $0) })
        }
        var lasts = true
        var runsOutIn: Double?
        let elapsed = measuredAt - start
        if used > 0, elapsed > 0 {
            let secondsToEmpty = (100 - used) / (used / elapsed)
            lasts = measuredAt + secondsToEmpty >= resetsAt
            if !lasts {
                runsOutIn = max(0, measuredAt + secondsToEmpty - nowStamp)
            }
        }
        return UsagePace(
            expected: expected,
            delta: delta,
            isStale: false,
            lastsToReset: lasts,
            runsOutIn: runsOutIn,
            earlyBy: nil)
    }

    public var isDeficit: Bool {
        self.delta > 0
    }

    public var headline: String {
        let value = Int(abs(self.delta).rounded())
        if value == 0 {
            return "On pace"
        }
        return self.isDeficit ? "\(value)% in deficit" : "\(value)% in reserve"
    }

    public var tail: String {
        if self.lastsToReset {
            return "lasts until reset"
        }
        guard let runsOutIn else { return "" }
        if let earlyBy, earlyBy >= 60 {
            let when = runsOutIn < 60 ? "out now" : "out in \(UsageFormat.duration(runsOutIn))"
            return "\(when), \(UsageFormat.duration(earlyBy)) before reset"
        }
        return runsOutIn < 60 ? "runs out now" : "runs out in \(UsageFormat.duration(runsOutIn))"
    }

    /// The only pace text left in a limit row: the limit runs out before it resets.
    /// "Out in 1h 2m, 1h 42m before reset". The reserve or deficit itself is shown by the mark alone.
    public var warning: String? {
        guard !self.lastsToReset, !self.tail.isEmpty else { return nil }
        return self.tail.prefix(1).uppercased() + self.tail.dropFirst()
    }

    public var color: Color {
        self.isDeficit ? UsagePalette.paceBad : UsagePalette.paceGood
    }
}

// MARK: - Bar

struct UsageSegmentBar: View {
    let segments: [UsageSegment]
    /// Where even use would be by now; nil draws the bar alone.
    var mark: UsageLimitTimeMark?
    @Environment(\.usageRowHighlighted) private var highlighted

    private static let barHeight: CGFloat = 7

    var body: some View {
        // A single Canvas: the mark "cuts through" the bar, as in stock CodexBar.
        Canvas { context, size in
            let barRect = CGRect(
                x: 0,
                y: (size.height - Self.barHeight) / 2 + (self.mark == nil ? 0 : 2),
                width: size.width,
                height: Self.barHeight)
            let track = Path(roundedRect: barRect, cornerRadius: Self.barHeight / 2)
            context.fill(track, with: .color(self.highlighted ? .white.opacity(0.28) : UsagePalette.track))

            var clipped = context
            clipped.clip(to: track)
            let visible = self.segments.filter { $0.barValue > 0.05 }
            var x: CGFloat = 0
            for (index, segment) in visible.enumerated() {
                let segmentWidth = max(1.5, size.width * CGFloat(min(100, segment.barValue)) / 100)
                let gap: CGFloat = index < visible.count - 1 ? 1 : 0
                let rect = CGRect(x: x, y: barRect.minY, width: max(0.5, segmentWidth - gap), height: Self.barHeight)
                clipped.fill(Path(rect), with: .color(segment.color))
                x += segmentWidth
            }

            if let mark = self.mark {
                let center = min(size.width - 4, max(4, size.width * CGFloat(mark.percent) / 100))
                UsageTimeMarkGlyph.draw(
                    in: &context, center: center, barTop: barRect.minY, barBottom: barRect.maxY,
                    color: self.highlighted ? .white : mark.color)
            }
        }
        .frame(height: self.mark == nil ? 13 : 17)
    }
}

/// The "T" of the time mark, drawn by the bar and by the legend from the same path.
struct UsageTimeMarkGlyph: View {
    let color: Color

    /// A cap 4 pt above the bar, a 2 pt stem through it, and a cut-out halo so it reads on any part.
    static func draw(in context: inout GraphicsContext, center: CGFloat, barTop: CGFloat, barBottom: CGFloat, color: Color) {
        let capY = barTop - 4
        let tailY = barBottom + 2
        var mark = Path()
        mark.move(to: CGPoint(x: center - 4, y: capY))
        mark.addLine(to: CGPoint(x: center + 4, y: capY))
        mark.addLine(to: CGPoint(x: center + 1, y: barTop))
        mark.addLine(to: CGPoint(x: center + 1, y: tailY))
        mark.addLine(to: CGPoint(x: center - 1, y: tailY))
        mark.addLine(to: CGPoint(x: center - 1, y: barTop))
        mark.closeSubpath()
        context.blendMode = .destinationOut
        context.stroke(mark, with: .color(.white), lineWidth: 2.5)
        context.blendMode = .normal
        context.fill(mark, with: .color(color))
    }

    var body: some View {
        Canvas { context, size in
            UsageTimeMarkGlyph.draw(
                in: &context, center: size.width / 2, barTop: 5, barBottom: size.height - 3, color: self.color)
        }
        .frame(width: 10, height: 13)
    }
}

// MARK: - Wrapping labels onto lines

struct UsageFlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = self.rows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * self.lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in self.rows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + self.spacing
            }
            y += row.height + self.lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let needed = current.indices.isEmpty ? size.width : current.width + self.spacing + size.width
            if !current.indices.isEmpty, needed > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + self.spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

struct UsageChip: View {
    let color: Color
    let text: String
    var dashed = false
    var fontSize: CGFloat = 10.5
    @Environment(\.usageRowHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 4) {
            if self.dashed {
                // Two short strokes: the swatch of a dashed chart line.
                HStack(spacing: 2) {
                    Rectangle().fill(self.color).frame(width: 4, height: 2)
                    Rectangle().fill(self.color).frame(width: 4, height: 2)
                }
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(self.color)
                    .frame(width: 7, height: 7)
            }
            Text(self.text)
                .font(.system(size: self.fontSize))
                .foregroundStyle(UsageInk.secondary(self.highlighted))
                .lineLimit(1)
        }
    }
}

/// "⚠ Out in 1h 2m, 1h 42m before reset": shown only when the limit will not last until its reset.
struct UsageRunOutLine: View {
    let text: String
    @Environment(\.usageRowHighlighted) private var highlighted

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(self.text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(self.highlighted ? .white : UsagePalette.paceBad)
    }
}

/// "Collector error: ValueError: …": the one quiet line an account without numbers gets in place of them.
struct UsageUnavailableLine: View {
    let text: String
    @Environment(\.usageRowHighlighted) private var highlighted

    var body: some View {
        Text(self.text)
            .font(.system(size: 10.5))
            .foregroundStyle(UsageInk.secondary(self.highlighted))
            .lineLimit(2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Footer

public struct UsageFooterView: View {
    let state: UsagePanelState
    let now: Date
    let width: CGFloat
    let refreshing: Bool
    let showsLegend: Bool
    /// The "You = Claude Code on this Mac" chip of the legend; a page without a source split leaves it out.
    let showsYouChip: Bool
    /// A footnote above the status line: what is exact and what is estimated.
    let note: String?

    public init(
        state: UsagePanelState,
        now: Date,
        width: CGFloat,
        refreshing: Bool,
        showsLegend: Bool,
        showsYouChip: Bool = true,
        note: String? = nil)
    {
        self.state = state
        self.now = now
        self.width = width
        self.refreshing = refreshing
        self.showsLegend = showsLegend
        self.showsYouChip = showsYouChip
        self.note = note
    }

    private var status: String {
        if self.refreshing {
            return "Refreshing limits…"
        }
        if self.state.isStale(now: self.now) {
            return "Not updated for \(UsageFormat.duration(self.now.timeIntervalSince(self.state.generatedDate))): "
                + "the usage collector is not running."
        }
        return "Updated \(UsageFormat.clock(self.state.generatedDate)) · refreshes when you open this menu"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if self.showsLegend {
                UsageFlowLayout(spacing: 12) {
                    if self.showsYouChip {
                        UsageChip(color: UsagePalette.you, text: "You = Claude Code on this Mac")
                    }
                    // The mark is the only place a row shows reserve or deficit, so the legend names both colors.
                    HStack(spacing: 4) {
                        UsageTimeMarkGlyph(color: UsagePalette.paceGood)
                        Text("in reserve")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        UsageTimeMarkGlyph(color: UsagePalette.paceBad)
                            .padding(.leading, 5)
                        Text("in deficit")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Text("mark = even use by now")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            if let note {
                UsageNote(text: note)
            }
            Text(self.status)
                .font(.system(size: 10.5))
                .foregroundStyle(self.state.isStale(now: self.now) && !self.refreshing
                    ? AnyShapeStyle(UsagePalette.warning)
                    : AnyShapeStyle(.tertiary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(width: self.width, alignment: .leading)
    }
}

// MARK: - Shared panel details

struct UsagePanelTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
                .font(.system(size: 13, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UsageSectionLabel: View {
    let text: String

    var body: some View {
        Text(self.text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(.secondary)
    }
}

struct UsageNote: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Mouse tracking inside the menu: SwiftUI `onHover` does not provide coordinates.
struct UsageMouseTracker: NSViewRepresentable {
    let onMoved: (CGPoint?) -> Void

    func makeNSView(context _: Context) -> TrackingView {
        let view = TrackingView()
        view.onMoved = self.onMoved
        return view
    }

    func updateNSView(_ nsView: TrackingView, context _: Context) {
        nsView.onMoved = self.onMoved
    }

    final class TrackingView: NSView {
        var onMoved: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            self.window?.acceptsMouseMovedEvents = true
            self.updateTrackingAreas()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                self.removeTrackingArea(trackingArea)
            }
            // A menu window is never "key", so tracking is always on.
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                owner: self,
                userInfo: nil)
            self.addTrackingArea(area)
            self.trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            self.onMoved?(self.convert(event.locationInWindow, from: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            self.onMoved?(self.convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            self.onMoved?(nil)
        }
    }
}
