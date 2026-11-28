import SwiftUI

// MARK: - The Codex tab: Limits · Spend · Value for every Codex account

/// The modes of the Codex tab, the same three as on the Claude tab.
public enum UsageCodexMode: String, CaseIterable, Sendable {
    case limits
    case spend
    case value
}

/// Numbers CodexBar holds in memory for one Codex account that may be newer than the summary: its own read of
/// every visible account (`codexAccountSnapshots`). The page shows them until the collector has taken them in.
public struct UsageCodexLive: Sendable, Equatable {
    /// When CodexBar read the limits (Unix seconds).
    public var measuredAt: Double
    public var fiveHour: UsageQuotaLiveReading.Window?
    public var week: UsageQuotaLiveReading.Window?
    /// The plan name as CodexBar shows it ("Plus", "Pro 5x").
    public var plan: String?
    public var creditsLeft: Double?
    /// Expiry of each available limit reset credit (nil: no expiry date); nil without reset credit data.
    public var resetCredits: [Date?]?
    /// When the credits balance was read (Unix seconds); nil without a balance reading.
    public var creditsAt: Double?
    /// When the limit reset credits were read (Unix seconds); nil: with the limits (`measuredAt`).
    public var resetCreditsAt: Double?

    public init(
        measuredAt: Double,
        fiveHour: UsageQuotaLiveReading.Window?,
        week: UsageQuotaLiveReading.Window?,
        plan: String? = nil,
        creditsLeft: Double? = nil,
        resetCredits: [Date?]? = nil,
        creditsAt: Double? = nil,
        resetCreditsAt: Double? = nil)
    {
        self.measuredAt = measuredAt
        self.fiveHour = fiveHour
        self.week = week
        self.plan = plan
        self.creditsLeft = creditsLeft
        self.resetCredits = resetCredits
        self.creditsAt = creditsAt
        self.resetCreditsAt = resetCreditsAt
    }

    /// When the reset credits of this reading were taken; nil without reset credit data.
    var resetCreditsReadAt: Double? {
        self.resetCredits == nil ? nil : self.resetCreditsAt ?? self.measuredAt
    }
}

/// The Codex tab as menu rows, one mode at a time, built from the shared parts of the Claude tab:
///
///   Limits  one `UsageLimitCardHeader` + `UsageLimitCardRow`s card per account (active first, the same
///           tints and badges as on Claude Limits), the account's credits as card facts, then the footer
///   Spend   `UsageSpendHeader`, Accounts | Models, a per-day chart per split with the day panel and drag to
///           zoom, "By model", one `UsageSpendAccountRowView` per account (hover: weeks and models), the
///           calls no account owns, then the footer
///   Value   one card: an account switcher, the account's `UsageValueBlock` and its limit by month or week
///
/// Every mode ends with the "Prompt cache" line row (`lineRows`). Rows have the same shape as a provider
/// page's (`UsageProviderPage.Row`) and the same id prefixes (`spec.idPrefix`, `spec.limitRowPrefix`), so the
/// menu adds, recycles and warms them in the same way. Ids carry the mode and the account id, so the rows of
/// one mode never stand in for another's.
@MainActor
public struct UsageCodexPage {
    public typealias Row = UsageProviderPage.Row

    public static let spec = UsageProviderSpec.codex

    public let mode: UsageCodexMode
    public let block: UsageProviderBlock
    /// The accounts in card order (active first), with CodexBar's newer readings merged in.
    public let entries: [UsageProviderBlock]
    public let rows: [Row]
    /// "Prompt cache", for the menu's footer area (as on the Claude tab).
    public let lineRows: [Row]
    /// The Spend chart's day panel; nil in the other modes or without spend.
    public let chartDayDetail: (key: String, build: @MainActor () -> AnyView)?
    /// The catalog behind `chartDayDetail` (every account's share of each day), for the preview.
    public let spendDayCatalog: UsageDayDetailCatalog?
    public let detailWidth: CGFloat

    /// Nil when the summary has no Codex block: then the stock tab stays.
    ///   - live: CodexBar's in-memory reads by account id (lowercase); newer ones replace the summary's.
    ///   - showsCredits / showsResetCredits: CodexBar's own settings for those facts.
    ///   - privateNames: CodexBar's "Hide personal info" is on: the name shown for each account id (lowercase),
    ///     e.g. "Account 1"; an account missing from it is "Account <n>" by its place in the summary. Nil: the
    ///     summary's names. Tints stay (they are no personal info); the badge shows the account's number.
    public init?(
        state: UsagePanelState,
        now: Date,
        width: CGFloat,
        detailWidth: CGFloat = UsageProviderPage.defaultDetailWidth,
        mode: UsageCodexMode,
        refreshing: Bool = false,
        live: [String: UsageCodexLive] = [:],
        showsCredits: Bool = true,
        showsResetCredits: Bool = true,
        privateNames: [String: String]? = nil,
        clock: @escaping @MainActor () -> Date = { Date() })
    {
        let spec = Self.spec
        guard let original = spec.block(in: state) else { return nil }
        self.mode = mode
        self.detailWidth = detailWidth
        let originals = Self.entries(of: original, live: live)
        // Tints and chart colors follow the person (their name in the summary), so they are taken before
        // the names are hidden; the badge then shows the account's number instead of its initials.
        let names = privateNames.map { Self.privateNames(of: original, given: $0) }
        var styles: [String: UsageLimitCardStyle] = [:]
        for (position, entry) in originals.enumerated() where styles[entry.account.uuid] == nil {
            let style = Self.style(of: entry, position: position, in: original)
            styles[entry.account.uuid] = names?[entry.account.uuid.lowercased()].map { name in
                UsageLimitCardStyle(
                    tint: style.tint, initials: Self.privateBadge(name, position: position), active: style.active)
            } ?? style
        }
        let series = Self.accountSeries(originals, in: original).map { line in
            guard let name = names?[line.id.lowercased()] else { return line }
            return UsageProviderSpend.AccountSeries(id: line.id, name: name, color: line.color, daily: line.daily)
        }
        let block = names.map { Self.renamed(original, names: $0) } ?? original
        let entries = names.map { names in originals.map { Self.renamed($0, names: names) } } ?? originals
        self.block = block
        self.entries = entries
        let styleOf: (UsageProviderBlock, Int) -> UsageLimitCardStyle = { entry, position in
            styles[entry.account.uuid] ?? Self.style(of: entry, position: position, in: block)
        }
        let stamp = Int(state.generatedAt)
        let ageBucket = Int(now.timeIntervalSince1970 / 600)
        let fingerprint = "\(stamp):\(ageBucket)"
        let scope = "lemelson-codex-\(mode.rawValue)-"
        var rows: [Row] = []
        func add(
            _ part: UsageProviderPage.Part,
            id: String,
            _ view: some View,
            scope name: String,
            separatorAfter: Bool = false,
            hasControls: Bool = false,
            inCard: Bool = false,
            fingerprint extra: String = "",
            detail: (@MainActor () -> AnyView)? = nil)
        {
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
        let prefix = spec.idPrefix + mode.rawValue + "-"
        var chartDay: (key: String, build: @MainActor () -> AnyView)?
        var dayCatalog: UsageDayDetailCatalog?

        switch mode {
        case .limits:
            for (position, entry) in entries.enumerated() {
                let uuid = entry.account.uuid.lowercased()
                let style = styleOf(entry, position)
                let windows = entry.error == nil ? entry.limitWindows : []
                let notice: (text: String, detail: String?)? = if let error = entry.error {
                    ("This account's data could not be read this time.", error)
                } else if windows.isEmpty {
                    (refreshing ? "Refreshing limits…" : "No limits collected yet.", nil)
                } else {
                    nil
                }
                let extras = entry.error == nil
                    ? Self.facts(
                        of: entry, live: live[uuid], showsCredits: showsCredits,
                        showsResetCredits: showsResetCredits, now: now, detailWidth: detailWidth)
                    : []
                let slices = (notice == nil ? windows.count : 1) + extras.count
                var slice = 0
                func isLast() -> Bool {
                    slice += 1
                    return slice == slices
                }
                let cardScope = "card-\(uuid)-"
                add(
                    .header,
                    id: prefix + "header-\(uuid)",
                    UsageLimitCardHeader(
                        name: entry.account.displayName,
                        style: style,
                        plan: spec.shortPlan(entry.account.planName),
                        measuredAt: entry.account.lastMeasuredAt,
                        now: now,
                        width: width,
                        hasLimits: slices > 0),
                    scope: cardScope + "header",
                    separatorAfter: slices == 0,
                    inCard: true,
                    fingerprint: ":\(entry.account.isActive)")
                if let notice {
                    let last = isLast()
                    add(
                        .notice,
                        id: prefix + "notice-\(uuid)",
                        UsageLimitCardNoticeRow(
                            text: notice.text, detail: notice.detail, style: style, width: width, last: last),
                        scope: cardScope + "notice",
                        separatorAfter: last,
                        inCard: true,
                        fingerprint: ":\(entry.account.isActive):\(notice.text)")
                } else {
                    for (index, (kind, window)) in windows.enumerated() {
                        let last = isLast()
                        add(
                            .limit(kind),
                            id: spec.limitRowPrefix + "\(uuid)-\(kind.rawValue)",
                            UsageLimitCardRow(
                                kind: kind,
                                window: window,
                                style: style,
                                now: now,
                                width: width,
                                sources: .single,
                                sessionsLeft: entry.sessionsLeft(for: kind, now: now),
                                sessionsNote: entry.sessionsMeasuringCaption(for: kind, now: now),
                                last: last,
                                afterHeader: index == 0),
                            scope: cardScope + "limit-\(kind.rawValue)",
                            separatorAfter: last,
                            inCard: true,
                            fingerprint: ":\(entry.account.isActive):\(Int(window.measuredAt ?? 0))",
                            detail: {
                                AnyView(UsageProviderPage.detail(
                                    kind: kind, window: window, block: entry, now: clock(), width: detailWidth))
                            })
                    }
                }
                for extra in extras {
                    let last = isLast()
                    add(
                        .fact(extra.fact.id),
                        id: prefix + "fact-\(uuid)-\(extra.fact.id)",
                        UsageLimitCardFactRow(
                            fact: extra.fact, style: style, width: width, last: last, hasDetail: extra.detail != nil),
                        scope: cardScope + "fact-\(extra.fact.id)",
                        separatorAfter: last,
                        inCard: true,
                        fingerprint: ":\(entry.account.isActive):" + (extra.fact.caption ?? ""),
                        detail: extra.detail)
                }
            }

        case .spend:
            let spend = UsageProviderSpend(block: block, spec: spec, now: now, accounts: series)
            let chartID = spec.idPrefix + "spend-chart"
            add(
                .spend,
                id: prefix + "summary",
                UsageCodexSpendView(spend: spend, spec: spec, width: width, chartID: chartID),
                scope: "summary",
                separatorAfter: true,
                hasControls: true)
            if spend.hasSpend {
                let catalog = spend.dayDetailCatalog(chartID: chartID, spec: spec, now: now)
                dayCatalog = catalog
                chartDay = (key: catalog.panelKey, build: {
                    AnyView(UsageDayDetailPanelView(catalog: catalog, width: detailWidth))
                })
            }
            let spends = Dictionary(
                entries.map { ($0.account.uuid, UsageProviderSpend(block: $0, spec: spec, now: now)) },
                uniquingKeysWith: { first, _ in first })
            let colors = Dictionary(series.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first })
            let showsAccounts = !block.accounts.isEmpty
            if showsAccounts {
                for (position, entry) in entries.enumerated() {
                    let uuid = entry.account.uuid
                    let color = colors[uuid] ?? .account(position)
                    add(
                        .fact("account"),
                        id: prefix + "account-\(uuid.lowercased())",
                        UsageSpendAccountRowView(
                            account: entry.error == nil ? entry.account : Self.unavailable(entry),
                            colorIndex: position,
                            width: width,
                            now: now,
                            color: color.color),
                        scope: "account",
                        fingerprint: ":row",
                        detail: {
                            AnyView(UsageCodexAccountPanelView(
                                entries: entries,
                                selected: uuid,
                                spends: spends,
                                spec: spec,
                                now: now,
                                width: detailWidth))
                        })
                }
                if let note = UsageCodexUnattributedRow.text(block.unattributed, spend: spend) {
                    add(
                        .fact("unattributed"),
                        id: prefix + "unattributed",
                        UsageCodexUnattributedRow(text: note, width: width),
                        scope: "unattributed",
                        fingerprint: ":\(note.count)")
                }
                if let last = rows.indices.last, rows.count > 1 {
                    rows[last] = rows[last].withSeparator()
                }
            }

        case .value:
            let spends = Dictionary(
                entries.map { ($0.account.uuid, UsageProviderSpend(block: $0, spec: spec, now: now)) },
                uniquingKeysWith: { first, _ in first })
            let styles = Dictionary(
                entries.enumerated().map { ($1.account.uuid, styleOf($1, $0)) },
                uniquingKeysWith: { first, _ in first })
            add(
                .value,
                id: prefix + "card",
                UsageCodexValueCardView(
                    entries: entries,
                    spends: spends,
                    tints: styles.mapValues(\.tint),
                    spec: spec,
                    width: width,
                    until: state.generatedDate),
                scope: "card",
                separatorAfter: true,
                hasControls: true)
        }

        add(
            .footer,
            id: prefix + "footer",
            UsageFooterView(
                state: state,
                now: now,
                width: width,
                refreshing: refreshing,
                showsLegend: false,
                showsYouChip: false,
                compact: true),
            scope: "footer",
            separatorAfter: true,
            fingerprint: ":\(refreshing)")
        self.rows = rows
        self.chartDayDetail = chartDay
        self.spendDayCatalog = dayCatalog
        self.lineRows = UsageCacheSummary.provider(block, spec: spec).map { summary in
            [Row(
                id: summary.rowID,
                part: .cache,
                view: AnyView(UsageCacheRowView(summary: summary, width: width)),
                detail: { AnyView(UsageCachePanelView(summary: summary, width: detailWidth)) },
                hasControls: false,
                separatorAfter: false,
                inCard: false,
                heightCacheScope: "lemelson-codex-cache",
                heightFingerprint: fingerprint)]
        } ?? []
    }

    // MARK: Accounts

    /// The accounts of the block in card order: the active one first, the rest in the summary's order (the
    /// order of `account-names.json`). An older summary without `accounts` gives the block itself.
    public static func entries(
        of block: UsageProviderBlock,
        live: [String: UsageCodexLive] = [:]) -> [UsageProviderBlock]
    {
        let accounts = block.accounts.isEmpty ? [block] : block.accounts
        let merged = accounts.map { entry in
            live[entry.account.uuid.lowercased()].map { Self.merged(entry, with: $0) } ?? entry
        }
        return merged.enumerated().sorted { lhs, rhs in
            if lhs.element.account.isActive != rhs.element.account.isActive {
                return lhs.element.account.isActive
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The card style: the account's own tint and badge (the same as on Claude Limits); the block itself
    /// (an older summary) keeps the Codex tint.
    public static func style(
        of entry: UsageProviderBlock,
        position: Int,
        in block: UsageProviderBlock) -> UsageLimitCardStyle
    {
        guard !block.accounts.isEmpty else { return Self.spec.cardStyle }
        return UsageLimitCardStyle(account: entry.account, fallbackIndex: Self.colorIndex(of: entry, in: block))
    }

    /// An account's chart color index: its position in the summary, not in card order, so it does not change
    /// when another account becomes active.
    static func colorIndex(of entry: UsageProviderBlock, in block: UsageProviderBlock) -> Int {
        block.accounts.firstIndex { $0.account.uuid == entry.account.uuid } ?? 0
    }

    static func accountSeries(
        _ entries: [UsageProviderBlock],
        in block: UsageProviderBlock) -> [UsageProviderSpend.AccountSeries]
    {
        guard !block.accounts.isEmpty else { return [] }
        return entries.map { entry in
            UsageProviderSpend.AccountSeries(
                id: entry.account.uuid,
                name: entry.account.displayName,
                color: .accountTint(entry.account, fallbackIndex: Self.colorIndex(of: entry, in: block)),
                daily: entry.error == nil ? entry.account.daily ?? [] : [])
        }
    }

    /// An entry the collector failed on, as an account the shared rows show as one quiet line.
    private static func unavailable(_ entry: UsageProviderBlock) -> UsagePanelState.Account {
        var account = entry.account
        account.error = entry.error
        return account
    }

    /// The name shown for every account of the block while personal info is hidden: CodexBar's label when
    /// it gave one, else "Account <n>" by the account's place in the summary (after CodexBar's numbers).
    static func privateNames(of block: UsageProviderBlock, given: [String: String]) -> [String: String] {
        // An older summary without the list has the block itself ("Codex"): nothing personal to hide.
        let accounts = block.accounts
        var names: [String: String] = [:]
        var taken = Set(given.values)
        for (index, entry) in accounts.enumerated() {
            let id = entry.account.uuid.lowercased()
            if let name = given[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                names[id] = name
                continue
            }
            // The lowest number from its place on that CodexBar's own labels do not use.
            var number = index + 1
            while taken.contains("Account \(number)") {
                number += 1
            }
            names[id] = "Account \(number)"
            taken.insert("Account \(number)")
        }
        return names
    }

    /// The badge of a hidden account: the number of its "Account <n>" label, else its place.
    static func privateBadge(_ name: String, position: Int) -> String {
        let digits = name.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? String(position + 1) : String(digits.prefix(2))
    }

    /// The block (and its accounts) with the names hidden: the summary's name, short name and e-mail of every
    /// account become its private name.
    static func renamed(_ block: UsageProviderBlock, names: [String: String]) -> UsageProviderBlock {
        var block = block
        if let name = names[block.account.uuid.lowercased()] {
            block.account.name = name
            block.account.short = name
        }
        block.accounts = block.accounts.map { Self.renamed($0, names: names) }
        return block
    }

    /// CodexBar's newer reading of the account in place of the summary's: the percent, reset time and time of
    /// each window it read, the plan name when the summary has none, and the credits when they are newer.
    static func merged(_ entry: UsageProviderBlock, with live: UsageCodexLive) -> UsageProviderBlock {
        guard entry.error == nil else { return entry }
        var entry = entry
        let newest = entry.account.lastMeasuredAt
            ?? (entry.account.windows ?? [:]).values.compactMap(\.measuredAt).max()
        if newest.map({ live.measuredAt > $0 }) ?? true {
            var windows = entry.account.windows ?? [:]
            for (kind, reading) in [(UsagePanelState.WindowKind.fiveHour, live.fiveHour), (.week, live.week)] {
                guard let reading else { continue }
                var window = windows[kind.rawValue] ?? UsagePanelState.Window(source: "live")
                // A reset passed since the summary's reading: its forecast and series belong to the old window.
                if let old = window.resetsAt, let new = reading.resetsAt, abs(old - Double(new)) > 3600 {
                    window = UsagePanelState.Window(source: "live")
                }
                window.pct = reading.pct
                window.measuredAt = live.measuredAt
                window.resetsAt = reading.resetsAt.map(Double.init) ?? window.resetsAt
                window.source = "live"
                window.rolled = false
                if var series = window.series {
                    series.append([live.measuredAt, reading.pct, nil])
                    window.series = series
                }
                windows[kind.rawValue] = window
            }
            if live.fiveHour != nil {
                // A 5-hour window again (after weekly-only readings): the card shows it again.
                entry.account.has5h = true
            } else if live.week != nil {
                // A weekly-only reading: the account's older 5-hour reading is stale, not current.
                windows.removeValue(forKey: UsagePanelState.WindowKind.fiveHour.rawValue)
                entry.account.has5h = false
            }
            entry.account.windows = windows
            entry.account.lastMeasuredAt = live.measuredAt
        }
        if entry.account.planName == nil, let plan = live.plan {
            entry.account.planName = plan
        }
        // The balance and the reset credits are read apart (an account can have reset credits and no balance),
        // so each one is replaced when its own reading is newer.
        let summaryResetsAt = entry.credits?.resetCreditsReadAt ?? 0
        if let at = live.creditsAt, at > (entry.credits?.updatedAt ?? 0) {
            var credits = entry.credits ?? UsageProviderBlock.Credits(remaining: nil)
            if credits.resetCreditsAt == nil {
                // The summary's one time stood for both; the reset credits keep it.
                credits.resetCreditsAt = credits.updatedAt
            }
            credits.remaining = live.creditsLeft ?? credits.remaining
            credits.updatedAt = at
            entry.credits = credits
        }
        if let resets = live.resetCredits, let at = live.resetCreditsReadAt, at > summaryResetsAt {
            var credits = entry.credits ?? UsageProviderBlock.Credits(remaining: nil)
            credits.resetCredits = resets.map { $0?.timeIntervalSince1970 }
            credits.resetCreditsAt = at
            entry.credits = credits
        }
        return entry
    }

    /// The account's credits balance and limit reset credits as card facts, as CodexBar's own settings allow.
    static func facts(
        of entry: UsageProviderBlock,
        live: UsageCodexLive?,
        showsCredits: Bool,
        showsResetCredits: Bool,
        now: Date,
        detailWidth: CGFloat) -> [UsageProviderPage.Extra]
    {
        guard let credits = entry.credits else { return [] }
        let note: String? = switch credits.note {
        case "workspace balance": "The balance of the workspace, shared by its members."
        case "balance not read": "CodexBar could not read the balance this time."
        default: nil
        }
        // Dated credits not yet expired, soonest first, then the ones without an expiry date.
        let dated = credits.resetCredits.compactMap(\.self).filter { $0 > now.timeIntervalSince1970 }.sorted()
        let undated = credits.resetCredits.filter { $0 == nil }.count
        let resets = dated.map { Optional(Date(timeIntervalSince1970: $0)) }
            + Array(repeating: nil as Date?, count: undated)
        return UsageCodexFacts.extras(
            creditsLeft: showsCredits ? credits.remaining : nil,
            creditsNote: note,
            resetCredits: showsResetCredits && !resets.isEmpty ? resets : nil,
            now: now,
            detailWidth: detailWidth)
    }
}

extension UsageProviderPage.Row {
    /// The same row with a menu separator after it.
    func withSeparator() -> Self {
        Self(
            id: self.id,
            part: self.part,
            view: self.view,
            detail: self.detail,
            hasControls: self.hasControls,
            separatorAfter: true,
            inCard: self.inCard,
            heightCacheScope: self.heightCacheScope,
            heightFingerprint: self.heightFingerprint)
    }
}

// MARK: - Spend

/// Codex Spend's top: the totals, the period switch, Accounts | Models and every period's two charts laid out
/// once (a switch only changes which layer shows), then "By model". The same parts as Claude Spend.
struct UsageCodexSpendView: View {
    let spend: UsageProviderSpend
    let spec: UsageProviderSpec
    let width: CGFloat
    let chartID: String

    var body: some View {
        let spend = self.spend
        let chartID = self.chartID
        VStack(alignment: .leading, spacing: 9) {
            if spend.hasSpend {
                UsageSpendHeader(
                    labels: UsageSpendHeader.labels(prices: self.spec.prices, hasSwitch: spend.offered.count > 1),
                    offered: spend.offered,
                    today: spend.today,
                    week: spend.week,
                    periods: Dictionary(uniqueKeysWithValues: spend.offered.map { ($0, spend[$0].whole) }),
                    customSummary: { spend.customSummary(for: $0) })
                if spend.hasAccounts {
                    UsageSpendBreakdownRow()
                }
                UsagePeriodStack(
                    offered: spend.offered,
                    customLayer: { range in
                        UsageCodexPeriodLayer(data: spend.period(range: range), chartID: chartID)
                    }) { period in
                    UsageCodexPeriodLayer(data: spend[period], chartID: chartID)
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

/// One period: the chart by account or by model (both laid out, one visible), then the model rows.
struct UsageCodexPeriodLayer: View, Equatable {
    let data: UsageProviderSpend.Period
    let chartID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let accounts = self.data.accountChart {
                UsageProviderChartPair(models: self.data.chart, accounts: accounts, chartID: self.chartID)
            } else {
                UsageSpendDayChart(data: self.data.chart, chartID: self.chartID)
            }
            UsageModelRows(
                title: self.data.range.map { "By model · \($0.dayCount) days" } ?? "By model · \(self.data.period.short)",
                lines: self.data.rows,
                total: self.data.whole.usd,
                nameWidth: UsageProviderPeriodLayer.nameWidth,
                notes: (0...self.data.otherMembers.count).reversed().compactMap { self.data.otherNote(naming: $0) })
        }
    }
}

/// The chart by account and by model, both laid out, one visible: only this leaf observes the split.
struct UsageProviderChartPair: View {
    let models: UsageDayChartData
    let accounts: UsageDayChartData
    let chartID: String
    @ObservedObject private var selection = UsagePanelSelection.shared
    @Environment(\.usageChartLayerShown) private var layerShown

    var body: some View {
        let chosen = self.selection.spendBreakdown
        ZStack(alignment: .topLeading) {
            ForEach(UsageSpendBreakdown.allCases) { breakdown in
                let shown = breakdown == chosen
                UsageSpendChartLayer(data: breakdown == .accounts ? self.accounts : self.models, chartID: self.chartID)
                    .equatable()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
                    .environment(\.usageChartLayerShown, self.layerShown && shown)
            }
        }
    }
}

/// The calls of the summary no account owns, in one quiet line under the account rows, so the accounts and
/// the totals above reconcile in the open.
struct UsageCodexUnattributedRow: View {
    let text: String
    let width: CGFloat

    /// "No account · $18,016 in 180 days: calls before Oct 12 whose Codex logs name no account. Counted in the
    /// totals and the chart, not in any account row." Nil without the accounts split or below 50 cents.
    static func text(_ unattributed: UsageProviderBlock.Unattributed?, spend: UsageProviderSpend) -> String? {
        guard spend.hasAccounts, let unattributed, unattributed.error == nil,
              let usd = unattributed.usd180d, usd >= 0.5
        else { return nil }
        let until = unattributed.lastAt.map { " before " + UsageFormat.format(Date(timeIntervalSince1970: $0), "MMM d") }
            ?? ""
        return "No account · \(UsageFormat.usd(usd)) in 180 days: calls\(until) whose Codex logs name no account. "
            + "Counted in the totals and the chart, not in any account row."
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(UsagePalette.others)
                .frame(width: 8, height: 8)
            Text(self.text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .frame(width: self.width, alignment: .leading)
    }
}

/// The hover panel of a Codex Spend account row: a switcher between the accounts, then the chosen one's
/// weekly windows and its models over the menu's period. Every account is laid out, one visible, so the
/// panel keeps its height on a switch.
struct UsageCodexAccountPanelView: View {
    let entries: [UsageProviderBlock]
    let spends: [String: UsageProviderSpend]
    let spec: UsageProviderSpec
    let now: Date
    let width: CGFloat
    @State private var selected: String

    init(
        entries: [UsageProviderBlock],
        selected: String,
        spends: [String: UsageProviderSpend],
        spec: UsageProviderSpec,
        now: Date,
        width: CGFloat)
    {
        self.entries = entries
        self.spends = spends
        self.spec = spec
        self.now = now
        self.width = width
        self._selected = State(initialValue: selected)
    }

    var body: some View {
        let entries = self.entries
        VStack(alignment: .leading, spacing: 10) {
            if entries.count > 1 {
                UsageSegmentedControl(
                    options: entries.map(\.account.uuid),
                    title: { id in entries.first { $0.account.uuid == id }?.account.displayName ?? "" },
                    selection: self.$selected,
                    fillWidth: true)
            }
            ZStack(alignment: .topLeading) {
                ForEach(entries, id: \.account.uuid) { entry in
                    let shown = entry.account.uuid == self.selected
                    self.content(entry)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: self.width, alignment: .leading)
    }

    @ViewBuilder private func content(_ entry: UsageProviderBlock) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            UsagePanelTitle(
                title: "\(entry.account.displayName) · \(self.spec.name) spend",
                subtitle: "This Mac only, dollars at \(self.spec.prices).")
            if let error = entry.error {
                UsageUnavailableLine(text: "Collector error: \(error)")
            } else {
                if (entry.account.weeks ?? []).isEmpty {
                    UsageNote(text: "Weekly windows appear after the first limit reading of this account.")
                } else {
                    UsageWeekWindows(account: entry.account, now: self.now)
                }
                Divider()
                if let spend = self.spends[entry.account.uuid], spend.hasSpend {
                    UsageCodexAccountModels(spend: spend)
                } else {
                    UsageNote(text: "No \(self.spec.name) calls of this account on this Mac yet.")
                }
            }
        }
    }
}

/// The only part of the account panel that follows the menu's period (or zoom).
struct UsageCodexAccountModels: View {
    let spend: UsageProviderSpend
    @ObservedObject private var selection = UsagePanelSelection.shared

    var body: some View {
        let data = self.selection.customRange.map { self.spend.period(range: $0) }
            ?? self.spend[self.spend.effective(self.selection.spendPeriod)]
        UsageModelRows(
            title: data.range.map { "By model · \($0.dayCount) days" } ?? "By model · \(data.period.short)",
            lines: data.rows,
            total: data.whole.usd,
            nameWidth: UsageProviderPeriodLayer.nameWidth)
    }
}

// MARK: - Value

/// Codex Value: what each account's plan is worth at OpenAI API prices and whether its limit changes. One
/// switcher picks the account; every account is laid out, one visible, so a switch never changes the height.
struct UsageCodexValueCardView: View {
    let entries: [UsageProviderBlock]
    let spends: [String: UsageProviderSpend]
    let tints: [String: Color]
    let spec: UsageProviderSpec
    let width: CGFloat
    /// The summary's time: the current month counts its days up to here.
    let until: Date
    @State private var selected: String
    @ObservedObject private var selection = UsagePanelSelection.shared

    init(
        entries: [UsageProviderBlock],
        spends: [String: UsageProviderSpend],
        tints: [String: Color],
        spec: UsageProviderSpec,
        width: CGFloat,
        until: Date)
    {
        self.entries = entries
        self.spends = spends
        self.tints = tints
        self.spec = spec
        self.width = width
        self.until = until
        self._selected = State(initialValue: entries.first?.account.uuid ?? "")
    }

    var body: some View {
        let entries = self.entries
        VStack(alignment: .leading, spacing: 10) {
            Text("What the plan is worth")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if entries.count > 1 {
                UsageSegmentedControl(
                    options: entries.map(\.account.uuid),
                    title: { id in entries.first { $0.account.uuid == id }?.account.displayName ?? "" },
                    selection: self.$selected,
                    fillWidth: true)
            }
            UsageNote(text: "The same usage bought through the API at list prices, if the limit is used up.")
            self.stack { entry in
                self.worth(entry)
            }
            Divider()
            HStack(alignment: .center) {
                Text("Is the limit changing?")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                UsageSegmentedControl(
                    options: Array(UsageDriftPeriod.allCases),
                    title: \.title,
                    selection: self.$selection.driftPeriod)
                    .fixedSize()
            }
            Text(self.selection.driftPeriod == .month
                ? "A bar is a month of full weekly limits at \(self.spec.prices): its average week × 4.35. "
                + "Faded: under 2 weeks of it measured."
                : "A point is one weekly limit, used up completely, rated on that week's own readings.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                // Both captions take two or three lines; the taller one sets the height so a switch of the
                // period never moves the chart, and no line is cut.
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 40, alignment: .topLeading)
            self.stack { entry in
                self.drift(entry)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: self.width, alignment: .leading)
    }

    /// Every account's part laid out on top of each other, the chosen one visible.
    private func stack(@ViewBuilder _ part: @escaping (UsageProviderBlock) -> some View) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(self.entries, id: \.account.uuid) { entry in
                let shown = entry.account.uuid == self.selected
                part(entry)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
    }

    private func color(_ entry: UsageProviderBlock) -> Color {
        self.tints[entry.account.uuid] ?? self.spec.tint
    }

    @ViewBuilder private func worth(_ entry: UsageProviderBlock) -> some View {
        let color = self.color(entry)
        let name = entry.account.displayName
        let plan = self.spec.shortPlan(entry.account.planName)
        if let error = entry.error {
            UsageValueBlock(color: color, name: name, plan: plan, times: nil, content: .unavailable(
                "Collector error: \(error)"))
        } else if let spend = self.spends[entry.account.uuid],
                  let worth = UsageProviderWorth(block: entry, spec: self.spec, spend: spend)
        {
            VStack(alignment: .leading, spacing: 8) {
                switch worth.content {
                case let .reason(reason):
                    UsageValueBlock(
                        color: color,
                        name: name,
                        plan: worth.planName,
                        times: nil,
                        content: .waiting("No estimate yet: too few readings of the weekly limit.", reason: reason))
                case let .numbers(numbers):
                    UsageValueBlock(
                        color: color,
                        name: name,
                        plan: numbers.planName,
                        times: numbers.times,
                        content: .numbers(UsageValueBlock.Numbers(
                            paid: numbers.price,
                            got: numbers.month,
                            scale: max(1, numbers.month, numbers.price ?? 0),
                            priceNote: numbers.price == nil ? "Plan price not set, so there is no ×." : nil,
                            models: numbers.models)))
                }
                UsageNote(text: worth.footnote)
            }
        } else {
            UsageValueBlock(
                color: color,
                name: name,
                plan: plan,
                times: nil,
                content: .waiting(
                    "No estimate yet: it needs a few limit readings of this account.",
                    reason: entry.valueReason))
        }
    }

    @ViewBuilder private func drift(_ entry: UsageProviderBlock) -> some View {
        let color = self.color(entry)
        let points = (entry.account.drift ?? []).compactMap { item -> UsageDriftPoint? in
            guard item.usdPer100 > 0 else { return nil }
            return UsageDriftPoint(
                account: entry.account.displayName,
                color: color,
                date: Date(timeIntervalSince1970: item.weekEnd),
                usd: item.usdPer100)
        }
        if points.isEmpty {
            UsageNote(text: "Not enough readings yet: it needs at least one full week of this account.")
                .frame(height: 130, alignment: .topLeading)
        } else if self.selection.driftPeriod == .month {
            UsageDriftMonthChartView(series: [UsageDriftMonthSeries(
                id: entry.account.uuid,
                name: entry.account.displayName,
                color: color,
                months: UsageDriftMonths.months(of: points, until: self.until))])
        } else {
            UsageDriftChartView(
                points: points,
                series: [UsageDriftSeries(
                    id: entry.account.uuid, name: entry.account.displayName, color: color, points: points)])
        }
    }
}
