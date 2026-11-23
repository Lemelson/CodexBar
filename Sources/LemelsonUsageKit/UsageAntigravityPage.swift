import SwiftUI

// MARK: - The page as menu rows

/// The Antigravity (Gemini) page: one combined page in place of the stock Antigravity card, built from the
/// same parts as the Claude pages.
///
/// Menu integration, parallel to `addLemelsonLimits` in `StatusItemController+LemelsonUsagePanel.swift`:
///
///     guard let page = UsageAntigravityPage(state: state, now: now, width: width) else { stock card }
///     for row in page.rows {
///         let item = makeMenuCardItem(row.view, id: row.id, width: width,
///                                     heightCacheScope: row.heightCacheScope,
///                                     heightCacheFingerprint: row.heightFingerprint,
///                                     containsInteractiveControls: row.hasControls, ...)
///         // Limit rows: wrap like the Claude limit rows (highlight bridge with the chevron, empty click
///         // handler) and register `row.detail` with the hover panel under `row.id`.
///         if row.separatorAfter { menu.addItem(.separator()) }
///     }
///
/// Every view is laid out at the fixed `width` it was given; hover details at `detailWidth`. Ids are stable
/// across rebuilds. Limit rows start with `lemelsonLimit-` (the prefix the Claude hover wiring looks for),
/// every id starts with `lemelson` (the prefix the warm-row recycling looks for).
@MainActor
public struct UsageAntigravityPage {
    public enum Part: Equatable, Sendable {
        /// "Antigravity · 12m ago".
        case header
        /// A 5-hour or weekly limit row; the only rows with a hover detail.
        case limit(UsagePanelState.WindowKind)
        /// One sentence instead of the limit rows: no quota readings yet, or the collector's step failed.
        case notice
        /// Totals, per-day chart and models; contains the period switch when the history is long enough.
        case spend
        /// Cache hits and misses.
        case cache
        /// What a full limit is worth at API prices; absent without a rate.
        case value
        /// Pace legend, what is exact and what is estimated, when the summary was updated.
        case footer
    }

    public struct Row: Identifiable {
        public let id: String
        public let part: Part
        /// The row content, already framed to the page width.
        public let view: AnyView
        /// The hover detail of a limit row, built on demand at `detailWidth`; nil for other rows.
        public let detail: (@MainActor () -> AnyView)?
        /// The row has a control that takes clicks (the period switch).
        public let hasControls: Bool
        /// A menu separator goes after this row.
        public let separatorAfter: Bool
        public let heightCacheScope: String
        /// Changes when the row's height may change: the summary was rewritten, or ten minutes passed
        /// (the age of a reading changes the caption length).
        public let heightFingerprint: String
    }

    public static let idPrefix = "lemelsonAntigravity-"
    /// Same prefix as the Claude limit rows, so the hover panel wiring that looks for it picks these up.
    public static let limitRowPrefix = "lemelsonLimit-antigravity-"
    public static let defaultDetailWidth: CGFloat = 340

    public let block: UsageAntigravityBlock
    public let rows: [Row]
    public let detailWidth: CGFloat

    /// Nil when the summary has no Antigravity block: then the stock card stays.
    /// `clock` gives the time a hover detail is built at (as for Claude, the moment it is first shown);
    /// the preview passes its fixed time.
    public init?(
        state: UsagePanelState,
        now: Date,
        width: CGFloat,
        detailWidth: CGFloat = UsageAntigravityPage.defaultDetailWidth,
        refreshing: Bool = false,
        clock: @escaping @MainActor () -> Date = { Date() })
    {
        guard let block = state.antigravity else { return nil }
        self.block = block
        self.detailWidth = detailWidth
        let stamp = Int(state.generatedAt)
        let ageBucket = Int(now.timeIntervalSince1970 / 600)
        let fingerprint = "\(stamp):\(ageBucket)"
        var rows: [Row] = []
        func add(
            _ part: Part,
            _ name: String,
            _ view: some View,
            separatorAfter: Bool = false,
            hasControls: Bool = false,
            detail: (@MainActor () -> AnyView)? = nil)
        {
            let id: String = if case let .limit(kind) = part {
                Self.limitRowPrefix + kind.rawValue
            } else {
                Self.idPrefix + name
            }
            rows.append(Row(
                id: id,
                part: part,
                view: AnyView(view),
                detail: detail,
                hasControls: hasControls,
                separatorAfter: separatorAfter,
                heightCacheScope: "lemelson-antigravity-\(name)",
                heightFingerprint: fingerprint))
        }

        add(.header, "header", UsageAccountHeaderView(account: block.account, now: now, width: width, showsDot: false))
        let windows = block.limitWindows
        if let error = block.error {
            add(.notice, "notice", UsageAntigravityNoticeView(
                text: "Antigravity's data could not be read this time.",
                detail: error,
                width: width), separatorAfter: true)
        } else if windows.isEmpty {
            add(.notice, "notice", UsageAntigravityNoticeView(
                text: "No quota readings yet: CodexBar has not recorded a 5-hour or weekly window.",
                detail: nil,
                width: width), separatorAfter: true)
        } else {
            for (index, (kind, window)) in windows.enumerated() {
                add(
                    .limit(kind),
                    "limit-\(kind.rawValue)",
                    UsageLimitRowView(
                        kind: kind,
                        window: window,
                        now: now,
                        width: width,
                        sessionsLeft: block.sessionsLeft(for: kind, now: now),
                        title: UsageAntigravityBlock.rowTitle(kind),
                        sources: .single),
                    separatorAfter: index == windows.count - 1,
                    detail: {
                        AnyView(Self.detail(kind: kind, window: window, block: block, now: clock(), width: detailWidth))
                    })
            }
        }
        if block.error == nil {
            let spend = UsageAntigravitySpend(block: block, now: now)
            add(.spend, "spend", UsageAntigravitySpendView(spend: spend, width: width),
                separatorAfter: true, hasControls: spend.offered.count > 1)
            if UsageAntigravityCacheView.hasContent(block) {
                add(.cache, "cache", UsageAntigravityCacheView(block: block, width: width),
                    separatorAfter: true)
            }
            if UsageAntigravityValueView.hasContent(block) {
                add(.value, "value", UsageAntigravityValueView(block: block, width: width), separatorAfter: true)
            }
        }
        let hasPaceMark = windows.contains { UsagePace.make(window: $0.1, kind: $0.0, now: now) != nil }
        add(.footer, "footer", UsageFooterView(
            state: state,
            now: now,
            width: width,
            refreshing: refreshing,
            showsLegend: hasPaceMark,
            showsYouChip: false,
            note: Self.footnote(block)), separatorAfter: true)
        self.rows = rows
    }

    /// The hover detail of one limit row.
    public static func detail(
        kind: UsagePanelState.WindowKind,
        window: UsagePanelState.Window,
        block: UsageAntigravityBlock,
        now: Date,
        width: CGFloat = UsageAntigravityPage.defaultDetailWidth) -> UsageLimitDetailPanelView
    {
        UsageLimitDetailPanelView(
            account: block.account,
            kind: kind,
            window: window,
            now: now,
            width: width,
            sessionsLeft: block.sessionsLeft(for: kind, now: now),
            title: UsageAntigravityBlock.detailTitle(kind),
            sources: .single)
    }

    /// What is exact and what is estimated, in the style of the Claude footnotes.
    static func footnote(_ block: UsageAntigravityBlock) -> String {
        "Beta. Tokens: exact, from this Mac's Antigravity files. Dollars: an estimate at Gemini API prices."
    }
}

// MARK: - Notice

/// One sentence in place of the limit rows.
struct UsageAntigravityNoticeView: View {
    let text: String
    let detail: String?
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .frame(width: self.width, alignment: .leading)
    }
}

// MARK: - Spend

/// Today, 7 days and a period; spend per day stacked by model; models. Same layering as Claude's Spend:
/// every offered period is laid out once and the switch only changes which layer is visible.
/// The period is the menu-wide choice (`UsagePanelSelection`); a period this history does not reach
/// shows the longest one it has.
public struct UsageAntigravitySpendView: View {
    let spend: UsageAntigravitySpend
    let width: CGFloat

    public init(spend: UsageAntigravitySpend, width: CGFloat) {
        self.spend = spend
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if self.spend.hasSpend {
                UsageAntigravitySpendHeader(spend: self.spend)
                UsageAntigravityPeriodStack(spend: self.spend)
            } else {
                Text("Spend")
                    .font(.system(size: 12.5, weight: .semibold))
                UsageNote(text: "No Antigravity calls recorded on this Mac yet.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }
}

/// The estimate label, the period switch (only when the history is longer than one period) and the totals.
struct UsageAntigravitySpendHeader: View {
    let spend: UsageAntigravitySpend
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let period = self.spend.effective(self.selection.spendPeriod)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center) {
                // Next to the period switch the label has a third of the row: the short form then.
                ViewThatFits(in: .horizontal) {
                    ForEach(self.spend.offered.count > 1
                        ? ["Estimate · API prices", "API estimate"]
                        : ["This Mac · estimate at Gemini API prices", "Estimate at Gemini API prices"], id: \.self)
                    { label in
                        Text(label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                Spacer(minLength: 6)
                if self.spend.offered.count > 1 {
                    Picker("Period", selection: Binding(
                        get: { self.spend.effective(self.selection.spendPeriod) },
                        set: { self.selection.spendPeriod = $0 }))
                    {
                        ForEach(self.spend.offered) { period in
                            Text(period.short).tag(period)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            HStack(alignment: .top, spacing: 8) {
                UsageSpendTile(title: "Today", use: self.spend.today)
                UsageSpendTile(title: "Last 7 days", use: self.spend.week)
                UsageSpendTile(title: period.title, use: self.spend[period].whole)
            }
        }
    }
}

struct UsageAntigravityPeriodStack: View {
    let spend: UsageAntigravitySpend
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let chosen = self.spend.effective(self.selection.spendPeriod)
        ZStack(alignment: .topLeading) {
            ForEach(self.spend.offered) { period in
                let shown = period == chosen
                UsageAntigravityPeriodLayer(data: self.spend[period], offered: self.spend.offered)
                    .equatable()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
    }
}

/// One period: chart and model rows. Every period has the same rows (the models of the whole history), so
/// all layers have one height and a switch never changes the menu.
struct UsageAntigravityPeriodLayer: View, Equatable {
    let data: UsageAntigravitySpend.Period
    let offered: [UsageSpendPeriod]

    static let nameWidth: CGFloat = 58

    var body: some View {
        let total = self.data.whole.usd
        VStack(alignment: .leading, spacing: 9) {
            UsageSpendDayChart(data: self.data.chart, offered: self.offered)
            VStack(alignment: .leading, spacing: 5) {
                UsageModelHeader(title: "By model · \(self.data.period.short)")
                ForEach(self.data.rows) { row in
                    UsageModelRow(
                        name: row.label,
                        use: row.use,
                        total: total,
                        color: row.color.color,
                        nameWidth: Self.nameWidth)
                }
                if let note = self.data.otherNote {
                    Text(note)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
    }
}

// MARK: - Cache

/// "Cache 94% read · 6% missed": how much of the prompts Antigravity read back from Gemini's cache.
public struct UsageAntigravityCacheView: View {
    let block: UsageAntigravityBlock
    let width: CGFloat

    public init(block: UsageAntigravityBlock, width: CGFloat) {
        self.block = block
        self.width = width
    }

    /// The span shown large: a week is steady; today and 30 days are the fallbacks.
    private static let spans: [(key: String, title: String)] = [("7d", "last 7 days"), ("30d", "last 30 days"),
                                                               ("today", "today")]

    static func main(_ block: UsageAntigravityBlock) -> (key: String, title: String, miss: Double)? {
        for span in self.spans {
            if let miss = block.cache[span.key]?.missPct {
                return (span.key, span.title, miss)
            }
        }
        return nil
    }

    static func hasContent(_ block: UsageAntigravityBlock) -> Bool {
        self.main(block) != nil
    }

    private static func percent(_ value: Double) -> String {
        UsageFormat.percent(min(100, max(0, value)))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let main = Self.main(self.block) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Cache")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("\(Self.percent(100 - main.miss)) read · \(Self.percent(main.miss)) missed")
                        .font(.system(size: 12.5, weight: .semibold))
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text(main.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                let others = [("today", "Today"), ("30d", "30 days"), ("7d", "7 days")].compactMap { key, title in
                    key == main.key ? nil : self.block.cache[key]?.missPct.map { "\(title) \(Self.percent($0)) missed" }
                }.prefix(2)
                if !others.isEmpty {
                    Text(others.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                UsageNote(text: "Of each prompt: read from Gemini's cache (10–20× cheaper) or missed "
                    + "(full input price).")
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(width: self.width, alignment: .leading)
    }
}

// MARK: - Value

/// What a full limit is worth at Gemini API prices, and "You pay / You get" when the plan price is known.
/// Left out entirely without a rate: no dashes.
public struct UsageAntigravityValueView: View {
    let block: UsageAntigravityBlock
    let width: CGFloat

    public init(block: UsageAntigravityBlock, width: CGFloat) {
        self.block = block
        self.width = width
    }

    static func hasContent(_ block: UsageAntigravityBlock) -> Bool {
        block.error == nil && (block.capacity(.week) != nil || block.capacity(.fiveHour) != nil)
    }

    private static let weeksPerMonth = 30.44 / 7

    public var body: some View {
        let week = self.block.capacity(.week)
        let session = self.block.account.has5h == false ? nil : self.block.capacity(.fiveHour)
        let priced = self.priced(week: week)
        VStack(alignment: .leading, spacing: 4) {
            // Same title line as the Claude Value card: the multiple sits large on the right.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Value")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 6)
                if let priced {
                    Text(UsageFormat.times(priced.month / priced.price))
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(UsagePalette.single)
                }
            }
            if let week {
                self.line("100% of the weekly limit", week, suffix: " at API prices")
            }
            if let session {
                self.line("100% of the 5-hour limit", session, suffix: week == nil ? " at API prices" : "")
            }
            if let priced {
                let scale = max(priced.month, priced.price)
                VStack(alignment: .leading, spacing: 3) {
                    UsageValueBar(label: "You pay", value: priced.price, scale: scale,
                                  color: Color.secondary.opacity(0.7), strong: false)
                    UsageValueBar(label: "You get", value: priced.month, scale: scale, color: UsagePalette.single,
                                  strong: true)
                    Text("Per month: the plan price vs. full weekly limits.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 3)
            }
            UsageNote(text: self.basis)
                .padding(.top, 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(width: self.width, alignment: .leading)
    }

    /// The plan price a month and a month of full weekly limits, when both are known.
    private func priced(week: Double?) -> (price: Double, month: Double)? {
        guard let week, let price = self.block.account.planPriceUsd, price > 0 else { return nil }
        return (price, self.block.account.value?.monthOpusUsd ?? week * Self.weeksPerMonth)
    }

    private var basis: String {
        let pairs = self.block.valuePairs ?? self.block.account.rates?["7d"]?.pairs
        if let pairs, pairs > 0 {
            return "Measured from \(Int(pairs)) pairs of quota readings and the dollars spent between them."
        }
        return "Measured from pairs of quota readings and the dollars spent between them."
    }

    private func line(_ title: String, _ usd: Double, suffix: String) -> some View {
        (Text(title)
            + Text(" ≈ \(UsageFormat.usd(usd))").fontWeight(.semibold)
            + Text(suffix).foregroundStyle(.secondary))
            .font(.system(size: 11))
            .monospacedDigit()
            .lineLimit(1)
    }
}
