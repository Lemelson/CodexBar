import Foundation
import SwiftUI

// MARK: - The page as menu rows

/// Overview in place of the stock Overview tab: every subscription on this Mac together, built from the same
/// parts as Claude Spend and the provider pages:
///
///   spend      `UsageOverviewSummaryView`: Last 24 hours / Last 7 days / the period, per-day spend split by
///              provider or by model, the models; hovering a day shows `chartDayDetail` in the hover panel,
///              dragging across days zooms (`UsageChartPointer`)
///   providers  one row per subscription (Claude with all its accounts, Codex, Antigravity), each with its
///              hover panel (`UsageOverviewProviderPanelView`); a click opens that provider's tab
///   footer     `UsageFooterView`, one line, as on the provider pages
///   cache row  "Prompt cache" of all subscriptions together (`UsageCacheSummary.all`): one line with the whole
///              story in the hover panel, placed by the menu above its action rows
///
/// Every view is laid out at the fixed `width` it was given; hover details at `detailWidth`. Ids are stable
/// across rebuilds and all start with `idPrefix`, the prefix Overview's warm-row recycling looks for.
@MainActor
public struct UsageOverviewPage {
    public enum Part: Equatable, Sendable {
        /// Totals, per-day chart and models; has the period and split switches.
        case spend
        /// Claude, Codex or Antigravity; has a hover detail.
        case provider(UsageOverviewProviderKind)
        /// The prompt cache row: not in `rows`, see `cacheRow`.
        case cache
        /// When the summary was updated: one line.
        case footer
    }

    public struct Row: Identifiable {
        public let id: String
        public let part: Part
        /// The row content, already framed to the page width.
        public let view: AnyView
        /// The hover detail, built on demand at `detailWidth`; nil for rows without one.
        public let detail: (@MainActor () -> AnyView)?
        /// The row has a control that takes clicks (the period and split switches, the zoom chip).
        public let hasControls: Bool
        /// A menu separator goes after this row.
        public let separatorAfter: Bool
        /// The subscription of a provider row; nil for the others.
        public let providerKind: UsageOverviewProviderKind?
        public let heightCacheScope: String
        /// Changes when the row's height may change: the summary was rewritten, or ten minutes passed.
        public let heightFingerprint: String
    }

    /// Every row id of the page starts with this.
    public static let idPrefix = "lemelsonOverview-"
    public static let defaultDetailWidth: CGFloat = 340

    public let spend: UsageOverviewSpend
    public let rows: [Row]
    public let detailWidth: CGFloat
    /// The one-line "Prompt cache" row of all subscriptions, with its detail panel; nil without cache data.
    public let cacheRow: Row?
    /// The day panel of the spend chart (hovering a day, dragging a span), for the hover panel: register
    /// `build` under `key` (`UsageOverviewSpend.defaultChartID + ":day"`). Nil without spend.
    public let chartDayDetail: (key: String, build: @MainActor () -> AnyView)?

    /// The one-line rows for the menu's footer area (above Status Page).
    public var lineRows: [Row] {
        [self.cacheRow].compactMap(\.self)
    }

    public init(
        state: UsagePanelState,
        now: Date,
        width: CGFloat,
        detailWidth: CGFloat = UsageOverviewPage.defaultDetailWidth,
        refreshing: Bool = false)
    {
        let spend = UsageOverviewSpend(state: state, now: now)
        self.spend = spend
        self.detailWidth = detailWidth
        let stamp = Int(state.generatedAt)
        let ageBucket = Int(now.timeIntervalSince1970 / 600)
        let fingerprint = "\(stamp):\(ageBucket)"
        let prefix = Self.idPrefix
        let scope = "lemelson-overview-"
        let offered = spend.offered
        var rows: [Row] = []
        func add(
            _ part: Part,
            _ name: String,
            _ view: some View,
            separatorAfter: Bool = false,
            hasControls: Bool = false,
            providerKind: UsageOverviewProviderKind? = nil,
            fingerprint extra: String = "",
            detail: (@MainActor () -> AnyView)? = nil)
        {
            rows.append(Row(
                id: prefix + name,
                part: part,
                view: AnyView(view),
                detail: detail,
                hasControls: hasControls,
                separatorAfter: separatorAfter,
                providerKind: providerKind,
                heightCacheScope: scope + name,
                heightFingerprint: fingerprint + extra))
        }

        // The zoom chip's ✕ and the split switch are controls too, also with a single period.
        add(.spend, "spend", UsageOverviewSummaryView(spend: spend, width: width),
            separatorAfter: true, hasControls: spend.offered.count > 1 || spend.hasSpend)
        for (index, provider) in spend.providers.enumerated() {
            add(
                .provider(provider.kind),
                "provider-\(provider.kind.rawValue)",
                UsageOverviewProviderRowView(provider: provider, offered: offered, width: width),
                separatorAfter: index == spend.providers.count - 1,
                providerKind: provider.kind,
                // A quiet line in place of the numbers has its own height.
                fingerprint: provider.unavailableNote.map { ":note-\($0.count)" } ?? "",
                detail: {
                    AnyView(UsageOverviewProviderPanelView(provider: provider, offered: offered, width: detailWidth))
                })
        }
        add(.footer, "footer", UsageFooterView(
            state: state,
            now: now,
            width: width,
            refreshing: refreshing,
            showsLegend: false,
            showsYouChip: false,
            note: "Dollars at API prices",
            compact: true), separatorAfter: true)
        self.rows = rows

        if spend.hasSpend {
            let catalog = spend.dayDetailCatalog(now: now)
            self.chartDayDetail = (key: catalog.panelKey, build: {
                AnyView(UsageDayDetailPanelView(catalog: catalog, width: detailWidth))
            })
        } else {
            self.chartDayDetail = nil
        }
        self.cacheRow = UsageCacheSummary.all(state).map { summary in
            Row(
                id: summary.rowID,
                part: .cache,
                view: AnyView(UsageCacheRowView(summary: summary, width: width)),
                detail: { AnyView(UsageCachePanelView(summary: summary, width: detailWidth)) },
                hasControls: false,
                separatorAfter: false,
                providerKind: nil,
                heightCacheScope: scope + "cache",
                heightFingerprint: fingerprint)
        }
    }
}

// MARK: - Provider rows, computed once

extension UsageOverviewSpend {
    /// One provider row and its panel: spend from the days, limits from the summary.

    static func summary(
        kind: UsageOverviewProviderKind,
        state: UsagePanelState,
        block: UsageProviderBlock?,
        days: [ProviderDay],
        labels: [String: String],
        palette: [String: UsageSeriesColor],
        unpriced: Set<String>,
        periodStarts: [UsageSpendPeriod: String],
        usesRolling24h: Bool,
        now: Date) -> ProviderSummary
    {
        func spend(from start: String) -> Double {
            days.reduce(0) { $1.key >= start ? $0 + $1.total.usd : $0 }
        }
        let today = spend(from: UsageDayKey.start(days: 1, now: now))
        let usd7d = spend(from: UsageDayKey.start(days: 7, now: now))
        let periodUsd = periodStarts.mapValues { spend(from: $0) }
        let split = UsageOverviewSpend.sum(days.map(\.uses))
        let order = Self.ranked(Array(split.keys), by: split)
        // The collector's own rolling 24 hours of this provider, unless its step failed.
        let reported: UsagePanelState.Spend24h.Provider? = state.spend24h?.byProvider.flatMap { by -> UsagePanelState.Spend24h.Provider? in
            switch kind {
            case .claude: by.claude
            case .codex: by.codex
            case .antigravity: by.antigravity
            }
        }.flatMap { $0.error == nil ? $0 : nil }

        switch kind {
        case .claude:
            let accounts = state.claudeLimitAccounts
            let counted = accounts.filter { !$0.isUnavailable }
            let unavailable = counted.isEmpty
                ? (accounts.first?.unavailableNote ?? "No Claude accounts in the summary.")
                : nil
            let fallback24h = counted.reduce(0) { $0 + ($1.usd24h ?? $1.usdToday ?? 0) }
            let usd24h = usesRolling24h ? (reported?.usd ?? fallback24h) : today
            // The tightest weekly limit of the accounts that have a reading of the current window.
            let readings = counted.compactMap { account -> (UsagePanelState.Account, WeeklyStatus)? in
                Self.weeklyStatus(account.window(.week), now: now).map { (account, $0) }
            }
            let tightest = readings.min { $0.1.urgency < $1.1.urgency }
            let status: String = tightest.map { entry in
                counted.count > 1 ? "\(entry.0.displayName) · \(entry.1.text)" : entry.1.text
            } ?? "—"
            let limits = accounts.map { account -> ProviderSummary.Limit in
                let window = account.window(.week)
                let verdict = window.map { UsageLimitVerdict(window: $0, now: now) } ?? .unknown
                let detail: String? = account.unavailableNote ?? account.pauseStatus
                    ?? window.flatMap { window in
                        window.rolled == true ? "New window" : window.resetsAt.map { UsageFormat.reset($0, now: now) }
                    }
                return ProviderSummary.Limit(
                    id: account.id,
                    name: account.displayName,
                    usedPct: account.isUnavailable ? nil : window?.pct,
                    verdict: account.isUnavailable ? "—" : verdict.text,
                    tone: Self.tone(verdict),
                    detail: detail)
            }
            let count = state.accounts.count
            let subtitle: String = if !counted.isEmpty, counted.count < accounts.count {
                "\(counted.count) of \(accounts.count) accounts"
            } else {
                count == 1 ? "1 account" : "\(count) accounts"
            }
            return ProviderSummary(
                kind: kind,
                title: kind.title,
                subtitle: subtitle,
                statusText: status,
                statusTone: tightest?.1.tone ?? .neutral,
                firstCellTitle: usesRolling24h ? "24h" : "Today",
                usd24h: usd24h,
                usd7d: usd7d,
                periodUsd: periodUsd,
                unavailableNote: unavailable,
                limits: limits,
                limitsTitle: "Weekly limit by account",
                days: days,
                order: order,
                labels: labels,
                palette: palette,
                unpriced: unpriced,
                periodStarts: periodStarts)
        case .codex, .antigravity:
            let spec = kind.spec ?? .codex
            let raw = spec.block(in: state)
            let unavailable: String? = if raw == nil {
                "No \(spec.name) data on this Mac yet."
            } else if raw?.error != nil {
                "\(spec.name)'s data could not be read this time."
            } else {
                nil
            }
            let windows = block?.limitWindows ?? []
            let weekly = windows.first { $0.0 == .week }.flatMap { Self.weeklyStatus($0.1, now: now) }
            let fallback24h = block.map { $0.account.usd24h ?? $0.account.usdToday ?? today } ?? 0
            let usd24h = usesRolling24h ? (reported?.usd ?? fallback24h) : today
            let limits = windows.map { entry -> ProviderSummary.Limit in
                let window = entry.1
                let verdict = UsageLimitVerdict(window: window, now: now)
                return ProviderSummary.Limit(
                    id: entry.0.rawValue,
                    name: entry.0.title,
                    usedPct: window.pct,
                    verdict: verdict.text,
                    tone: Self.tone(verdict),
                    detail: window.rolled == true ? "New window" : window.resetsAt.map { UsageFormat.reset($0, now: now) })
            }
            let plan = spec.shortPlan(block?.account.planName ?? block?.worth?.planName)
            return ProviderSummary(
                kind: kind,
                title: kind.title,
                subtitle: plan ?? "",
                statusText: unavailable == nil ? (weekly?.text ?? "—") : "—",
                statusTone: unavailable == nil ? (weekly?.tone ?? .neutral) : .neutral,
                firstCellTitle: usesRolling24h ? "24h" : "Today",
                usd24h: unavailable == nil ? usd24h : 0,
                usd7d: usd7d,
                periodUsd: periodUsd,
                unavailableNote: unavailable,
                limits: limits,
                limitsTitle: "Limits",
                days: days,
                order: order,
                labels: labels,
                palette: palette,
                unpriced: unpriced,
                periodStarts: periodStarts)
        }
    }

    /// The compact weekly status of one window: "Out · back in 9h 35m", "Out in ≈2d 4h", "74% left". Nil without
    /// a reading of the current window (none, a new window, a reset that passed).
    struct WeeklyStatus: Sendable, Equatable {
        let text: String
        let tone: ProviderSummary.Limit.Tone
        /// Smaller is more urgent: out now, then running out soonest, then the least left.
        let urgency: Double
    }

    static func weeklyStatus(_ window: UsagePanelState.Window?, now: Date) -> WeeklyStatus? {
        guard let window, let used = window.pct, window.rolled != true else { return nil }
        if let reset = window.resetsAt, reset <= now.timeIntervalSince1970 {
            return nil
        }
        let verdict = UsageLimitVerdict(window: window, now: now)
        let left = max(0, 100 - used)
        if used >= 100 || verdict == .outNow {
            let text: String = if let reset = window.resetsAt, reset > now.timeIntervalSince1970 {
                "Out · back in \(UsageFormat.duration(reset - now.timeIntervalSince1970))"
            } else {
                "Out now"
            }
            return WeeklyStatus(text: text, tone: .bad, urgency: -1)
        }
        if case let .outIn(time, _) = verdict {
            let hit = window.liveForecast(now: now)?.hitAt.map { $0 - now.timeIntervalSince1970 } ?? 0
            // Red only when running out within 24 hours; multi-day run-out is a warning, not an outage.
            let tone: ProviderSummary.Limit.Tone = hit <= 24 * 3600 ? .bad : .warning
            return WeeklyStatus(text: "Out in ≈\(time)", tone: tone, urgency: max(0, hit) / 1e9)
        }
        let tone: ProviderSummary.Limit.Tone = if left <= 10 {
            .bad
        } else if verdict == .enough {
            .good
        } else {
            .neutral
        }
        return WeeklyStatus(
            text: "\(UsageFormat.percent(left)) left",
            tone: tone,
            urgency: 1 + left)
    }

    private static func tone(_ verdict: UsageLimitVerdict) -> ProviderSummary.Limit.Tone {
        switch verdict {
        case .enough: .good
        case .mayRunOut: .warning
        case .outIn, .outNow: .bad
        case .unknown: .neutral
        }
    }}
