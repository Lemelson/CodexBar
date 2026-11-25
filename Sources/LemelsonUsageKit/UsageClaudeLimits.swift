import AppKit
import SwiftUI

private enum UsageClaudeLimitAccount: String, CaseIterable {
    case lemelson
    case magomed
    case misha

    init?(account: UsagePanelState.Account) {
        self.init(rawValue: account.displayName.lowercased())
    }

    static func position(of account: UsagePanelState.Account) -> Int {
        guard let known = Self(account: account) else { return self.allCases.count }
        return self.allCases.firstIndex(of: known) ?? self.allCases.count
    }
}

extension UsagePanelState {
    /// Promote the active account while keeping the remaining cards in their usual order.
    public var claudeLimitAccounts: [Account] {
        self.accounts.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive
            }
            return UsageClaudeLimitAccount.position(of: lhs) < UsageClaudeLimitAccount.position(of: rhs)
        }
    }
}

/// The same account tint follows the account when the active one changes.
public struct UsageClaudeLimitCardStyle {
    let tint: Color
    let initials: String
    let active: Bool

    public init(account: UsagePanelState.Account, in state: UsagePanelState) {
        switch UsageClaudeLimitAccount(account: account) {
        case .lemelson:
            self.tint = UsagePalette.dynamic(light: 0x6946B6, dark: 0xA98BFF)
            self.initials = "L"
        case .misha:
            self.tint = UsagePalette.dynamic(light: 0x2461B7, dark: 0x62A8FF)
            self.initials = "M"
        case .magomed:
            self.tint = UsagePalette.dynamic(light: 0x526C25, dark: 0xADC46D)
            self.initials = "Mg"
        case nil:
            self.tint = UsagePalette.account(state.colorIndex(of: account))
            self.initials = String(account.displayName.prefix(2)).capitalized
        }
        self.active = account.isActive
    }
}

/// A card is drawn in slices so each limit remains a real menu item with its own hover panel.
private struct UsageClaudeCardSlice: ViewModifier {
    static let inset: CGFloat = 8
    static let radius: CGFloat = 16

    let style: UsageClaudeLimitCardStyle
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

public struct UsageClaudeLimitHeader: View {
    let account: UsagePanelState.Account
    let style: UsageClaudeLimitCardStyle
    let now: Date
    let width: CGFloat
    let hasLimits: Bool
    @Environment(\.colorScheme) private var scheme

    public init(
        account: UsagePanelState.Account,
        style: UsageClaudeLimitCardStyle,
        now: Date,
        width: CGFloat,
        hasLimits: Bool)
    {
        self.account = account
        self.style = style
        self.now = now
        self.width = width
        self.hasLimits = hasLimits
    }

    private var actionNote: String? {
        guard self.account.lastPoll?.status != "auth_rejected" else { return nil }
        return UsageAccountHeaderView.actionNote(for: self.account)
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
                Text(self.account.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if self.style.active {
                    Circle().fill(self.style.tint).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Spacer(minLength: 4)
                if let measured = self.account.measuredAt, self.now.timeIntervalSince1970 - measured >= 30 * 60 {
                    let age = UsageFormat.age(measured, now: self.now).replacingOccurrences(of: " ago", with: " old")
                    Label(age, systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            if let note = self.account.unavailableNote ?? self.actionNote {
                Text(note).font(.system(size: 10.5)).foregroundStyle(UsagePalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note = UsageAccountHeaderView.pauseNote(for: self.account) {
                Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary)
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
        .modifier(UsageClaudeCardSlice(style: self.style, width: self.width, first: true, last: !self.hasLimits))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(self.style.active ? .isSelected : [])
    }
}

enum UsageClaudeLimitVerdict: Equatable {
    case enough
    case mayRunOut
    case outIn(String)
    case outNow
    case unknown

    init(window: UsagePanelState.Window, now: Date) {
        let stamp = now.timeIntervalSince1970
        guard window.rolled != true, let reset = window.resetsAt, reset > stamp,
              let measured = window.measuredAt, stamp - measured < 30 * 60
        else {
            self = .unknown
            return
        }
        if let used = window.pct, used >= 100 {
            self = .outNow
        } else if let forecast = window.liveForecast(now: now) {
            if let hit = forecast.hitAt, hit < reset {
                self = hit <= stamp ? .outNow : .outIn(UsageFormat.duration(hit - stamp))
            } else if forecast.hitEarly.map({ $0 < reset }) == true || (forecast.endHi ?? 0) >= 100 {
                self = .mayRunOut
            } else {
                self = forecast.endPct == nil ? .unknown : .enough
            }
        } else {
            self = .unknown
        }
    }

    var label: (text: String, symbol: String, color: Color) {
        switch self {
        case .enough: ("Enough", "checkmark.circle.fill", UsagePalette.paceGood)
        case .mayRunOut: ("May run out", "exclamationmark.triangle.fill", UsagePalette.warning)
        case let .outIn(time): ("Out in ≈\(time)", "xmark.octagon.fill", UsagePalette.paceBad)
        case .outNow: ("Out now", "xmark.octagon.fill", UsagePalette.paceBad)
        case .unknown: ("No forecast", "minus.circle", .secondary)
        }
    }
}

public struct UsageClaudeLimitRow: View {
    let kind: UsagePanelState.WindowKind
    let window: UsagePanelState.Window
    let style: UsageClaudeLimitCardStyle
    let now: Date
    let width: CGFloat
    let sessionsLeft: UsageSessionsLeft?
    let last: Bool
    @Environment(\.usageRowHighlighted) private var highlighted

    public init(
        kind: UsagePanelState.WindowKind,
        window: UsagePanelState.Window,
        style: UsageClaudeLimitCardStyle,
        now: Date,
        width: CGFloat,
        sessionsLeft: UsageSessionsLeft?,
        last: Bool)
    {
        self.kind = kind
        self.window = window
        self.style = style
        self.now = now
        self.width = width
        self.sessionsLeft = sessionsLeft
        self.last = last
    }

    private var timeMark: UsageSegmentBar.TimeArrow? {
        let stamp = self.now.timeIntervalSince1970
        guard self.window.rolled != true, let used = self.window.pct, let reset = self.window.resetsAt,
              reset > stamp, reset - stamp <= self.kind.span
        else { return nil }
        let expected = 100 * (1 - (reset - stamp) / self.kind.span)
        let fresh = self.window.measuredAt.map { stamp - $0 < 30 * 60 } ?? false
        let color = if !fresh {
            Color.secondary
        } else {
            used > expected ? UsagePalette.paceBad : UsagePalette.paceGood
        }
        return .init(percent: expected, color: color)
    }

    public var body: some View {
        let segments = UsageSegment.build(for: self.window, kind: self.kind, sources: .split)
        let forecast = UsageClaudeLimitVerdict(window: self.window, now: self.now).label
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: self.kind == .fiveHour ? "clock" : self.kind == .week ? "calendar" : "sparkle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(self.kind == .fable ? UsagePalette.fable : UsageInk.secondary(self.highlighted))
                    .frame(width: 13)
                Text(self.kind.title).lineLimit(1)
                Spacer(minLength: 4)
                Label(forecast.text, systemImage: forecast.symbol)
                    .foregroundStyle(self.highlighted ? .white : forecast.color)
                    .lineLimit(1)
                    .frame(minWidth: 104, alignment: .leading)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(UsageInk.secondary(self.highlighted))
            }
            .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                UsageSegmentBar(segments: segments, timeArrow: self.timeMark)
                Text(UsageFormat.percent(max(0, self.window.pct ?? 0)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .fixedSize()
                    .frame(minWidth: 29, alignment: .trailing)
            }
            HStack(alignment: .top, spacing: 5) {
                UsageFlowLayout(spacing: 6) {
                    ForEach(segments) { segment in
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
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(UsageInk.secondary(self.highlighted))
                .fixedSize()
            }
        }
        .foregroundStyle(UsageInk.primary(self.highlighted))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.065)).frame(height: 0.5).allowsHitTesting(false)
        }
        .modifier(UsageClaudeCardSlice(
            style: self.style, width: self.width, last: self.last, highlighted: self.highlighted))
    }
}
