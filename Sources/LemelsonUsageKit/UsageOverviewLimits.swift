import Foundation
import SwiftUI

// Overview → Limits, under the cumulative chart: the weekly limit of every account on this Mac.
//
//   UsageOverviewLimitAccount     one account of any provider, as its row and its hover panel need it
//   UsageOverviewLimitsHeader     "WEEKLY LIMITS" and the legend: You, Others, Not split
//   UsageOverviewAccountLimitRow  name, plan and what is left; the bar split three ways with the time mark
//
// Order: Claude accounts as the summary lists them, then Codex accounts in the Codex tab's own order (the
// active one first, `UsageCodexPage.entries`), then Antigravity. Codex rows carry CodexBar's newer readings and
// its private names, exactly as the Codex tab does, so the two never show different numbers or names.

// MARK: - One account

public struct UsageOverviewLimitAccount: Identifiable, Sendable, Equatable {
    public let provider: UsageOverviewProviderKind
    public let account: UsagePanelState.Account
    /// Codex and Antigravity: the account's block (sessions, calibration). Nil for Claude.
    public let block: UsageProviderBlock?
    /// How the weekly bar is told apart.
    public let sources: UsageLimitSources
    /// The collector failed on this account, or the provider has no data: one quiet line instead of a bar.
    public let unavailableNote: String?
    /// "74% left", "Out in ≈1d 11h"; nil without a reading of the current window.
    let status: UsageOverviewSpend.WeeklyStatus?

    /// "claude-<uuid>": the tail of the row's id.
    public var id: String {
        "\(self.provider.rawValue)-\(self.account.uuid)"
    }

    /// The account's key in `overviewTimeline`: "claude:<uuid>".
    public var timelineKey: String {
        "\(self.provider.rawValue):\(self.account.uuid)"
    }

    public var name: String {
        self.account.displayName
    }

    public var isActive: Bool {
        self.account.isActive
    }

    /// "Max 20x", "Pro 5x", "Ultra 5x"; nil without a plan name.
    public var plan: String? {
        self.provider.spec.map { $0.shortPlan(self.account.planName) } ?? self.account.planName
    }

    /// "Claude Max 20x", "Codex Pro 5x"; just "Ultra 5x" for the account named "Antigravity", so the row never
    /// reads "Antigravity  Antigravity Ultra 5x".
    public var subtitle: String {
        UsageOverviewRecent.subtitle(name: self.name, providerTitle: self.provider.title, plan: self.plan)
    }

    /// The title of the weekly limit's detail panel after the account's name: "Claude · Weekly limit", so
    /// "Lemelson · Claude · Weekly limit" and "Lemelson · Codex · Weekly limit" are told apart at once.
    public var detailTitle: String {
        let limit = UsagePanelState.WindowKind.week.longTitle
        return UsageOverviewRecent.sameName(self.name, self.provider.title) ? limit : "\(self.provider.title) · \(limit)"
    }

    public var window: UsagePanelState.Window? {
        self.unavailableNote == nil ? self.account.window(.week) : nil
    }

    public var statusText: String {
        if let status { return status.text }
        if self.unavailableNote != nil { return "—" }
        return self.window?.rolled == true ? "New window" : "No reading"
    }

    /// You, Others and Not split yet of the weekly reading, for the row's bar.
    var segments: [UsageSegment] {
        self.window.map { UsageSegment.threeWay(for: $0, sources: self.sources) } ?? []
    }

    /// Changes when the row's look may: the reading, its split, the account's state.
    var fingerprint: String {
        let window = self.window
        return ":\(self.isActive):\(Int(window?.measuredAt ?? 0)):\(Int((window?.pct ?? -1).rounded()))"
            + (window.map(UsageProviderPage.splitFingerprint) ?? "") + (self.unavailableNote == nil ? "" : ":note")
    }

    /// Every account with a weekly limit, in the page's order. Codex's accounts stand in for its block, so
    /// one Codex account is never listed twice.
    ///   - codexLive: CodexBar's in-memory reads by account id (lowercase), as the Codex tab takes them.
    ///   - codexPrivateNames: "Hide personal info" is on: the name shown for each Codex account id.
    public static func all(
        in state: UsagePanelState,
        now: Date,
        codexLive: [String: UsageCodexLive] = [:],
        codexPrivateNames: [String: String]? = nil) -> [UsageOverviewLimitAccount]
    {
        var result: [UsageOverviewLimitAccount] = []
        for account in state.accounts {
            let note = account.unavailableNote
            result.append(UsageOverviewLimitAccount(
                provider: .claude,
                account: account,
                block: nil,
                sources: .split,
                unavailableNote: note,
                status: note == nil ? UsageOverviewSpend.weeklyStatus(account.window(.week), now: now) : nil))
        }
        for kind in [UsageOverviewProviderKind.codex, .antigravity] {
            guard let spec = kind.spec, let block = spec.block(in: state) else { continue }
            let entries: [UsageProviderBlock] = if block.error != nil {
                [block]
            } else if kind == .codex {
                // The Codex tab's own entries: live readings merged in, active first, names hidden when asked.
                Self.codexEntries(of: block, live: codexLive, privateNames: codexPrivateNames)
            } else {
                block.accounts.isEmpty ? [block] : block.accounts
            }
            for entry in entries {
                let note = (entry.error ?? block.error).map { _ in "\(spec.name)'s data could not be read this time." }
                let window = entry.account.window(.week)
                result.append(UsageOverviewLimitAccount(
                    provider: kind,
                    account: entry.account,
                    block: entry,
                    sources: window.map { spec.sources(for: $0, block: entry) } ?? .single,
                    unavailableNote: note,
                    status: note == nil ? UsageOverviewSpend.weeklyStatus(window, now: now) : nil))
            }
        }
        return result
    }

    /// Codex's accounts as the Codex tab lists them (`UsageCodexPage.entries`): CodexBar's newer readings in
    /// place of the summary's, the active account first, and the private names when personal info is hidden.
    static func codexEntries(
        of block: UsageProviderBlock,
        live: [String: UsageCodexLive],
        privateNames: [String: String]?) -> [UsageProviderBlock]
    {
        let entries = UsageCodexPage.entries(of: block, live: live)
        guard let privateNames else { return entries }
        let names = UsageCodexPage.privateNames(of: block, given: privateNames)
        return entries.map { UsageCodexPage.renamed($0, names: names) }
    }

    /// The weekly limit's detail panel, the same one the provider's own page shows; nil without a reading.
    @MainActor
    public func detail(in state: UsagePanelState, now: Date, width: CGFloat) -> UsageLimitDetailPanelView? {
        guard let window = self.window, window.pct != nil else { return nil }
        if let block, let spec = self.provider.spec {
            return UsageProviderPage.detail(
                kind: .week, window: window, block: block, now: now, width: width, spec: spec,
                title: self.detailTitle)
        }
        return UsageLimitDetailPanelView(
            account: self.account,
            kind: .week,
            window: window,
            now: now,
            width: width,
            sessionsLeft: UsageSessionsLeft.make(for: .week, account: self.account, in: state, now: now),
            title: self.detailTitle)
    }
}

extension UsageSegment {
    /// Any account's weekly reading as You, Others and Not split yet: one legend for every provider.
    /// Claude's own sources (other Claude Code, chat, Cowork) are all "others" here.
    static func threeWay(for window: UsagePanelState.Window, sources: UsageLimitSources) -> [UsageSegment] {
        let total = max(0, window.pct ?? 0)
        guard total > 0 else { return [] }
        if sources.local != nil, window.split != nil {
            return self.build(for: window, kind: .week, sources: sources)
        }
        guard sources == .split, let rawMine = window.mine else {
            return self.serverThreeWay(window, total: total)
                ?? [UsageSegment(kind: .unknown, value: total, barValue: total)]
        }
        let mine = min(total, max(0, rawMine))
        var result = [UsageSegment(kind: .you, value: mine, barValue: mine)]
        if total - mine >= 0.5 {
            result.append(UsageSegment(kind: .others, value: total - mine, barValue: total - mine))
        }
        return result
    }
}

extension UsageSegment {
    /// Claude without a rate ("mine" is not known) but with the server's own breakdown of the week: chat,
    /// Cowork and the rest are certainly not this Mac (Others); Claude Code on all devices is this Mac or
    /// another one (Not split yet). Nil without a usable breakdown.
    static func serverThreeWay(_ window: UsagePanelState.Window, total: Double) -> [UsageSegment]? {
        guard let server = window.server else { return nil }
        func part(_ key: String) -> Double {
            max(0, server[key] ?? 0)
        }
        let code = part("claude_code")
        let others = part("chat") + part("cowork") + part("other")
        let sum = code + others
        guard sum >= 1, others >= 0.5 else { return nil }
        // The bar is the reading the row shows; the server's parts give its proportions.
        let scale = total / sum
        var result = [UsageSegment(kind: .others, value: others * scale, barValue: others * scale)]
        if code * scale >= 0.5 {
            result.append(UsageSegment(kind: .unknown, value: code * scale, barValue: code * scale))
        }
        return result
    }
}

// MARK: - Section header

/// "WEEKLY LIMITS" with the legend of the bars under it.
public struct UsageOverviewLimitsHeader: View {
    let width: CGFloat

    public static let height: CGFloat = 20

    public init(width: CGFloat) {
        self.width = width
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            UsageSectionLabel(text: "Weekly limits")
            Spacer(minLength: 6)
            UsageChip(color: UsagePalette.you, text: "You", fontSize: 9.5)
            UsageChip(color: UsagePalette.others, text: "Others", fontSize: 9.5)
            UsageChip(color: UsagePalette.others, text: "Not split", hatched: true, fontSize: 9.5)
        }
        .padding(.leading, 20)
        .padding(.trailing, 30)
        .frame(width: self.width, height: Self.height, alignment: .center)
    }
}

// MARK: - Account row

public struct UsageOverviewAccountLimitRow: View {
    let entry: UsageOverviewLimitAccount
    let now: Date
    let width: CGFloat
    @Environment(\.usageRowHighlighted) private var highlighted

    /// Every account row has this height, with a bar or with a note.
    public static let height: CGFloat = 38

    public init(entry: UsageOverviewLimitAccount, now: Date, width: CGFloat) {
        self.entry = entry
        self.now = now
        self.width = width
    }

    public var body: some View {
        let entry = self.entry
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UsageInk.primary(self.highlighted))
                    .layoutPriority(2)
                if entry.isActive {
                    // Neutral ink: the provider's colour (orange for Claude) would read as the "You" swatch
                    // of the legend right above.
                    Circle()
                        .fill(UsageInk.secondary(self.highlighted))
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2 }
                        .accessibilityLabel("active")
                }
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(UsageInk.secondary(self.highlighted))
                        .layoutPriority(1)
                }
                Spacer(minLength: 6)
                // The status keeps its full width ("Out in ≈1d 12h"): the plan gives way first.
                Text(entry.statusText)
                    .font(.system(size: 10.5, weight: entry.status?.tone == .bad ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(self.statusColor)
                    .fixedSize()
                    .layoutPriority(3)
            }
            .lineLimit(1)
            .frame(height: 15)
            if let note = entry.unavailableNote {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(UsageInk.secondary(self.highlighted))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: 17, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    UsageSegmentBar(
                        segments: entry.segments,
                        mark: entry.window.flatMap { UsageLimitTimeMark.make(window: $0, kind: .week, now: self.now) })
                        .frame(height: 17)
                    Text(entry.window?.pct.map { UsageFormat.percent(max(0, $0)) } ?? "—")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(UsageInk.primary(self.highlighted))
                        .fixedSize()
                        .frame(minWidth: 29, alignment: .trailing)
                }
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 30)
        .frame(width: self.width, height: Self.height, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        if self.highlighted {
            return .white
        }
        switch self.entry.status?.tone {
        case .good: return UsagePalette.paceGood
        case .warning: return UsagePalette.warning
        case .bad: return UsagePalette.paceBad
        case .neutral, nil: return .secondary
        }
    }
}
