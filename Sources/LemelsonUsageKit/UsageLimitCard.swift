import AppKit
import SwiftUI

// The limit card: one design for every provider page (Claude Limits, Antigravity, Codex).
//
//   UsageLimitCardHeader     tint gradient, initials badge, name, active dot; plan and reading age on the right
//   UsageLimitCardRow        one limit window: icon, title, verdict, chevron, the bar with the time mark,
//                            percent, legend chips (split sources only), reset time and sessions left
//   UsageLimitCardFactRow    a compact fact inside the card (Codex credits), supplied by the app
//   UsageLimitCardNoticeRow  one sentence in place of the limit rows (no readings yet, the collector failed)
//
// Every part is one menu row (so each limit keeps its own hover panel), drawn as a slice of one rounded card
// (`UsageLimitCardSlice`). The verdict (`UsageLimitVerdict`) and the time mark (`UsageLimitTimeMark`) are
// computed here and nowhere else; `UsageSegmentBar` draws the mark.

// MARK: - How fresh a reading is

public enum UsageLimitReading {
    /// A reading older than this says nothing about the current rate: no forecast, a grey time mark, and the
    /// card header shows the reading's age.
    public static let freshness: Double = 30 * 60

    static func isFresh(_ measuredAt: Double?, now: Date) -> Bool {
        measuredAt.map { now.timeIntervalSince1970 - $0 < self.freshness } ?? false
    }
}

// MARK: - Style

/// The colour and badge of one card. Claude accounts get theirs from `init(account:in:)`, provider pages from
/// their `UsageProviderSpec`.
public struct UsageLimitCardStyle: Sendable {
    public let tint: Color
    public let initials: String
    /// Draws the tinted border and the dot after the name: the Claude account signed in now.
    public let active: Bool

    public init(tint: Color, initials: String, active: Bool = false) {
        self.tint = tint
        self.initials = initials
        self.active = active
    }
}

/// A card is drawn in slices so each limit remains a real menu item with its own hover panel.
struct UsageLimitCardSlice: ViewModifier {
    static let inset: CGFloat = 8
    static let radius: CGFloat = 16

    let style: UsageLimitCardStyle
    let width: CGFloat
    var first = false
    var last = false
    var highlighted = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let radius = Self.radius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: self.first ? radius : 0,
            bottomLeadingRadius: self.last ? radius : 0,
            bottomTrailingRadius: self.last ? radius : 0,
            topTrailingRadius: self.first ? radius : 0)
        content
            .frame(maxHeight: .infinity)
            .frame(width: max(0, self.width - 2 * Self.inset))
            .background {
                if self.highlighted {
                    Color(nsColor: .selectedContentBackgroundColor)
                } else {
                    Color.primary.opacity(self.scheme == .dark ? 0.044 : 0.045)
                }
            }
            .clipShape(shape)
            .overlay {
                if self.style.active {
                    GeometryReader { proxy in
                        let seam: CGFloat = 2
                        shape.strokeBorder(self.style.tint.opacity(0.97), lineWidth: seam)
                            .frame(height: proxy.size.height + (self.first ? 0 : seam) + (self.last ? 0 : seam))
                            .offset(y: self.first ? 0 : -seam)
                    }
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
            .frame(width: self.width)
            .padding(.bottom, self.last ? 8 : 0)
    }
}

/// The hairline between two slices of a card.
private struct UsageLimitCardSeam: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.065)).frame(height: 0.5).allowsHitTesting(false)
        }
    }
}

// MARK: - Header

public struct UsageLimitCardHeader: View {
    /// One line under the name: what needs an action (warning colour) or why the card is waiting (quiet).
    public struct Note: Sendable, Equatable {
        public let text: String
        public let isWarning: Bool

        public init(_ text: String, isWarning: Bool) {
            self.text = text
            self.isWarning = isWarning
        }
    }

    let name: String
    let style: UsageLimitCardStyle
    /// Short plan name on the right ("Ultra 5x", "Plus"); nil leaves it out.
    let plan: String?
    /// Time of the newest reading: its age is shown once it is no longer fresh.
    let measuredAt: Double?
    let now: Date
    let note: Note?
    let width: CGFloat
    /// Without limit rows the header is the whole card and rounds its bottom corners too.
    let hasLimits: Bool
    @Environment(\.colorScheme) private var scheme

    public init(
        name: String,
        style: UsageLimitCardStyle,
        plan: String? = nil,
        measuredAt: Double?,
        now: Date,
        note: Note? = nil,
        width: CGFloat,
        hasLimits: Bool)
    {
        self.name = name
        self.style = style
        self.plan = plan
        self.measuredAt = measuredAt
        self.now = now
        self.note = note
        self.width = width
        self.hasLimits = hasLimits
    }

    /// "2h old", once the reading is no longer fresh.
    static func ageText(measuredAt: Double?, now: Date) -> String? {
        guard let measuredAt, !UsageLimitReading.isFresh(measuredAt, now: now) else { return nil }
        return UsageFormat.age(measuredAt, now: now).replacingOccurrences(of: " ago", with: " old")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(self.style.initials)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(self.scheme == .dark ? .black : .white)
                    .frame(width: 21, height: 21)
                    .background(self.style.tint, in: .rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(self.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if self.style.active {
                    Circle().fill(self.style.tint).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    if let plan {
                        Text(plan)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    if let age = Self.ageText(measuredAt: self.measuredAt, now: self.now) {
                        Label(age, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 9.5, weight: .regular))
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            }
            if let note {
                Text(note.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(note.isWarning ? AnyShapeStyle(UsagePalette.warning) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            LinearGradient(
                stops: [
                    .init(color: self.style.tint.opacity(0.40), location: 0),
                    .init(color: self.style.tint.opacity(0.17), location: 0.55),
                    .init(color: self.style.tint.opacity(0), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom)
        }
        .modifier(UsageLimitCardSlice(style: self.style, width: self.width, first: true, last: !self.hasLimits))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.style.active ? .isSelected : [])
    }
}

// MARK: - Verdict

/// The one-phrase forecast at the right of a limit row: Enough / May run out / Out in ≈… / Out now /
/// No forecast. Only a fresh reading with the collector's forecast gives one.
public enum UsageLimitVerdict: Equatable, Sendable {
    case enough
    case mayRunOut
    /// Runs out in `in`; `beforeReset` is how long before the reset (nil when under a minute).
    case outIn(String, beforeReset: String?)
    case outNow
    case unknown

    public init(window: UsagePanelState.Window, now: Date) {
        let stamp = now.timeIntervalSince1970
        guard window.rolled != true, let reset = window.resetsAt, reset > stamp,
              UsageLimitReading.isFresh(window.measuredAt, now: now)
        else {
            self = .unknown
            return
        }
        if let used = window.pct, used >= 100 {
            self = .outNow
        } else if let forecast = window.liveForecast(now: now) {
            if let hit = forecast.hitAt, hit < reset {
                if hit <= stamp {
                    self = .outNow
                } else {
                    let early = reset - hit
                    self = .outIn(
                        UsageFormat.duration(hit - stamp),
                        beforeReset: early >= 60 ? UsageFormat.duration(early) : nil)
                }
            } else if forecast.hitEarly.map({ $0 < reset }) == true || (forecast.endHi ?? 0) >= 100 {
                self = .mayRunOut
            } else {
                self = forecast.endPct == nil ? .unknown : .enough
            }
        } else {
            self = .unknown
        }
    }

    public var text: String {
        switch self {
        case .enough: "Enough"
        case .mayRunOut: "May run out"
        case let .outIn(time, _): "Out in ≈\(time)"
        case .outNow: "Out now"
        case .unknown: "No forecast"
        }
    }

    /// "Runs out 3d 4h before reset": the line under the bar of a limit that will not last.
    public var runOutLine: String? {
        guard case let .outIn(_, early?) = self else { return nil }
        return "Runs out \(early) before reset"
    }

    var symbol: String {
        switch self {
        case .enough: "checkmark.circle.fill"
        case .mayRunOut: "exclamationmark.triangle.fill"
        case .outIn, .outNow: "xmark.octagon.fill"
        case .unknown: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .enough: UsagePalette.paceGood
        case .mayRunOut: UsagePalette.warning
        case .outIn, .outNow: UsagePalette.paceBad
        case .unknown: .secondary
        }
    }
}

// MARK: - Time mark

/// The "T" on a limit bar: where even use would be by now. Green: in reserve (used no more than that),
/// red: in deficit, grey: the reading is old, so only its position means something.
public struct UsageLimitTimeMark: Equatable, Sendable {
    public enum Tone: Sendable, Equatable {
        case reserve, deficit, stale
    }

    /// Percent of the window that even use would have spent by now.
    public let percent: Double
    public let tone: Tone

    public init(percent: Double, tone: Tone) {
        self.percent = percent
        self.tone = tone
    }

    /// The one formula for "even use by now"; nil for a rolled window, an unknown or past reset, or a reset
    /// further away than the window is long.
    public static func evenUse(window: UsagePanelState.Window, kind: UsagePanelState.WindowKind, now: Date) -> Double? {
        let stamp = now.timeIntervalSince1970
        guard window.rolled != true, let reset = window.resetsAt, reset > stamp, reset - stamp <= kind.span else {
            return nil
        }
        return 100 * (1 - (reset - stamp) / kind.span)
    }

    public static func make(window: UsagePanelState.Window, kind: UsagePanelState.WindowKind, now: Date) -> Self? {
        guard let used = window.pct, let even = self.evenUse(window: window, kind: kind, now: now) else { return nil }
        let tone: Tone = if !UsageLimitReading.isFresh(window.measuredAt, now: now) {
            .stale
        } else {
            used > even ? .deficit : .reserve
        }
        return Self(percent: even, tone: tone)
    }

    public var color: Color {
        switch self.tone {
        case .reserve: UsagePalette.paceGood
        case .deficit: UsagePalette.paceBad
        case .stale: .secondary
        }
    }
}

// MARK: - Limit row

public struct UsageLimitCardRow: View {
    let kind: UsagePanelState.WindowKind
    let window: UsagePanelState.Window
    let style: UsageLimitCardStyle
    let now: Date
    let width: CGFloat
    /// `.split` (Claude): a bar part and a legend chip per source. `.single`: one part, no chips: the quota
    /// counts all use wherever it happened, so there is nothing honest to put on a chip.
    let sources: UsageLimitSources
    /// Weekly row only: see `UsageSessionsLeft.make(for:account:in:now:)`.
    let sessionsLeft: UsageSessionsLeft?
    /// In place of `sessionsLeft` while the session size is being measured: "5h sessions: measuring, 1 of 3…".
    let sessionsNote: String?
    let last: Bool
    @Environment(\.usageRowHighlighted) private var highlighted

    public init(
        kind: UsagePanelState.WindowKind,
        window: UsagePanelState.Window,
        style: UsageLimitCardStyle,
        now: Date,
        width: CGFloat,
        sources: UsageLimitSources = .split,
        sessionsLeft: UsageSessionsLeft?,
        sessionsNote: String? = nil,
        last: Bool)
    {
        self.kind = kind
        self.window = window
        self.style = style
        self.now = now
        self.width = width
        self.sources = sources
        self.sessionsLeft = sessionsLeft
        self.sessionsNote = sessionsNote
        self.last = last
    }

    private var symbol: String {
        switch self.kind {
        case .fiveHour: "clock"
        case .week: "calendar"
        case .fable: "sparkle"
        }
    }

    public var body: some View {
        let segments = UsageSegment.build(for: self.window, kind: self.kind, sources: self.sources)
        let verdict = UsageLimitVerdict(window: self.window, now: self.now)
        let chips = self.sources == .split ? segments : []
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: self.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(self.kind == .fable ? UsagePalette.fable : UsageInk.secondary(self.highlighted))
                    .frame(width: 13)
                Text(self.kind.title).lineLimit(1)
                Spacer(minLength: 4)
                Label(verdict.text, systemImage: verdict.symbol)
                    .foregroundStyle(self.highlighted ? .white : verdict.color)
                    .lineLimit(1)
                    .frame(minWidth: 104, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(UsageInk.secondary(self.highlighted))
            }
            .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                UsageSegmentBar(segments: segments, mark: UsageLimitTimeMark.make(
                    window: self.window, kind: self.kind, now: self.now))
                Text(UsageFormat.percent(max(0, self.window.pct ?? 0)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .fixedSize()
                    .frame(minWidth: 29, alignment: .trailing)
            }
            HStack(alignment: .top, spacing: 5) {
                UsageFlowLayout(spacing: 6) {
                    ForEach(chips) { segment in
                        UsageChip(color: segment.color, text: segment.chipText, fontSize: 9.5)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    if self.window.rolled == true {
                        Text("New window")
                    } else if let reset = self.window.resetsAt {
                        Text(UsageFormat.reset(reset, now: self.now))
                    }
                    if let sessions = self.sessionsLeft {
                        Text("\(Text(sessions.leftNumber).fontWeight(.semibold))\(sessions.leftUnit)")
                            .monospacedDigit()
                    } else if let note = self.sessionsNote {
                        Text(note).monospacedDigit()
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(UsageInk.secondary(self.highlighted))
                .fixedSize()
            }
            if let line = verdict.runOutLine {
                UsageRunOutLine(text: line)
            }
        }
        .foregroundStyle(UsageInk.primary(self.highlighted))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(UsageLimitCardSeam())
        .modifier(UsageLimitCardSlice(
            style: self.style, width: self.width, last: self.last, highlighted: self.highlighted))
    }
}

// MARK: - Facts and notices inside a card

/// A compact fact a provider page shows inside its card, after the limit rows, e.g. Codex's credits balance.
/// The app supplies them (`UsageProviderPage(extras:)`); the kit only draws them.
public struct UsageLimitCardFact: Identifiable, Sendable, Equatable {
    public let id: String
    /// SF Symbol name, drawn like a limit row's icon.
    public let symbol: String
    public let title: String
    /// Right-aligned, emphasised: "58,169 left", "3 available".
    public let value: String
    /// Optional quiet line under it: "Next expires in 5d 9h".
    public let caption: String?

    public init(id: String, symbol: String, title: String, value: String, caption: String? = nil) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.value = value
        self.caption = caption
    }
}

public struct UsageLimitCardFactRow: View {
    let fact: UsageLimitCardFact
    let style: UsageLimitCardStyle
    let width: CGFloat
    let last: Bool
    /// Leaves room for the chevron of a fact with a hover detail.
    let hasDetail: Bool
    @Environment(\.usageRowHighlighted) private var highlighted

    public init(fact: UsageLimitCardFact, style: UsageLimitCardStyle, width: CGFloat, last: Bool, hasDetail: Bool = false) {
        self.fact = fact
        self.style = style
        self.width = width
        self.last = last
        self.hasDetail = hasDetail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: self.fact.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UsageInk.secondary(self.highlighted))
                    .frame(width: 13)
                Text(self.fact.title).lineLimit(1)
                Spacer(minLength: 4)
                Text(self.fact.value)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
                if self.hasDetail {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(UsageInk.secondary(self.highlighted))
                }
            }
            .font(.system(size: 12, weight: .semibold))
            if let caption = self.fact.caption {
                Text(caption)
                    .font(.system(size: 9.5))
                    .foregroundStyle(UsageInk.secondary(self.highlighted))
                    .lineLimit(1)
                    .padding(.leading, 18)
            }
        }
        .foregroundStyle(UsageInk.primary(self.highlighted))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .modifier(UsageLimitCardSeam())
        .modifier(UsageLimitCardSlice(
            style: self.style, width: self.width, last: self.last, highlighted: self.highlighted))
    }
}

/// One sentence in place of a card's limit rows.
public struct UsageLimitCardNoticeRow: View {
    let text: String
    let detail: String?
    let style: UsageLimitCardStyle
    let width: CGFloat
    let last: Bool

    public init(text: String, detail: String?, style: UsageLimitCardStyle, width: CGFloat, last: Bool) {
        self.text = text
        self.detail = detail
        self.style = style
        self.width = width
        self.last = last
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(UsageLimitCardSeam())
        .modifier(UsageLimitCardSlice(style: self.style, width: self.width, last: self.last))
    }
}
