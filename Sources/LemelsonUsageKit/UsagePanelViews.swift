import AppKit
import SwiftUI

extension EnvironmentValues {
    /// Menu row under the cursor: on the colored highlight, text and bar are drawn light.
    @Entry public var usageRowHighlighted: Bool = false
    /// Only for the PNG preview, which cannot move a pointer: per-day spend charts draw this day
    /// ("2026-11-21") as pointed at. Nil in the app.
    @Entry public var usagePreviewHoveredDay: String? = nil
    /// Only for the PNG preview: per-day spend charts draw this span as being dragged across. Nil in the app.
    @Entry public var usagePreviewDragRange: UsageSpendRange? = nil
    /// Whether a per-day chart's layer is the visible one of its stack (`UsagePeriodStack`, the Accounts /
    /// Models pair): only that chart tracks the pointer and draws hover marks. True outside a stack.
    @Entry var usageChartLayerShown: Bool = true
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
    /// Not from this Mac, with no breakdown by source. Dark enough in light mode to stand apart from the
    /// track and from the hatched "Not split yet" part on a warm screen.
    public static let others = UsagePalette.dynamic(light: 0x6B6B70, dark: 0x787B84)
    /// The diagonal strokes of "Not split yet", drawn over the track. Dark enough to stay crisp on a warm
    /// (Night Shift) screen, where 0.30 washed out against the track.
    public static let unsplitStripe = Color.primary.opacity(0.45)
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
    public static let haiku = UsagePalette.dynamic(light: 0xC99A06, dark: 0xFDE047)

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

    /// A provider page's models (Antigravity, Codex), most used first: the account colors in another order,
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

    /// Laid over a per-day chart outside the pointed-at day or the dragged span: washes the bars out towards
    /// the menu's own background (lighter in light mode, darker in dark), so the marked part stands out by
    /// brightness, also on a warm screen.
    public static let chartWash = UsagePalette.dynamic(light: 0xF4F4F4, dark: 0x1C1C1E)

    /// A limit with no split by source (Antigravity, Codex): the whole bar is one color.
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
    /// Codex / Antigravity: whose use "You" is. Nil for Claude.
    var local: UsageLocalSource?
    /// The value is a floor ("Others 12%+"): more of the unsplit part may belong here.
    var atLeast = false
    /// The value rests on a single measured stretch ("You ≈8%").
    var approximate = false

    var id: String {
        self.kind.rawValue
    }

    /// "Not split yet" is hatched, not filled: it is nobody's colour yet.
    var isHatched: Bool {
        self.kind == .unknown
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
        if let local {
            switch self.kind {
            case .you: return "You: \(local.app) on this Mac"
            case .unknown: return "Not split yet: you or others"
            default: break
            }
        }
        return switch self.kind {
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

    /// "8%", "≈8%", "12%+". A floor is rounded down (0.6 is "0%+", never "1%+"), and "≈" never stands before
    /// "<1%" or "0%".
    var valueText: String {
        if self.atLeast {
            return UsageFormat.floorPercent(self.value) + "+"
        }
        return self.approximate ? UsageFormat.approxPercent(self.value) : UsageFormat.percent(self.value)
    }

    /// The value in a sentence: "at least 12%" for a floor.
    var longValueText: String {
        self.atLeast ? "at least \(UsageFormat.floorPercent(self.value))" : self.valueText
    }

    var chipText: String {
        // Claude's unsplit bar is the whole reading, which the row already shows.
        self.kind == .unknown && self.local == nil ? self.label : "\(self.label) \(self.valueText)"
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
        if case let .local(source) = sources {
            guard let split = window.split else {
                return [UsageSegment(kind: .all, value: total, barValue: total, usd: window.usd?.total)]
            }
            return self.build(split: split, total: total, usd: window.usd?.total, source: source)
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

extension UsageSegment {
    /// Codex and Antigravity: the reading told apart by the collector (`Window.Split`).
    ///
    /// - calibrated, or mixed with a part of its own: You, Others, Not split yet.
    /// - idle: You 0%, Others.
    /// - floor (no rate, some of it moved while this Mac was idle): Others as a floor and Not split yet;
    ///   no orange, since this Mac's part is not known.
    /// - unknown (no rate, nothing proven): Not split yet alone.
    static func build(
        split: UsagePanelState.Window.Split,
        total: Double,
        usd: Double?,
        source: UsageLocalSource) -> [UsageSegment]
    {
        let sum = split.total
        guard total > 0, sum > 0 else { return [] }
        // The parts are of the reading the collector split; the bar is the reading the row shows.
        let scale = total / sum
        let parts = [split.youPct * scale, split.othersPct * scale, split.unknownPct * scale]
        let labels = Self.rounded(parts, to: total.rounded())
        func value(_ index: Int) -> Double {
            labels[index] >= 1 ? labels[index] : parts[index]
        }
        let knowsYou: Bool = switch split.method {
        case .calibrated, .idle: true
        case .mixed: split.youPct > 0
        case .floor, .unknown: false
        }
        // Without a rate nothing is this Mac's for sure: what is not proven others is not split.
        let unknown = knowsYou ? parts[2] : parts[2] + parts[0]
        // Others as a floor ("12%+") is rounded down, never up to the next percent, and the unsplit part
        // takes the rest of the reading, so the two labels still add up to it.
        let isFloor = !knowsYou && unknown >= 0.5
        let othersFloor = parts[1].rounded(.down)
        let othersLabel = isFloor ? (othersFloor >= 1 ? othersFloor : parts[1]) : value(1)
        let unknownLabel: Double = if isFloor {
            max(0, total.rounded() - othersFloor)
        } else if knowsYou {
            value(2)
        } else {
            value(2) + (labels[0] >= 1 ? labels[0] : parts[0])
        }

        var result: [UsageSegment] = []
        if knowsYou {
            result.append(UsageSegment(
                kind: .you, value: value(0), barValue: parts[0], usd: usd, local: source,
                approximate: split.preliminary && split.youPct > 0))
        }
        if parts[1] >= 0.5 {
            result.append(UsageSegment(
                kind: .others, value: othersLabel, barValue: parts[1], local: source, atLeast: isFloor))
        }
        if unknown >= 0.5 || result.isEmpty {
            result.append(UsageSegment(kind: .unknown, value: unknownLabel, barValue: unknown, local: source))
        }
        return result
    }

    /// Whole percents that add up to `target`: each part rounded down, the leftover given to the largest
    /// remainders, so the chips never read 8% + 5% under a 12% bar.
    ///
    /// A part under half a percent is never made a whole percent this way (0.4% of a 61.6% reading would
    /// read "1%"): it stays "<1%", and the percent it was next in line for is nobody's, so 62% reads
    /// "<1%" and "61%" rather than giving 61.2% a percent it did not use.
    static func rounded(_ parts: [Double], to target: Double) -> [Double] {
        var result = parts.map { $0.rounded(.down) }
        let missing = target - result.reduce(0, +)
        var left = missing.isFinite ? Int(max(0, min(missing, Double(parts.count)))) : 0
        let order = parts.indices.sorted { lhs, rhs in
            parts[lhs] - result[lhs] > parts[rhs] - result[rhs]
        }
        for index in order where left > 0 && parts[index] > result[index] {
            if parts[index] >= 0.5 {
                result[index] += 1
            }
            left -= 1
        }
        return result
    }
}

/// Whether a limit's use can be split by where it came from.
public enum UsageLimitSources: Sendable, Equatable {
    /// Claude: this Mac, other Claude Code, chat, Cowork. The bar has a part per source and a legend line.
    case split
    /// A provider summary without a split (older collectors): one bar segment, no legend line, no
    /// "Where it went".
    case single
    /// Codex and Antigravity: this Mac's app, others, and what is not split yet (`Window.Split`).
    case local(UsageLocalSource)

    var local: UsageLocalSource? {
        if case let .local(source) = self { return source }
        return nil
    }

    /// The bar has parts with a legend line under it.
    var hasParts: Bool {
        self != .single
    }
}

/// Whose use "You" is on a provider page, and what it takes to measure it.
public struct UsageLocalSource: Sendable, Equatable {
    /// "Codex", "Antigravity".
    public var app: String
    /// Where others' use can come from ("Codex cloud, ChatGPT or another computer").
    public var providerNote: String
    /// This Mac's spend between two readings that gives the weekly rate (`calibration.thresholds.stretchUsd`).
    public var stretchUsd: Double?

    public init(app: String, providerNote: String, stretchUsd: Double? = nil) {
        self.app = app
        self.providerNote = providerNote
        self.stretchUsd = stretchUsd
    }

    /// One sentence on how the reading was split, by the collector's method.
    ///   - usd: this Mac's dollars in the window, when the panel shows them next to "You".
    ///   - used: the reading, in percent of the limit.
    ///   - rated: whether the account has a dollars-per-percent rate; nil when the caller does not know.
    func note(
        for split: UsagePanelState.Window.Split,
        usd: Double? = nil,
        used: Double? = nil,
        rated: Bool? = nil) -> String
    {
        switch split.method {
        case .calibrated:
            return split.preliminary
                ? "You is this Mac's \(self.app) spend at a rate measured once so far, so it is approximate."
                : "You is this Mac's \(self.app) spend at the measured rate; the rest is others (\(self.providerNote))."
        case .idle:
            // "Idle" is about the moments the limit moved, not the whole window: with dollars on the same
            // panel ("You $2.40 · 0%"), say so instead of "was idle".
            if let usd, usd >= 0.5 {
                let moved = used.map { "the \(UsageFormat.percent($0))" } ?? "what"
                return "This Mac's \(UsageFormat.usdFine(usd)) of \(self.app) use did not move this limit yet; "
                    + "\(moved) moved while \(self.app) was idle here, so it is others (\(self.providerNote))."
            }
            return "The limit moved while \(self.app) was idle on this Mac, so all of it is others "
                + "(\(self.providerNote))."
        case .mixed:
            return "Part of the reading has no clean match yet: \(Self.reasonText(split.reason))."
        case .floor:
            guard rated != true else {
                return "Only what moved while this Mac was idle is proven others; the rest has no clean match "
                    + "yet: \(Self.reasonText(split.reason))."
            }
            return "No rate yet: only what moved while this Mac was idle is proven others. \(self.startsAfter)"
        case .unknown:
            // A rate may well exist: the collector then says why this reading still has no match. "No rate
            // yet" is only said when that is the reason.
            if rated == true || Self.namedReasons.contains(split.reason ?? "") {
                return "This reading cannot be split yet: \(Self.reasonText(split.reason))."
            }
            return "No rate yet, so this reading cannot be split. \(self.startsAfter)"
        }
    }

    /// The collector's reasons that explain an unsplit reading by themselves, with or without a rate.
    static let namedReasons: Set<String> = [
        "uncovered", "unpriced_calls", "bucket_boundary", "missing_baseline", "possible_local_activity",
        "live_reading",
    ]

    /// "The split starts after $10+ of Codex use on this Mac between two readings."
    private var startsAfter: String {
        guard let usd = self.stretchUsd, usd > 0 else {
            return "The split starts after more \(self.app) use on this Mac between two readings."
        }
        return "The split starts after \(UsageFormat.usd(usd))+ of \(self.app) use on this Mac between two readings."
    }

    /// The collector's reason for an unsplit part, in plain words.
    static func reasonText(_ reason: String?) -> String {
        switch reason {
        case "uncovered": "this Mac's logs do not cover that time"
        case "unpriced_calls": "some calls have no price yet"
        case "missing_baseline": "there was no reading before it"
        case "possible_local_activity": "this Mac was active at that time"
        case "live_reading": "the newest reading is not matched with this Mac's use yet"
        case "bucket_boundary": "this Mac's use falls in the same minute as the reading"
        default: "readings come in whole percents"
        }
    }
}

// MARK: - Pace

/// The Pace section of a limit's detail panel: how far the use is from even use by now. Built on the time mark
/// (`UsageLimitTimeMark`), so the panel's sentence and colour always match the "T" on the row's bar. When the
/// limit runs out is not said here: that is the verdict's and the forecast's (`UsageLimitVerdict`), the one
/// run-out logic of the row and the panel.
public struct UsageLimitPace: Equatable {
    /// How many percent would be spent by now at an even rate.
    public let expected: Double
    /// Spent (as of the last reading) minus expected: plus is overspend, minus is reserve.
    public let delta: Double
    /// The time mark this pace reads: its tone decides the wording and the colour.
    public let mark: UsageLimitTimeMark

    public static func make(
        window: UsagePanelState.Window,
        kind: UsagePanelState.WindowKind,
        now: Date) -> UsageLimitPace?
    {
        guard let used = window.pct, used < 100,
              let mark = UsageLimitTimeMark.make(window: window, kind: kind, now: now)
        else { return nil }
        let expected = min(100, mark.percent)
        return UsageLimitPace(expected: expected, delta: used - expected, mark: mark)
    }

    /// The reading is old: the mark still compares it with even use by now.
    public var isStale: Bool {
        self.mark.tone == .stale
    }

    /// The same side as the mark: above even use is a deficit, anything else a reserve.
    public var isDeficit: Bool {
        self.delta > 0
    }

    /// "24% in deficit", "3% in reserve"; under half a point "<1% in deficit".
    public var headline: String {
        let value = Int(abs(self.delta).rounded())
        let amount = value == 0 ? "<1%" : "\(value)%"
        return self.isDeficit ? "\(amount) in deficit" : "\(amount) in reserve"
    }

    public var color: Color {
        self.mark.color
    }
}

// MARK: - Bar

struct UsageSegmentBar: View {
    let segments: [UsageSegment]
    /// Where even use would be by now; nil draws the bar alone.
    var mark: UsageLimitTimeMark?
    @Environment(\.usageRowHighlighted) private var highlighted

    private static let barHeight: CGFloat = 7
    /// A part that is drawn is at least this wide: narrower, it is a sliver lost in the bar's rounded cap.
    static let minSegmentWidth: CGFloat = 2.5

    /// The parts the bar draws: under half a percent a part is no part of the picture (it would be a 1.5 pt
    /// sliver of colour inside the rounded cap), unless it is all there is.
    static func drawn(_ segments: [UsageSegment]) -> [UsageSegment] {
        let visible = segments.filter { $0.barValue >= 0.5 }
        guard visible.isEmpty else { return visible }
        return segments.filter { $0.barValue > 0.05 }.max { $0.barValue < $1.barValue }.map { [$0] } ?? []
    }

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
            let visible = Self.drawn(self.segments)
            var x: CGFloat = 0
            for (index, segment) in visible.enumerated() {
                let segmentWidth = max(
                    Self.minSegmentWidth, size.width * CGFloat(min(100, segment.barValue)) / 100)
                let gap: CGFloat = index < visible.count - 1 ? 1 : 0
                let rect = CGRect(x: x, y: barRect.minY, width: max(0.5, segmentWidth - gap), height: Self.barHeight)
                if segment.isHatched {
                    UsageHatch.draw(in: clipped, rect: rect, highlighted: self.highlighted)
                } else {
                    clipped.fill(Path(rect), with: .color(segment.color))
                }
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

/// The fill of "Not split yet": 45° strokes over the track, so it reads as unassigned rather than as a
/// third colour, and differs from grey Others by pattern as well as by brightness.
enum UsageHatch {
    static let pitch: CGFloat = 4
    static let lineWidth: CGFloat = 1.5

    static func draw(in context: GraphicsContext, rect: CGRect, highlighted: Bool = false) {
        guard rect.width > 0, rect.height > 0 else { return }
        var clipped = context
        clipped.clip(to: Path(rect))
        var strokes = Path()
        // Anchored to the bar's own origin, so the pattern does not shift when the part before it grows.
        var x = (rect.minX / Self.pitch).rounded(.down) * Self.pitch - rect.height
        while x < rect.maxX {
            strokes.move(to: CGPoint(x: x, y: rect.maxY))
            strokes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += Self.pitch
        }
        clipped.stroke(
            strokes,
            with: .color(highlighted ? .white.opacity(0.75) : UsagePalette.unsplitStripe),
            lineWidth: Self.lineWidth)
    }
}

/// The swatch of "Not split yet" in a legend: the track with the bar's hatch.
struct UsageHatchSwatch: View {
    var size = CGSize(width: 7, height: 7)
    @Environment(\.usageRowHighlighted) private var highlighted

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape = Path(roundedRect: rect, cornerRadius: 2)
            context.fill(shape, with: .color(self.highlighted ? .white.opacity(0.28) : UsagePalette.track))
            var clipped = context
            clipped.clip(to: shape)
            UsageHatch.draw(in: clipped, rect: rect, highlighted: self.highlighted)
        }
        .frame(width: self.size.width, height: self.size.height)
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
    /// The swatch of a solid chart line: one short stroke.
    var line = false
    /// The swatch of "Not split yet": hatched like its part of the bar.
    var hatched = false
    var fontSize: CGFloat = 10.5
    @Environment(\.usageRowHighlighted) private var highlighted

    var body: some View {
        HStack(spacing: 4) {
            if self.hatched {
                UsageHatchSwatch()
            } else if self.line {
                Rectangle().fill(self.color).frame(width: 10, height: 2)
            } else if self.dashed {
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
/// "⚠ Out 3d 4h early" in the place of a limit row's reset time, in the row's small type.
struct UsageRunOutLine: View {
    let text: String
    @Environment(\.usageRowHighlighted) private var highlighted

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
            Text(self.text)
                .font(.system(size: 9.5, weight: .semibold))
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
    /// One line: the note and a short status ("Beta · dollars at OpenAI API prices · updated 11:57"), as
    /// much of it as fits. The provider pages, which show this footer always, use it.
    let compact: Bool

    public init(
        state: UsagePanelState,
        now: Date,
        width: CGFloat,
        refreshing: Bool,
        showsLegend: Bool,
        showsYouChip: Bool = true,
        note: String? = nil,
        compact: Bool = false)
    {
        self.compact = compact
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

    /// "updated 11:57", "refreshing…", "not updated for 3h".
    private var shortStatus: String {
        if self.refreshing {
            return "refreshing…"
        }
        if self.state.isStale(now: self.now) {
            return "not updated for \(UsageFormat.duration(self.now.timeIntervalSince(self.state.generatedDate)))"
        }
        return "updated \(UsageFormat.clock(self.state.generatedDate))"
    }

    private var statusStyle: AnyShapeStyle {
        self.state.isStale(now: self.now) && !self.refreshing
            ? AnyShapeStyle(UsagePalette.warning)
            : AnyShapeStyle(.tertiary)
    }

    public var body: some View {
        if self.compact {
            self.compactLine
        } else {
            self.full
        }
    }

    /// The note and the status on one line; without room for both, the status alone (never cut mid-word).
    /// Without a note, the full status when it fits ("Updated 19:14 · refreshes when you open this menu").
    private var compactLine: some View {
        let status = self.shortStatus
        let line = self.note.map { "\($0) · \(status)" } ?? self.status
        return ViewThatFits(in: .horizontal) {
            Text(line).fixedSize()
            Text(status.prefix(1).uppercased() + status.dropFirst()).lineLimit(1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(self.statusStyle)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .frame(width: self.width, alignment: .leading)
    }

    private var full: some View {
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
                .foregroundStyle(self.statusStyle)
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
