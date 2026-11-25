import SwiftUI

// MARK: - The page as menu rows

/// One page for a provider with a single account (Antigravity, Codex), in place of its stock card, built
/// from the same parts as the Claude pages:
///
///   limit card     `UsageLimitCardHeader`, a `UsageLimitCardRow` per window (`.single` sources), the app's
///                  compact facts (`extras`, e.g. Codex credits), as on Claude Limits
///   spend          `UsageSpendHeader` + `UsagePeriodStack` + `UsageSpendDayChart` + `UsageModelRows`, as on
///                  Claude Spend, split by the provider's models
///   value          `UsageValueBlock`, as on Claude Value
///   footer         `UsageFooterView`, with the time-mark legend
///   cache row      `UsageCacheRowView`, placed by the menu among its action rows (`cacheRow`)
///
/// What differs between providers is a `UsageProviderSpec` (name, tint, model names, price words).
///
/// Menu integration, parallel to `addLemelsonLimits` in `StatusItemController+LemelsonUsagePanel.swift`:
///
///     guard let page = UsageProviderPage(spec: .codex, state: state, now: now, width: width) else { stock }
///     for row in page.rows {
///         let item = makeMenuCardItem(row.inCard ? LemelsonHighlightBridge(content: row.view) : row.view,
///                                     id: row.id, width: width,
///                                     heightCacheScope: row.heightCacheScope,
///                                     heightCacheFingerprint: row.heightFingerprint,
///                                     containsInteractiveControls: row.hasControls,
///                                     layout: row.inCard ? .joined : .standalone,
///                                     onClick: row.detail == nil ? nil : {})
///         // Rows with `detail`: register it with the hover panel under `row.id`.
///         if row.separatorAfter { menu.addItem(.separator()) }
///     }
///
/// Every view is laid out at the fixed `width` it was given; hover details at `detailWidth`. Ids are stable
/// across rebuilds. Limit rows start with `lemelsonLimit-<provider>-` (the prefix the hover wiring looks
/// for), every other id with `spec.idPrefix` (the prefix the warm-row recycling looks for).
@MainActor
public struct UsageProviderPage {
    public enum Part: Equatable, Sendable {
        /// The card header: name, plan, age of an old reading.
        case header
        /// A 5-hour or weekly limit row; has a hover detail.
        case limit(UsagePanelState.WindowKind)
        /// One sentence instead of the limit rows: no quota readings yet, or the collector's step failed.
        case notice
        /// A compact fact the app put inside the card, by its id.
        case fact(String)
        /// Totals, per-day chart and models; contains the period switch when the history is long enough.
        case spend
        /// The prompt cache row: not in `rows`, see `cacheRow`.
        case cache
        /// What a full limit is worth at API prices; absent without a rate or a reason.
        case value
        /// Time-mark legend, what is exact and what is estimated, when the summary was updated.
        case footer
    }

    public struct Row: Identifiable {
        public let id: String
        public let part: Part
        /// The row content, already framed to the page width.
        public let view: AnyView
        /// The hover detail, built on demand at `detailWidth`; nil for rows without one.
        public let detail: (@MainActor () -> AnyView)?
        /// The row has a control that takes clicks (the period switch).
        public let hasControls: Bool
        /// A menu separator goes after this row.
        public let separatorAfter: Bool
        /// A slice of the limit card: lay it out joined to its neighbours (no row padding); it draws its own
        /// highlight and chevron, so it wants the highlight state but no chevron from the menu.
        public let inCard: Bool
        public let heightCacheScope: String
        /// Changes when the row's height may change: the summary was rewritten, or ten minutes passed
        /// (the age of a reading changes the caption length).
        public let heightFingerprint: String
    }

    /// A compact row the app adds to the card after the limit rows (Codex: credits balance, limit reset
    /// credits), with an optional hover detail.
    public struct Extra {
        public let fact: UsageLimitCardFact
        public let detail: (@MainActor () -> AnyView)?

        public init(fact: UsageLimitCardFact, detail: (@MainActor () -> AnyView)? = nil) {
            self.fact = fact
            self.detail = detail
        }
    }

    public static let defaultDetailWidth: CGFloat = 340

    public let spec: UsageProviderSpec
    public let block: UsageProviderBlock
    public let rows: [Row]
    public let detailWidth: CGFloat
    /// The one-line "Prompt cache" row for the menu's footer area (next to Status Page), with its detail
    /// panel; nil without cache data. Not part of `rows`: the menu places it among its own action rows.
    public let cacheRow: Row?

    /// Nil when the summary has no block for this provider: then the stock card stays.
    /// `clock` gives the time a hover detail is built at (as for Claude, the moment it is first shown);
    /// the preview passes its fixed time.
    public init?(
        spec: UsageProviderSpec,
        state: UsagePanelState,
        now: Date,
        width: CGFloat,
        detailWidth: CGFloat = UsageProviderPage.defaultDetailWidth,
        refreshing: Bool = false,
        extras: [Extra] = [],
        clock: @escaping @MainActor () -> Date = { Date() })
    {
        guard let block = spec.block(in: state) else { return nil }
        self.spec = spec
        self.block = block
        self.detailWidth = detailWidth
        let stamp = Int(state.generatedAt)
        let ageBucket = Int(now.timeIntervalSince1970 / 600)
        let fingerprint = "\(stamp):\(ageBucket)"
        let scope = "lemelson-\(spec.key.rawValue)-"
        var rows: [Row] = []
        func add(
            _ part: Part,
            _ name: String,
            _ view: some View,
            separatorAfter: Bool = false,
            hasControls: Bool = false,
            inCard: Bool = false,
            fingerprint extra: String = "",
            detail: (@MainActor () -> AnyView)? = nil)
        {
            let id: String = if case let .limit(kind) = part {
                spec.limitRowPrefix + kind.rawValue
            } else {
                spec.idPrefix + name
            }
            rows.append(Row(
                id: id,
                part: part,
                view: AnyView(view),
                detail: detail,
                hasControls: hasControls,
                separatorAfter: separatorAfter,
                inCard: inCard,
                heightCacheScope: scope + name,
                heightFingerprint: fingerprint + extra))
        }

        // The card: header, then the limit rows (or one notice), then the app's facts.
        let style = spec.cardStyle
        let windows = block.limitWindows
        let notice: (text: String, detail: String?)? = if let error = block.error {
            ("\(spec.name)'s data could not be read this time.", error)
        } else if windows.isEmpty {
            ("No quota readings yet: CodexBar has not recorded a 5-hour or weekly window.", nil)
        } else {
            nil
        }
        let slices = (notice == nil ? windows.count : 1) + extras.count
        var slice = 0
        func isLast() -> Bool {
            slice += 1
            return slice == slices
        }
        add(.header, "header", UsageLimitCardHeader(
            name: spec.name,
            style: style,
            plan: spec.shortPlan(block.account.planName ?? block.worth?.planName),
            measuredAt: block.account.measuredAt,
            now: now,
            width: width,
            hasLimits: slices > 0), separatorAfter: slices == 0, inCard: true)
        if let notice {
            let last = isLast()
            add(.notice, "notice", UsageLimitCardNoticeRow(
                text: notice.text, detail: notice.detail, style: style, width: width, last: last),
                separatorAfter: last, inCard: true)
        } else {
            for (kind, window) in windows {
                let last = isLast()
                add(
                    .limit(kind),
                    "limit-\(kind.rawValue)",
                    UsageLimitCardRow(
                        kind: kind,
                        window: window,
                        style: style,
                        now: now,
                        width: width,
                        sources: .single,
                        sessionsLeft: block.sessionsLeft(for: kind, now: now),
                        sessionsNote: block.sessionsMeasuringCaption(for: kind, now: now),
                        last: last),
                    separatorAfter: last,
                    inCard: true,
                    detail: {
                        AnyView(Self.detail(kind: kind, window: window, block: block, now: clock(), width: detailWidth))
                    })
            }
        }
        for extra in extras {
            let last = isLast()
            add(
                .fact(extra.fact.id),
                "fact-\(extra.fact.id)",
                UsageLimitCardFactRow(
                    fact: extra.fact, style: style, width: width, last: last, hasDetail: extra.detail != nil),
                separatorAfter: last,
                inCard: true,
                fingerprint: extra.fact.caption == nil ? ":1" : ":2",
                detail: extra.detail)
        }

        if block.error == nil {
            let spend = UsageProviderSpend(block: block, spec: spec, now: now)
            add(.spend, "spend", UsageProviderSpendView(spend: spend, spec: spec, width: width),
                separatorAfter: true, hasControls: spend.offered.count > 1)
            if UsageProviderValueView.hasContent(block, spec: spec, now: now) {
                add(.value, "value", UsageProviderValueView(block: block, spec: spec, width: width, now: now),
                    separatorAfter: true)
            }
        }
        let hasMark = windows.contains { UsageLimitTimeMark.make(window: $0.1, kind: $0.0, now: now) != nil }
        add(.footer, "footer", UsageFooterView(
            state: state,
            now: now,
            width: width,
            refreshing: refreshing,
            showsLegend: hasMark,
            showsYouChip: false,
            note: Self.footnote(block, spec: spec)), separatorAfter: true)
        self.rows = rows
        self.cacheRow = UsageCacheSummary.provider(block, spec: spec).map { summary in
            Row(
                id: summary.rowID,
                part: .cache,
                view: AnyView(UsageCacheRowView(summary: summary, width: width)),
                detail: { AnyView(UsageCachePanelView(summary: summary, width: detailWidth)) },
                hasControls: false,
                separatorAfter: false,
                inCard: false,
                heightCacheScope: scope + "cache",
                heightFingerprint: fingerprint)
        }
    }

    /// The hover detail of one limit row: the same panel as a Claude limit, single source.
    public static func detail(
        kind: UsagePanelState.WindowKind,
        window: UsagePanelState.Window,
        block: UsageProviderBlock,
        now: Date,
        width: CGFloat = UsageProviderPage.defaultDetailWidth) -> UsageLimitDetailPanelView
    {
        UsageLimitDetailPanelView(
            account: block.account,
            kind: kind,
            window: window,
            now: now,
            width: width,
            sessionsLeft: block.sessionsLeft(for: kind, now: now),
            sources: .single,
            sessionsNote: block.sessionsMeasuringSentence(for: kind, now: now))
    }

    /// What is exact and what is estimated, in the style of the Claude footnotes.
    static func footnote(_ block: UsageProviderBlock, spec: UsageProviderSpec) -> String {
        (block.beta ? "Beta. " : "")
            + "Tokens: exact, from \(spec.source). Dollars: an estimate at \(spec.prices)."
    }
}

// MARK: - Spend

/// Today, 7 days and a period; spend per day stacked by model; models. The same parts as Claude's Spend
/// (`UsageSpendHeader`, `UsagePeriodStack`, `UsageSpendDayChart`, `UsageModelRows`): every offered period is
/// laid out once and the switch only changes which layer is visible. The period is the menu-wide choice
/// (`UsagePanelSelection`); a period this history does not reach shows the longest one it has.
public struct UsageProviderSpendView: View {
    let spend: UsageProviderSpend
    let spec: UsageProviderSpec
    let width: CGFloat

    public init(spend: UsageProviderSpend, spec: UsageProviderSpec, width: CGFloat) {
        self.spend = spend
        self.spec = spec
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if self.spend.hasSpend {
                UsageSpendHeader(
                    labels: UsageSpendHeader.labels(prices: self.spec.prices, hasSwitch: self.spend.offered.count > 1),
                    offered: self.spend.offered,
                    today: self.spend.today,
                    week: self.spend.week,
                    periods: Dictionary(uniqueKeysWithValues: self.spend.offered.map { ($0, self.spend[$0].whole) }))
                UsagePeriodStack(offered: self.spend.offered) { period in
                    UsageProviderPeriodLayer(data: self.spend[period], offered: self.spend.offered)
                }
            } else {
                Text("Spend")
                    .font(.system(size: 12.5, weight: .semibold))
                UsageNote(text: "No \(self.spec.name) calls recorded on this Mac yet.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }
}

/// One period: chart and model rows. Every period has the same rows (the models of the whole history), so
/// all layers have one height and a switch never changes the menu.
struct UsageProviderPeriodLayer: View, Equatable {
    let data: UsageProviderSpend.Period
    let offered: [UsageSpendPeriod]

    /// Provider model names ("Hydrogen", "Sol Mini") are longer than Claude's.
    static let nameWidth: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            UsageSpendDayChart(data: self.data.chart, offered: self.offered)
            UsageModelRows(
                title: "By model · \(self.data.period.short)",
                lines: self.data.rows,
                total: self.data.whole.usd,
                nameWidth: Self.nameWidth,
                note: self.data.otherNote)
        }
    }
}
