import AppKit
import CodexBarCore
import LemelsonUsageKit
import SwiftUI

// The Antigravity tab as one page of the fork (`UsageProviderPage` with `UsageProviderSpec.antigravity`), and the
// Codex tab in the same three modes as the Claude tab (`UsageCodexPage`: Limits · Spend · Value, with its own
// mode row and pin, every Codex account of the summary on it), in place of the stock card and the stock rows
// under it:
//   • Antigravity: Plan Usage, Cost (the stock Cost counts copied conversations twice);
//   • Codex: the account switcher or the stacked account cards, the usage card (session, weekly, the inline
//     cost dashboard), Limit Reset Credits, Credits, Extra usage (the same credits balance again, or the
//     monthly cap that the credits line already names), Plan Usage and Cost. Each account's credits balance
//     and limit reset credits come back as facts inside its card (`UsageCodexFacts`), "Buy Credits…" stays an
//     action row (the stock item, first under the page's line rows), and the OpenAI web charts the page has no
//     counterpart for (Usage breakdown, Credits history) stay as rows with their detail panel. CodexBar reads
//     every visible Codex account while the page is on (read-only OAuth usage, `shouldFetchAllCodexVisibleAccounts`);
//     each account's reading goes into the live file under its own key, and until the collector has taken it
//     in, the page shows CodexBar's newer numbers (`UsageCodexLive`). The account with the border and the dot
//     is the system account as CodexBar sees it now, so a switch shows at once.
//
// Entry points:
//   • `addLemelsonProviderPage`: from `addLemelsonUsagePanel` while the Antigravity or Codex tab is built;
//   • `lemelsonObserveProviderPages`: once at start (`wireBindings`): every fresh snapshot of the store goes
//     into the provider's live readings file (`UsageQuotaLiveWriter`), and while a menu is open the
//     collector then runs and the page is rebuilt with the new numbers;
//   • `lemelsonProviderPageMayBeShown`: on menu open and after each build of the open menu: asks the store
//     for a fresh reading when a page is shown (the footer says "refreshing" meanwhile).
//
// `defaults write com.steipete.codexbar lemelsonAntigravityPage stock` (or `lemelsonCodexPage stock`) brings
// the stock tab back (next menu build, no restart).

extension Notification.Name {
    /// Posted in-process right after CodexBar's "System Account" switch has written the new account
    /// (`CodexAccountPromotionService`), before its own refresh: the fork's Codex page follows at once.
    static let lemelsonCodexSystemAccountDidChange = Notification.Name("lemelson.codexSystemAccountDidChange")
}

@MainActor
final class LemelsonProviderPageState {
    static let antigravity = LemelsonProviderPageState(
        spec: .antigravity,
        provider: .antigravity,
        defaultsKey: "lemelsonAntigravityPage",
        writer: .antigravity)
    static let codex = LemelsonProviderPageState(
        spec: .codex,
        provider: .codex,
        defaultsKey: "lemelsonCodexPage",
        writer: .codex,
        modes: .codex)
    static let all = [LemelsonProviderPageState.antigravity, .codex]

    static func state(for provider: UsageProvider) -> LemelsonProviderPageState? {
        self.all.first { $0.provider == provider }
    }

    /// The page shown now, if the current page key is one of these tabs.
    static func state(forPageKey key: String) -> LemelsonProviderPageState? {
        self.all.first { $0.isShown(onPage: key) }
    }

    let spec: UsageProviderSpec
    let provider: UsageProvider
    let defaultsKey: String
    let writer: UsageQuotaLiveWriter
    /// The tab's modes (Codex); nil for a page of one mode (Antigravity).
    let modes: LemelsonModeStore?

    private init(
        spec: UsageProviderSpec,
        provider: UsageProvider,
        defaultsKey: String,
        writer: UsageQuotaLiveWriter,
        modes: LemelsonModeStore? = nil)
    {
        self.spec = spec
        self.provider = provider
        self.defaultsKey = defaultsKey
        self.writer = writer
        self.modes = modes
    }

    /// The mode shown; a page without modes is always Limits.
    var mode: LemelsonPanelMode {
        self.modes?.mode ?? .limits
    }

    /// The modes whose rows can be rendered ahead.
    var warmableModes: [LemelsonPanelMode] {
        self.modes == nil ? [.limits] : LemelsonPanelMode.allCases
    }

    /// "codex:limits" for a page with modes, "antigravity" for one without.
    func pageKey(mode: LemelsonPanelMode) -> String {
        self.modes == nil ? self.provider.rawValue : "\(self.provider.rawValue):\(mode.rawValue)"
    }

    /// Whether a page key names this tab (any of its modes).
    func isShown(onPage key: String) -> Bool {
        key == self.provider.rawValue || key.hasPrefix(self.provider.rawValue + ":")
    }

    /// The stock tab: asked for, or under tests (they check the author's cards, and must never write test
    /// readings into the real live files).
    var usesStockTab: Bool {
        SettingsStore.isRunningTests || UserDefaults.standard.string(forKey: self.defaultsKey) == "stock"
    }

    /// Rows of this page carry these ids (the warm rows of the Claude modes leave them alone).
    func owns(_ id: String) -> Bool {
        id.hasPrefix(self.spec.idPrefix) || id.hasPrefix(self.spec.limitRowPrefix)
    }

    /// "antigravity", "codex": for the log.
    var logName: String {
        self.spec.key.rawValue
    }

    /// Version of the summary the page was last built from.
    var renderedStateDate: Date?
    /// `updatedAt` of the last store snapshot handed to the live writer.
    var lastSnapshotAt: Date?
    /// The last live write handed to the writer: the next one waits for it.
    var liveWrite: Task<Void, Never>?
    /// Whether the store was fetching the provider at the last look.
    var wasRefreshing = false
    /// When the page last asked the store for a fresh reading.
    var lastRefreshRequest: Date?
    /// Width of the last build of the page.
    var width: CGFloat = 0
    /// Rendered rows of each mode while it is not in the menu, by row id.
    var warmRows: [LemelsonPanelMode: [String: NSView]] = [:]
    var warmWidth: CGFloat = 0
    /// The mode whose rows are in the menu now (or were, when another tab replaced the page).
    var renderedMode: LemelsonPanelMode?
    var isWarming = false
    var warmTimer: Timer?
    /// Codex: what CodexBar's last read of every visible account gave, by ChatGPT account id (lowercase), and
    /// the fingerprint of the records it came from (a new one writes their live lines).
    var liveByAccount: [String: UsageCodexLive] = [:]
    var lastAccountSnapshotsSignature: String?
    /// Codex: the ChatGPT account id of the live system account at the last look (a change is a switch).
    var lastSystemAccountID: String?
    /// Codex: the account a switch just made the system one, and when. It marks that account active until
    /// the collector writes a summary newer than the switch (that summary has the switch itself).
    var switchOverride: (id: String, at: Date)?
    /// Codex: whether the rows were last built with personal info hidden (a change renders them again).
    var renderedPrivately: Bool?

    /// Codex: the system account changed at `at`: the summary account `active` (its id in the summary, when
    /// known) is the active one until a newer summary, `system` is CodexBar's key of the new system account
    /// (`lemelsonCodexSystemAccountID`), and the rows rendered with the old account first are dropped.
    func noteSystemAccountSwitch(active: String?, system: String?, at: Date) {
        if let active {
            self.switchOverride = (active, at)
        }
        if let system {
            self.lastSystemAccountID = system
        }
        self.warmRows.removeAll()
    }

    /// Codex: the account a recent switch marks active for a summary written at `generatedAt` (Unix seconds);
    /// nil, and forgotten, once the summary is as new as the switch.
    func switchOverrideID(forSummaryAt generatedAt: Double) -> String? {
        guard let override = self.switchOverride else { return nil }
        guard generatedAt < override.at.timeIntervalSince1970 else {
            self.switchOverride = nil
            return nil
        }
        return override.id
    }
}

/// Whether the summary can draw the fork's Codex page: the one check the page itself, the stock account
/// switcher and the all-accounts refresh share, so a summary without a `codex` block (a corrupt or partial
/// file) never hides the stock switcher while the stock card is shown. Decoded once per version of the file.
@MainActor
enum LemelsonCodexPageReadiness {
    private static var cached: (url: URL, date: Date, ready: Bool)?

    static var summaryHasCodexBlock: Bool {
        self.summaryHasCodexBlock(at: UsagePanelStore.defaultURL)
    }

    /// A missing or unreadable file, or one without a `codex` block, is not ready (never fails open).
    static func summaryHasCodexBlock(at url: URL) -> Bool {
        guard let date = UsagePanelStore.modificationDate(of: url) else {
            self.cached = nil
            return false
        }
        if let cached = self.cached, cached.url == url, cached.date == date {
            return cached.ready
        }
        let ready = UsagePanelStore.load(from: url)?.codex != nil
        self.cached = (url, date, ready)
        return ready
    }

    /// The summary just read (by the page): its `codex` block decides for this version of the file.
    static func note(_ state: UsagePanelState?, at url: URL = UsagePanelStore.defaultURL) {
        guard let date = UsagePanelStore.modificationDate(of: url) else { return }
        self.cached = (url, date, state?.codex != nil)
    }
}

extension StatusItemController {
    /// The fork's Codex page draws the Codex tab (not `lemelsonCodexPage stock`, not under tests, with a
    /// summary that has a `codex` block, the same check as `addLemelsonProviderPage`): it shows every Codex
    /// account, so CodexBar reads all of them and its own account switcher stays out of the tab.
    static var lemelsonCodexPageShowsAllAccounts: Bool {
        !LemelsonProviderPageState.codex.usesStockTab && LemelsonCodexPageReadiness.summaryHasCodexBlock
    }

    /// A row of the Antigravity or the Codex page.
    static func lemelsonIsProviderPageRow(_ id: String) -> Bool {
        LemelsonProviderPageState.all.contains { $0.owns(id) }
    }

    /// The store is fetching the provider now, or the collector is rewriting the summary.
    func lemelsonProviderRefreshing(_ page: LemelsonProviderPageState) -> Bool {
        LemelsonPanelSession.shared.isRefreshing || self.store.refreshingProviders.contains(page.provider.instanceID)
    }

    // MARK: - The page

    /// Draws the Antigravity or Codex tab. Returns false (the stock card stays) for another tab, without the
    /// summary's block for the provider, or with `lemelson<Provider>Page stock`.
    func addLemelsonProviderPage(to menu: NSMenu, context: MenuCardContext, captureMenu: NSMenu? = nil) -> Bool {
        guard let page = LemelsonProviderPageState.state(for: context.currentProvider),
              self.menuCardRenderingEnabledForController, !page.usesStockTab
        else { return false }
        let loaded = UsagePanelStore.load()
        if page.provider == .codex {
            LemelsonCodexPageReadiness.note(loaded)
        }
        guard let state = loaded, page.spec.block(in: state) != nil else { return false }
        let started = CACurrentMediaTime()
        let mode = page.mode
        let warm = self.lemelsonTakeWarmProviderRows(page, width: context.menuWidth)
        if let modes = page.modes {
            // The tab's own mode row and pin, as on the Claude tab.
            let tab: LemelsonModeTab = .codex
            let capture = captureMenu ?? menu
            let switcher = NSMenuItem()
            switcher.view = LemelsonModeSwitcherView(
                tab: tab,
                selected: modes.mode,
                pinnedMode: modes.pinnedMode,
                width: context.menuWidth,
                onSelect: { [weak self, weak capture] mode in
                    self?.handleLemelsonModeSelection(mode, tab: tab, menu: capture)
                },
                onPin: { [weak self, weak capture] in
                    self?.handleLemelsonModePin(tab: tab, menu: capture)
                })
            switcher.isEnabled = false
            menu.addItem(switcher)
            menu.addItem(.separator())
        }
        guard let built = self.addLemelsonProviderRows(
            page, state: state, mode: mode, to: menu, width: context.menuWidth)
        else { return false }
        page.width = context.menuWidth
        if !page.isWarming, page.isShown(onPage: self.lemelsonCurrentPageKey()) {
            page.renderedMode = mode
        }
        let session = LemelsonPanelSession.shared
        // The page replaces the stock card's rows below it (Cost, Usage history, Plan Usage).
        session.stockExtrasVisible = false
        if page.provider == .codex {
            // The OpenAI web charts the page has no counterpart for stay as rows (the detail panel adopts them).
            let web = context.openAIContext
            session.keptOpenAIWebItems = OpenAIWebContext(
                hasUsageBreakdown: web.hasUsageBreakdown,
                hasCreditsHistory: web.hasCreditsHistory,
                hasCostHistory: false,
                canShowBuyCredits: false,
                hasOpenAIWebMenuItems: web.hasUsageBreakdown || web.hasCreditsHistory)
            // "Buy Credits…" stays: the stock item, right under the page's line rows (`addLemelsonPendingRows`).
            session.pendingBuyCredits = web.canShowBuyCredits
        }
        // Its "Plan worth" and "Prompt cache" rows go above the action rows, as the cache row on the Claude pages.
        session.pendingLineRows = built.lineRows
        // The other modes (or, built for the tab cache's warm-up while another tab is shown, all of them) are
        // rendered by the debounced warm-up, not a second time inside this pass.
        if !page.isWarming {
            self.lemelsonScheduleProviderWarmup()
        }
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Self.lemelsonLog.notice("\(page.logName, privacy: .public) page (\(mode.rawValue, privacy: .public)) built in \(ms) ms with \(warm) warm rows, \(built.rowCount) rows, open=\(self.openMenus[ObjectIdentifier(menu)] != nil)")
        }
        return true
    }

    /// What a build of a page's rows leaves for the rest of the menu.
    struct LemelsonProviderBuild {
        let rowCount: Int
        let lineRows: [LemelsonLineRow]
    }

    /// The page's rows in one mode, without its line rows (see `lemelsonLineRows(of:)`). Nil without a page.
    private func addLemelsonProviderRows(
        _ page: LemelsonProviderPageState,
        state: UsagePanelState,
        mode: LemelsonPanelMode,
        to menu: NSMenu,
        width: CGFloat) -> LemelsonProviderBuild?
    {
        let refreshing = self.lemelsonProviderRefreshing(page)
        let now = Date()
        let detailWidth = UsageHoverPanelController.panelWidth
        let rows: [UsageProviderPage.Row]
        let lineRows: [UsageProviderPage.Row]
        let chartDay: (key: String, build: @MainActor () -> AnyView)?
        let chartRowID: String
        var anotherAccount: (block: UsageProviderBlock, key: String?)?
        if page.provider == .codex {
            let hidden = self.settings.hiddenUsageItemIDs(for: .codex)
            let hidesPersonalInfo = self.settings.hidePersonalInfo
            guard let built = UsageCodexPage(
                state: self.lemelsonCodexStateWithSystemAccount(state),
                now: now,
                width: width,
                detailWidth: detailWidth,
                mode: mode.codexMode,
                refreshing: refreshing,
                live: page.liveByAccount,
                showsCredits: self.settings.showOptionalCreditsAndExtraUsage && !hidden.contains(.credits),
                showsResetCredits: !hidden.contains(.codexResetCredits),
                privateNames: hidesPersonalInfo ? self.lemelsonCodexPrivateNames() : nil)
            else { return nil }
            rows = built.rows
            lineRows = built.lineRows
            chartDay = built.chartDayDetail
            chartRowID = page.spec.idPrefix + "spend-summary"
        } else {
            // The account shown: when the collector's limits are of another one, the page says so instead.
            let accountKey = self.lemelsonAccountKey(page)
            guard let built = UsageProviderPage(
                spec: page.spec,
                state: state,
                now: now,
                width: width,
                detailWidth: detailWidth,
                refreshing: refreshing,
                accountKey: accountKey)
            else { return nil }
            rows = built.rows
            lineRows = built.lineRows
            chartDay = built.chartDayDetail
            chartRowID = page.spec.spendChartID
            anotherAccount = (built.block, accountKey)
        }
        page.renderedStateDate = UsagePanelStore.modificationDate()
        // The spend chart's day panel, keyed by the spend row's id so warm-up and cached tab swaps keep it.
        if let chartDay {
            self.lemelsonRegisterChartDayDetail(
                forRowID: chartRowID,
                .swiftUI(key: chartDay.key, width: detailWidth) {
                    chartDay.build()
                })
        }

        for row in rows {
            // The footer's caption changes with the refreshing state.
            let fingerprint = row.part == .footer ? "\(row.heightFingerprint):\(refreshing)" : row.heightFingerprint
            if row.part == .notice, let anotherAccount,
               UsageProviderPage.limitsOfAnotherAccount(anotherAccount.block, shown: anotherAccount.key)
            {
                Self.lemelsonLog.notice("\(page.logName, privacy: .public): limits in the summary are of another account, notice shown")
            }
            if let detail = row.detail {
                // As the Claude limit rows: the detail panel shows the window's chart at once and morphs
                // between the two rows; the empty click handler keeps the row highlightable. A card row draws
                // its own chevron and highlight.
                self.lemelsonRegisterDetail(.swiftUI(key: row.id, width: detailWidth) {
                    detail()
                })
                menu.addItem(self.makeMenuCardItem(
                    LemelsonHighlightBridge(content: row.view, showsChevron: !row.inCard),
                    id: row.id,
                    width: width,
                    heightCacheScope: row.heightCacheScope,
                    heightCacheFingerprint: fingerprint,
                    layout: row.inCard ? .joined : .standalone,
                    onClick: {}))
            } else if row.inCard {
                // The card header, a notice, a fact without detail: joined to the card's other slices, never
                // highlighted.
                menu.addItem(self.makeMenuCardItem(
                    row.view,
                    id: row.id,
                    width: width,
                    heightCacheScope: row.heightCacheScope,
                    heightCacheFingerprint: fingerprint,
                    layout: .joined))
            } else {
                menu.addItem(self.makeMenuCardItem(
                    row.view,
                    id: row.id,
                    width: width,
                    heightCacheScope: row.heightCacheScope,
                    heightCacheFingerprint: fingerprint,
                    // The period switch takes clicks; without this the row ignores them.
                    containsInteractiveControls: row.hasControls))
            }
            if row.separatorAfter {
                menu.addItem(.separator())
            }
        }
        return LemelsonProviderBuild(rowCount: rows.count, lineRows: Self.lemelsonLineRows(of: lineRows))
    }

    /// The summary with the Codex account CodexBar sees as the system account now marked active (border, dot,
    /// first card), so a switch made in CodexBar shows before the collector has written the next summary.
    /// Unchanged when CodexBar's account list is older than the summary (a switch made elsewhere, which the
    /// summary already has), not loaded yet, or the account is not in the summary.
    func lemelsonCodexStateWithSystemAccount(_ state: UsagePanelState) -> UsagePanelState {
        // A switch just made marks its account until the collector writes a summary after it (that summary
        // has the switch itself); then CodexBar's own view of the system account, when newer than the summary.
        guard let id = LemelsonProviderPageState.codex.switchOverrideID(forSummaryAt: state.generatedAt)
            ?? self.lemelsonCodexSystemAccountID(newerThan: state.generatedAt)
        else { return state }
        return Self.lemelsonCodexState(state, active: id)
    }

    /// The summary with the account of this id (lowercase ChatGPT account id or e-mail) marked active and the
    /// others not; unchanged when the account is not in the summary.
    static func lemelsonCodexState(_ state: UsagePanelState, active id: String) -> UsagePanelState {
        guard var block = state.codex, block.accounts.contains(where: { $0.account.uuid.lowercased() == id })
        else { return state }
        for index in block.accounts.indices {
            block.accounts[index].account.active = block.accounts[index].account.uuid.lowercased() == id
        }
        var state = state
        state.codex = block
        return state
    }

    /// The ChatGPT account id (lowercase) of the account CodexBar sees as the system one (`~/.codex/auth.json`),
    /// else its lowercase e-mail; nil while CodexBar's account list is not loaded.
    func lemelsonCodexSystemAccountID(newerThan generatedAt: Double? = nil) -> String? {
        if let generatedAt {
            guard let loadedAt = self.settings.cachedCodexAccountMenuProjection?.loadedAt,
                  loadedAt.timeIntervalSince1970 > generatedAt
            else { return nil }
        }
        guard let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay,
              let live = projection.visibleAccounts.first(where: { $0.id == projection.liveVisibleAccountID })
        else { return nil }
        return Self.lemelsonCodexSummaryKeys(of: live).first
    }

    /// "Hide personal info": CodexBar's own label of every visible Codex account ("Account 1", or "Account 1 ·
    /// <workspace>"), by each key the account can have in the summary.
    func lemelsonCodexPrivateNames() -> [String: String] {
        guard let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay else { return [:] }
        return Self.lemelsonCodexPrivateNames(projection.visibleAccounts)
    }

    static func lemelsonCodexPrivateNames(_ accounts: [CodexVisibleAccount]) -> [String: String] {
        let labels = CodexAccountSwitcherLabeling.labels(for: accounts, hidePersonalInfo: true)
        var names: [String: String] = [:]
        for account in accounts {
            guard let label = labels[account.id] else { continue }
            for key in Self.lemelsonCodexSummaryKeys(of: account) where names[key] == nil {
                names[key] = label
            }
        }
        return names
    }

    /// The keys a CodexBar account can have in the summary: its ChatGPT account id, else its e-mail (lowercase).
    static func lemelsonCodexSummaryKeys(of account: CodexVisibleAccount) -> [String] {
        [account.workspaceAccountID, account.email]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// The page's "Plan worth" and "Prompt cache" rows in the shape the menu footer takes.
    static func lemelsonLineRows(of rows: [UsageProviderPage.Row]) -> [LemelsonLineRow] {
        rows.compactMap { row in
            guard let detail = row.detail else { return nil }
            return LemelsonLineRow(
                id: row.id,
                view: row.view,
                detail: detail,
                heightCacheScope: row.heightCacheScope,
                heightFingerprint: row.heightFingerprint)
        }
    }

    /// The key CodexBar files the shown account's history under (`preferredAccountKey` of
    /// `history/<provider>.json`), resolved read-only by the store's own rules; nil until the history is loaded
    /// or when CodexBar has no key for the account. The live readings carry it, and the page compares it with
    /// the account of the collector's limits.
    func lemelsonAccountKey(_ page: LemelsonProviderPageState) -> String? {
        self.store.planUtilizationHistorySelection(for: page.provider, readOnly: true).accountKey
    }

    // MARK: - Rows rendered ahead of time

    // A freshly created hosting view takes a tenth of a second or more to lay out and paint its first frame
    // (the spend chart has a layer per period). The menu's own tab cache would hide that, but every
    // collector pass and store change empties it, and its refill waits while pages turn: the page then
    // came in late on the first visit, after a few empty frames. So the page keeps rendered rows of its
    // own, as the Claude modes do: built shortly after the menu opens, handed to the menu's row recycling
    // when the page is built, and taken back when another tab replaces it.

    /// Inside a populate pass, before the page's rows are made: the rows of the mode last shown that the
    /// outgoing menu left in the recycle pool are kept for that mode, and the rendered rows of the mode shown
    /// now go to the pool, where `makeMenuCardItem` picks them up by id. Only the shown mode's rows may be in
    /// the pool: a row nobody claims by id is handed to any row of the same type. Returns how many.
    private func lemelsonTakeWarmProviderRows(_ page: LemelsonProviderPageState, width: CGFloat) -> Int {
        self.lemelsonDropWarmRowsIfPrivacyChanged(page)
        // Only for the page being shown: the tab cache's own warm-up builds the page too, and its rows are
        // dropped with that cache.
        guard !page.isWarming, page.isShown(onPage: self.lemelsonCurrentPageKey()) else {
            return 0
        }
        let mode = page.mode
        if let leaving = page.renderedMode, leaving != mode {
            let stash = self.menuCardViewRecyclePool.filter { page.owns($0.key) }
            for id in stash.keys {
                self.menuCardViewRecyclePool.removeValue(forKey: id)
            }
            if !stash.isEmpty {
                page.warmRows[leaving, default: [:]].merge(stash) { _, new in new }
                page.warmWidth = page.width
            }
        }
        if abs(page.warmWidth - width) > 0.5 {
            page.warmRows.removeAll()
        }
        let warm = page.warmRows.removeValue(forKey: mode) ?? [:]
        for (id, view) in warm where self.menuCardViewRecyclePool[id] == nil {
            self.menuCardViewRecyclePool[id] = view
        }
        return warm.count
    }

    /// "Hide personal info" changed since the rows were rendered: they show the other names.
    private func lemelsonDropWarmRowsIfPrivacyChanged(_ page: LemelsonProviderPageState) {
        guard page.provider == .codex else { return }
        let hides = self.settings.hidePersonalInfo
        if let rendered = page.renderedPrivately, rendered != hides {
            page.warmRows.removeAll()
            self.lemelsonDropCachedContent(of: .codex)
        }
        page.renderedPrivately = hides
    }

    /// Inside a populate pass of another tab: the rows of a provider page that just left the menu are kept
    /// for the mode they were built in.
    func lemelsonKeepProviderRowsLeaving(except provider: UsageProvider?) {
        for page in LemelsonProviderPageState.all where page.provider != provider && !page.isWarming {
            let leaving = self.menuCardViewRecyclePool.filter { page.owns($0.key) }
            guard !leaving.isEmpty else { continue }
            for id in leaving.keys {
                self.menuCardViewRecyclePool.removeValue(forKey: id)
            }
            page.warmRows[page.renderedMode ?? page.mode, default: [:]].merge(leaving) { _, new in new }
            page.warmWidth = page.width
        }
    }

    /// The modes of a page with no rendered rows kept, but the one the menu shows (its rows are in the menu).
    private func lemelsonMissingWarmModes(_ page: LemelsonProviderPageState) -> [LemelsonPanelMode] {
        let shown = page.isShown(onPage: self.lemelsonCurrentPageKey()) ? page.mode : nil
        return page.warmableModes.filter { $0 != shown && page.warmRows[$0] == nil }
    }

    /// After a build of the open root menu: render the modes of each page that have no rows kept, shortly,
    /// once pages have stopped turning. A common-modes timer: main-actor tasks do not run while the menu
    /// tracks the pointer.
    func lemelsonScheduleProviderWarmup() {
        guard !SettingsStore.isRunningTests else { return }
        let enabled = self.store.enabledFirstPartyProvidersForDisplay()
        for page in LemelsonProviderPageState.all {
            // A page never shown yet is rendered at the width of the menu's last build.
            guard !page.usesStockTab, self.lemelsonWarmWidth(page) > 0, page.warmTimer == nil,
                  enabled.contains(page.provider), !self.lemelsonMissingWarmModes(page).isEmpty
            else { continue }
            let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    page.warmTimer = nil
                    guard let self, !self.openMenus.isEmpty else { return }
                    guard !self.lemelsonPostponesWarmup() else {
                        self.lemelsonScheduleProviderWarmup()
                        return
                    }
                    self.lemelsonWarmProviderRows(page)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            page.warmTimer = timer
        }
    }

    func lemelsonCancelProviderWarmups() {
        for page in LemelsonProviderPageState.all {
            page.warmTimer?.invalidate()
            page.warmTimer = nil
        }
    }

    private func lemelsonWarmWidth(_ page: LemelsonProviderPageState) -> CGFloat {
        page.width > 0 ? page.width : LemelsonPanelSession.shared.menuWidth
    }

    private func lemelsonWarmProviderRows(_ page: LemelsonProviderPageState) {
        let width = self.lemelsonWarmWidth(page)
        guard width > 0, self.menuCardRenderingEnabledForController,
              let state = UsagePanelStore.load(), page.spec.block(in: state) != nil
        else { return }
        self.lemelsonDropWarmRowsIfPrivacyChanged(page)
        if abs(page.warmWidth - width) > 0.5 {
            page.warmRows.removeAll()
        }
        let missing = self.lemelsonMissingWarmModes(page)
        guard !missing.isEmpty else { return }
        let started = CACurrentMediaTime()
        page.isWarming = true
        defer { page.isWarming = false }
        for mode in missing {
            let scratch = NSMenu()
            scratch.autoenablesItems = false
            guard let built = self.addLemelsonProviderRows(page, state: state, mode: mode, to: scratch, width: width)
            else { continue }
            self.addLemelsonLineRows(built.lineRows, to: scratch, width: width)
            var rows: [String: NSView] = [:]
            for item in scratch.items {
                guard let id = item.representedObject as? String, page.owns(id), let view = item.view else { continue }
                // Laying out now makes the first attach draw in the same frame as the page turn.
                view.layoutSubtreeIfNeeded()
                item.view = nil
                rows[id] = view
            }
            scratch.removeAllItems()
            page.warmRows[mode] = rows
        }
        page.warmWidth = width
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            let modes = missing.map(\.rawValue).joined(separator: ",")
            Self.lemelsonLog.notice("\(page.logName, privacy: .public) rows rendered ahead (\(modes, privacy: .public)) in \(ms) ms")
        }
    }

    // MARK: - Live readings

    /// Called once at start. Each provider's observation re-arms itself on every change of the store.
    func lemelsonObserveProviderPages() {
        guard !SettingsStore.isRunningTests else { return }
        self.lemelsonObserveAccountSwitches()
        for page in LemelsonProviderPageState.all {
            self.lemelsonObserve(page)
        }
    }

    private func lemelsonObserve(_ page: LemelsonProviderPageState) {
        withObservationTracking {
            _ = self.store.snapshot(for: page.provider.instanceID)?.updatedAt
            _ = self.store.refreshingProviders.contains(page.provider.instanceID)
            if page.provider == .codex {
                // CodexBar's read of every visible Codex account: limits and credits.
                _ = self.store.codexAccountSnapshots.count
                _ = self.store.codexAccountSnapshots.map(\.snapshot?.updatedAt)
                _ = self.store.codexAccountSnapshots.map(\.credits?.updatedAt)
                // The system account. The cached projection itself is not observable (`@ObservationIgnored`);
                // reading it here tracks the active source it is keyed by, and a switch made by CodexBar or by
                // Claude Switcher arrives through `lemelsonCodexSystemAccountDidSwitch` as well.
                _ = self.settings.cachedCodexAccountMenuProjection?.loadedAt
                _ = self.settings.codexVisibleAccountProjectionForMenuDisplay?.liveVisibleAccountID
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                // Re-arms the observation and handles the change (once).
                self?.lemelsonObserve(page)
            }
        }
        self.lemelsonProviderStoreDidChange(page)
    }

    private func lemelsonProviderStoreDidChange(_ page: LemelsonProviderPageState) {
        let log = Self.lemelsonLog
        let name = page.logName
        let pageShown = !self.openMenus.isEmpty && page.isShown(onPage: self.lemelsonCurrentPageKey())
        var rebuild = false

        let refreshing = self.store.refreshingProviders.contains(page.provider.instanceID)
        if refreshing != page.wasRefreshing {
            page.wasRefreshing = refreshing
            log.notice("\(name, privacy: .public) fetch \(refreshing ? "started" : "ended", privacy: .public)")
            // The footer shows the fetch while it runs.
            rebuild = true
        }

        var readings: [UsageQuotaLiveReading] = []
        if let snapshot = self.store.snapshot(for: page.provider.instanceID), snapshot.updatedAt != page.lastSnapshotAt {
            page.lastSnapshotAt = snapshot.updatedAt
            let account = self.lemelsonAccountKey(page)
            let reading = page.provider == .codex
                ? Self.lemelsonCodexReading(snapshot, account: account)
                : Self.lemelsonAntigravityReading(snapshot, account: account)
            if let reading {
                readings.append(reading)
            } else {
                log.notice("\(name, privacy: .public) live: no 5-hour or weekly window in the snapshot")
            }
        }
        if page.provider == .codex {
            let accounts = self.lemelsonCodexAccountsDidChange(page)
            readings += accounts.readings
            rebuild = rebuild || accounts.changed
            if accounts.changed {
                // Overview's Limits lists the same accounts with the same live numbers.
                self.lemelsonCodexLiveDidChangeForOverview()
            }
        }
        // The new numbers (and a switch's border, dot and card order) show at once; the live file is written
        // after, and only a line that went in rebuilds again (with the collector's pass started).
        if rebuild, pageShown, !page.usesStockTab {
            self.lemelsonRebuildOpenMenus()
        }
        guard !readings.isEmpty else { return }
        // The file work runs on the writer's own executor (it may wait for the collector's lock); the result
        // comes back here, on the main actor. Each write waits for the one before it, so lines keep their order.
        let writer = page.writer
        let previous = page.liveWrite
        page.liveWrite = Task { [weak self] in
            _ = await previous?.value
            var outcomes: [UsageQuotaLiveWriter.Outcome] = []
            for reading in readings {
                await outcomes.append(writer.record(reading))
            }
            self?.lemelsonLiveRecorded(page, readings: readings, outcomes: outcomes, rebuild: rebuild && !pageShown)
        }
    }

    /// Codex: CodexBar's newest read of every visible account, for the page (`liveByAccount`) and for the live
    /// file (one reading per account, under its own key); and whether the system account changed. Only when
    /// the records or the system account changed since the last look.
    private func lemelsonCodexAccountsDidChange(
        _ page: LemelsonProviderPageState) -> (readings: [UsageQuotaLiveReading], changed: Bool)
    {
        var changed = false
        if self.settings.codexVisibleAccountProjectionForMenuDisplay == nil {
            // CodexBar dropped its account list (a new active source): read it again now, so the border
            // and the dot follow without waiting for the menu's own revalidation.
            _ = self.settings.codexAccountReconciliationSnapshot
        }
        let system = self.lemelsonCodexSystemAccountID()
        if system != page.lastSystemAccountID {
            if page.lastSystemAccountID != nil, system != nil {
                Self.lemelsonLog.notice("codex: the system account changed, border and dot follow")
                // The tab cache's rows and the page's own warm rows were rendered with the old account first.
                page.warmRows.removeAll()
                self.lemelsonDropCachedContent(of: .codex)
            }
            page.lastSystemAccountID = system
            changed = true
        }
        let records = self.store.codexAccountSnapshots
        let signature = records.map { record in
            let at = record.snapshot?.updatedAt.timeIntervalSince1970 ?? 0
            let credits = record.credits?.updatedAt.timeIntervalSince1970 ?? 0
            return "\(record.id):\(at):\(credits)"
        }.joined(separator: ",")
        guard signature != page.lastAccountSnapshotsSignature else { return ([], changed) }
        page.lastAccountSnapshotsSignature = signature
        let live = Self.lemelsonCodexLive(records, now: Date())
        if live.byAccount != page.liveByAccount {
            page.liveByAccount = live.byAccount
            changed = true
        }
        return (live.readings, changed)
    }


    /// A Codex account switch, made in CodexBar ("System Account") or in Claude Switcher: CodexBar reads
    /// `~/.codex/auth.json` again, the page marks the new system account active until the collector's next
    /// summary, the rows rendered with the old one are dropped, open menus are rebuilt now (border, dot, card
    /// order and the new account's last numbers in the first frame), and a read-only Codex read starts.
    ///   - id: the account the switch made the system one, when the caller knows it (lowercase).
    ///   - rebuild: false when the caller rebuilds the open menus itself right after.
    func lemelsonCodexSystemAccountDidSwitch(to id: String? = nil, source: String, rebuild: Bool = true) {
        guard !SettingsStore.isRunningTests else { return }
        let page = LemelsonProviderPageState.codex
        guard !page.usesStockTab else { return }
        self.settings.invalidateCodexAccountReconciliationSnapshotCache()
        // Synchronous: the files are small, and the rebuild below needs the new live account.
        _ = self.settings.codexAccountReconciliationSnapshot
        let system = self.lemelsonCodexSystemAccountID()
        let now = Date()
        page.noteSystemAccountSwitch(active: id?.lowercased() ?? system, system: system, at: now)
        Self.lemelsonLog.notice("codex: system account switched (\(source, privacy: .public)), page follows at once")
        self.lemelsonDropCachedContent(of: .codex)
        if rebuild {
            self.invalidateMenus()
            if !self.openMenus.isEmpty {
                self.lemelsonRebuildOpenMenus()
            }
        }
        // The new account's numbers: CodexBar's own read (read-only OAuth), apart from the rebuild.
        page.lastRefreshRequest = now
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ProviderInteractionContext.$current.withValue(.background) {
                await self.store.refreshProvider(.codex, coalesceIfRefreshing: true)
            }
        }
    }

    /// CodexBar's read of each visible Codex account as the page's live numbers (by every key the account can
    /// have in the summary) and as live lines (keyed by `CodexHistoryOwnership.canonicalKey`, never an e-mail).
    static func lemelsonCodexLive(
        _ records: [CodexAccountUsageSnapshot],
        now: Date) -> (byAccount: [String: UsageCodexLive], readings: [UsageQuotaLiveReading])
    {
        var byAccount: [String: UsageCodexLive] = [:]
        var readings: [UsageQuotaLiveReading] = []
        for record in records {
            guard let snapshot = record.snapshot else { continue }
            let identity: CodexIdentity = if let id = record.account.workspaceAccountID {
                .providerAccount(id: id)
            } else {
                .emailOnly(normalizedEmail: record.account.email.lowercased())
            }
            let key = CodexHistoryOwnership.canonicalKey(for: identity)
            guard let reading = Self.lemelsonCodexReading(snapshot, account: key) else { continue }
            if key != nil {
                readings.append(reading)
            }
            let credits = record.credits
            let resetCredits = snapshot.codexResetCredits.map { inventory in
                inventory.availableInventory(at: now).credits.map(\.expiresAt)
            }
            let live = UsageCodexLive(
                measuredAt: snapshot.updatedAt.timeIntervalSince1970,
                fiveHour: reading.fiveHour,
                week: reading.week,
                plan: reading.plan,
                creditsLeft: credits.flatMap { $0.balanceReadSucceeded ? $0.remaining : nil },
                resetCredits: resetCredits,
                creditsAt: credits.map { $0.updatedAt.timeIntervalSince1970 },
                // Read with the limits, also for an account without a credits balance.
                resetCreditsAt: resetCredits == nil ? nil : snapshot.updatedAt.timeIntervalSince1970)
            for summaryKey in Self.lemelsonCodexSummaryKeys(of: record.account) where byAccount[summaryKey] == nil {
                byAccount[summaryKey] = live
            }
        }
        return (byAccount, readings)
    }

    /// After live lines were handled: logs each outcome (the values, never the account key), and when a line
    /// went in while a menu is open, runs the collector once so the page shows it.
    private func lemelsonLiveRecorded(
        _ page: LemelsonProviderPageState,
        readings: [UsageQuotaLiveReading],
        outcomes: [UsageQuotaLiveWriter.Outcome],
        rebuild: Bool)
    {
        let log = Self.lemelsonLog
        let name = page.logName
        var written = false
        for (reading, outcome) in zip(readings, outcomes) {
            if case let .failed(reason) = outcome {
                log.error("\(name, privacy: .public) live: write failed: \(reason, privacy: .public)")
                continue
            }
            written = written || outcome == .written
            let values = [("5h", reading.fiveHour), ("7d", reading.week)].compactMap { key, window in
                window.map { "\(key) \(UsageFormat.percent($0.pct))" }
            }.joined(separator: ", ")
            log.notice("\(name, privacy: .public) live: \(String(describing: outcome), privacy: .public) ts=\(reading.ts) \(values, privacy: .public) plan=\(reading.plan ?? "-", privacy: .private) account=\(reading.account ?? "-", privacy: .private)")
        }
        guard !self.openMenus.isEmpty else { return }
        // A new line only reaches the page through the collector; while the menu is open it runs now.
        if written {
            self.lemelsonStartRefreshIfDue(force: true)
        }
        // One rebuild for the whole change (the fetch's end, the new numbers, the collector's start).
        if (written || rebuild), !page.usesStockTab, page.isShown(onPage: self.lemelsonCurrentPageKey()) {
            self.lemelsonRebuildOpenMenus()
        }
    }

    /// The Gemini 5-hour and weekly quota of a snapshot. Other model groups ("Claude/GPT", versioned
    /// Gemini groups) are separate quotas and are not part of the page.
    static func lemelsonAntigravityReading(_ snapshot: UsageSnapshot, account: String? = nil) -> UsageQuotaLiveReading? {
        let windows = (snapshot.extraRateWindows ?? []).filter {
            $0.usageKnown && AntigravityStatusSnapshot.isQuotaSummaryWindowID($0.id)
        }
        func window(_ title: String) -> UsageQuotaLiveReading.Window? {
            windows.first { $0.title == title }.map {
                UsageQuotaLiveReading.Window(pct: $0.window.usedPercent, resetsAt: $0.window.resetsAt)
            }
        }
        // The plan or tier name the fetch gave (Google's paid tier, plan type or current tier), as is.
        let reading = UsageQuotaLiveReading(
            at: snapshot.updatedAt,
            fiveHour: window("Gemini 5-hour"),
            week: window("Gemini weekly"),
            plan: snapshot.loginMethod(for: .antigravity),
            account: account)
        return reading.isEmpty ? nil : reading
    }

    /// Codex's session (5-hour) and weekly window. Codex reports them as the primary and the secondary
    /// window; the window length decides when it is known (a plan with only a weekly window reports that as
    /// the primary one). Model-specific extra windows are separate pools and not part of the page.
    static func lemelsonCodexReading(_ snapshot: UsageSnapshot, account: String? = nil) -> UsageQuotaLiveReading? {
        var fiveHour: UsageQuotaLiveReading.Window?
        var week: UsageQuotaLiveReading.Window?
        for (slot, window) in [snapshot.primary, snapshot.secondary].enumerated() {
            guard let window, !window.isSyntheticPlaceholder, window.usedPercent.isFinite else { continue }
            let reading = UsageQuotaLiveReading.Window(pct: window.usedPercent, resetsAt: window.resetsAt)
            switch window.windowMinutes {
            case 300:
                fiveHour = fiveHour ?? reading
            case 10080:
                week = week ?? reading
            case nil:
                if slot == 0 { fiveHour = fiveHour ?? reading } else { week = week ?? reading }
            default:
                continue
            }
        }
        // The plan name as CodexBar shows it on the Codex card ("Plus", "Pro 20x").
        let plan = snapshot.loginMethod(for: .codex).map {
            CodexPlanFormatting.displayName($0) ?? UsageFormatter.cleanPlanName($0)
        }
        let reading = UsageQuotaLiveReading(
            at: snapshot.updatedAt, fiveHour: fiveHour, week: week, plan: plan, account: account)
        return reading.isEmpty ? nil : reading
    }

    // MARK: - Refresh while the page is shown

    /// Codex: a visible account has no read of its own in the last two minutes (the primary snapshot is the
    /// system account's only; the page shows every account).
    func lemelsonCodexAccountMissingFreshRead(now: Date) -> Bool {
        guard let projection = self.settings.codexVisibleAccountProjectionForMenuDisplay,
              projection.visibleAccounts.count > 1
        else { return false }
        return Self.lemelsonCodexAccountMissingFreshRead(
            visible: projection.visibleAccounts, records: self.store.codexAccountSnapshots, now: now)
    }

    static func lemelsonCodexAccountMissingFreshRead(
        visible: [CodexVisibleAccount],
        records: [CodexAccountUsageSnapshot],
        now: Date) -> Bool
    {
        visible.contains { account in
            guard let updated = records.first(where: { $0.id == account.id })?.snapshot?.updatedAt else { return true }
            return now.timeIntervalSince(updated) >= 120
        }
    }

    /// A page is (or may now be) on screen: unless the store fetched its provider in the last two minutes or
    /// is fetching it now, ask for a fresh reading.
    func lemelsonProviderPageMayBeShown(in menu: NSMenu) {
        guard menu.supermenu == nil, self.openMenus[ObjectIdentifier(menu)] != nil,
              self.menuCardRenderingEnabledForController,
              let page = LemelsonProviderPageState.state(forPageKey: self.lemelsonCurrentPageKey()),
              !page.usesStockTab,
              !self.store.refreshingProviders.contains(page.provider.instanceID)
        else { return }
        let now = Date()
        if let last = page.lastRefreshRequest, now.timeIntervalSince(last) < 120 { return }
        if let updated = self.store.snapshot(for: page.provider.instanceID)?.updatedAt, now.timeIntervalSince(updated) < 120,
           page.provider != .codex || !self.lemelsonCodexAccountMissingFreshRead(now: now)
        {
            return
        }
        page.lastRefreshRequest = now
        Self.lemelsonLog.notice("\(page.logName, privacy: .public): page shown, asking the store for a fresh reading")
        let provider = page.provider
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ProviderInteractionContext.$current.withValue(.background) {
                await self.store.refreshProvider(provider, coalesceIfRefreshing: true)
            }
        }
    }
}
