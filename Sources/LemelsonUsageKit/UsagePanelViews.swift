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
    /// A reading older than this says nothing about the current rate.
    private static let freshness: Double = 30 * 60

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
        guard resetsAt > nowStamp, used < 100 else { return nil }
        let start = resetsAt - kind.span
        // The mark stands where even use would be at this minute, so it is right for an old reading too.
        guard nowStamp > start else { return nil }
        let expected = min(100, (nowStamp - start) / kind.span * 100)
        guard expected >= 3 else { return nil }
        let delta = used - expected
        // When the limit runs out is estimated only from a fresh reading: an old rate would be wrong.
        guard let measuredAt = window.measuredAt, nowStamp - measuredAt < Self.freshness else {
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
    var pace: UsagePace?
    @Environment(\.usageRowHighlighted) private var highlighted

    private static let barHeight: CGFloat = 7

    var body: some View {
        // A single Canvas: the pace mark "cuts through" the bar, as in stock CodexBar.
        Canvas { context, size in
            let barRect = CGRect(
                x: 0,
                y: (size.height - Self.barHeight) / 2,
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

            if let pace = self.pace {
                let center = min(size.width - 1.5, max(1.5, size.width * CGFloat(pace.expected) / 100))
                // An old reading says little about the pace now: its mark is drawn pale.
                let ink = self.highlighted ? Color.white : pace.color
                let opacity = pace.isStale ? 0.45 : 1
                context.blendMode = .destinationOut
                context.fill(
                    Path(CGRect(x: center - 2.5, y: 0, width: 5, height: size.height)),
                    with: .color(.white))
                context.blendMode = .normal
                context.fill(
                    Path(
                        roundedRect: CGRect(x: center - 1, y: 0, width: 2, height: size.height),
                        cornerRadius: 1),
                    with: .color(ink.opacity(opacity)))
            }
        }
        .frame(height: 13)
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
                .font(.system(size: 10.5))
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

/// "≈4.7 full 5h sessions left · 21 fit before reset": under the weekly limit of an account with a 5-hour limit.
struct UsageSessionsLeftLine: View {
    let sessions: UsageSessionsLeft
    @Environment(\.usageRowHighlighted) private var highlighted

    var body: some View {
        (Text(self.sessions.leftNumber)
            .fontWeight(.semibold)
            .foregroundStyle(UsageInk.primary(self.highlighted))
            + Text("\(self.sessions.leftUnit) · \(self.sessions.fitText)"))
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(UsageInk.secondary(self.highlighted))
            .lineLimit(1)
    }
}

// MARK: - Limit row

/// One limit window of one account. On hover CodexBar opens a detail panel beside it.
public struct UsageLimitRowView: View {
    let kind: UsagePanelState.WindowKind
    let window: UsagePanelState.Window
    let now: Date
    let width: CGFloat
    /// Weekly row only: see `UsageSessionsLeft.make(for:account:in:now:)`.
    let sessionsLeft: UsageSessionsLeft?
    /// Replaces the short window title ("Session"), e.g. "5-hour" on the Antigravity page.
    let title: String?
    let sources: UsageLimitSources
    /// An account read only by hand: see `UsageReadingAge.make(account:kind:window:now:)`.
    let reading: UsageReadingAge?
    @Environment(\.usageRowHighlighted) private var highlighted

    public init(
        kind: UsagePanelState.WindowKind,
        window: UsagePanelState.Window,
        now: Date,
        width: CGFloat,
        sessionsLeft: UsageSessionsLeft? = nil,
        title: String? = nil,
        sources: UsageLimitSources = .split,
        reading: UsageReadingAge? = nil)
    {
        self.kind = kind
        self.window = window
        self.now = now
        self.width = width
        self.sessionsLeft = sessionsLeft
        self.title = title
        self.sources = sources
        self.reading = reading
    }

    private var percent: Double {
        max(0, self.window.pct ?? 0)
    }

    private var percentColor: Color {
        if self.highlighted {
            return .white
        }
        switch self.percent {
        case 95...: return UsagePalette.paceBad
        case 80...: return UsagePalette.warning
        default: return .primary
        }
    }

    private var resetText: String {
        if self.window.rolled == true {
            return "new window, no reading yet"
        }
        guard let resetsAt = self.window.resetsAt else { return "" }
        return UsageFormat.reset(resetsAt, now: self.now)
    }

    public var body: some View {
        let segments = UsageSegment.build(for: self.window, kind: self.kind, sources: self.sources)
        let pace = UsagePace.make(window: self.window, kind: self.kind, now: self.now)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(self.title ?? self.kind.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(UsageInk.primary(self.highlighted))
                Text("\(UsageFormat.percent(self.percent)) used")
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(self.percentColor)
                Spacer(minLength: 4)
                Text(self.resetText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(UsageInk.secondary(self.highlighted))
                    .lineLimit(1)
            }
            UsageSegmentBar(segments: segments, pace: pace)
                .opacity(self.reading?.level == .stale ? 0.5 : 1)
            // One source needs no legend: the bar is the percentage above it.
            if !segments.isEmpty, self.sources == .split {
                UsageFlowLayout {
                    ForEach(segments) { segment in
                        UsageChip(color: segment.color, text: segment.chipText)
                    }
                }
            }
            if let reading, !reading.isFresh {
                UsageReadingAgeLine(reading: reading)
            }
            // Reserve or deficit is read off the mark on the bar; the exact percent is in the detail panel.
            if let warning = pace?.warning {
                UsageRunOutLine(text: warning)
            }
            if let sessionsLeft {
                UsageSessionsLeftLine(sessions: sessionsLeft)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 30)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
    }
}

// MARK: - Account header

public struct UsageAccountHeaderView: View {
    let account: UsagePanelState.Account
    let now: Date
    let width: CGFloat
    /// The dot says which Claude account is signed in; a page with a single account leaves it out.
    let showsDot: Bool

    public init(account: UsagePanelState.Account, now: Date, width: CGFloat, showsDot: Bool = true) {
        self.account = account
        self.now = now
        self.width = width
        self.showsDot = showsDot
    }

    /// "Max 5x · 52m ago": the plan and how long ago the limits were read. The green dot already says
    /// which account is in Claude now. An account read only by hand says "reading from 3d ago" once the
    /// reading is old, in the color of its age.
    public static func status(for account: UsagePanelState.Account, now: Date) -> Text {
        let reading = UsageReadingAge.make(account: account, now: now)
        let read = if let reading, !reading.isFresh {
            Text(reading.ageText).foregroundStyle(reading.color)
        } else {
            Text(account.measuredAt.map { UsageFormat.age($0, now: now) } ?? "not read yet")
        }
        guard let plan = account.planName else { return read }
        return Text("\(plan) · ") + read
    }

    /// A second line only for what needs an action from me. Why an account is merely waiting
    /// (VPN state, server not answering) is not shown: the age of the reading says enough.
    public static func actionNote(for account: UsagePanelState.Account) -> String? {
        switch account.lastPoll?.status {
        case "auth_rejected":
            "Sign-in expired: open it once in Claude Switcher."
        case "keychain_denied":
            "No Keychain access to read limits."
        case "no_session_cookie", "cookies_unreadable", "no_org":
            "No saved sign-in for this account yet."
        default:
            nil
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if self.showsDot {
                    Circle()
                        .fill(self.account.isActive ? UsagePalette.paceGood : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                }
                Text(self.account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                // A long name gives way: the plan and the age are never cut off.
                Self.status(for: self.account, now: self.now)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let note = Self.actionNote(for: self.account) {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(UsagePalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .frame(width: self.width, alignment: .leading)
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
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(UsagePalette.paceGood)
                            .frame(width: 2, height: 9)
                        Text("in reserve")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(UsagePalette.paceBad)
                            .frame(width: 2, height: 9)
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
