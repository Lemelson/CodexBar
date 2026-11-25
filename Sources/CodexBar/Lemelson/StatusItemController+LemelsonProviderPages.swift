import AppKit
import CodexBarCore
import LemelsonUsageKit
import SwiftUI

// The Antigravity and Codex tabs as one page of the fork each (`UsageProviderPage` with
// `UsageProviderSpec.antigravity` / `.codex`), in place of the stock card and the stock rows under it:
//   • Antigravity: Plan Usage, Cost (the stock Cost counts copied conversations twice);
//   • Codex: the usage card (session, weekly, the inline cost dashboard), Limit Reset Credits, Credits,
//     Extra usage (the same credits balance again, or the monthly cap that the credits line already names),
//     Plan Usage and Cost. The credits balance and the limit reset credits come back as facts inside the page's
//     card (`UsageCodexFacts`), "Buy Credits…" stays an action row, and the OpenAI web charts the page has no
//     counterpart for (Usage breakdown, Credits history) stay as rows with their detail panel.
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
        writer: .codex)
    static let all = [LemelsonProviderPageState.antigravity, .codex]

    static func state(for provider: UsageProvider) -> LemelsonProviderPageState? {
        self.all.first { $0.provider == provider }
    }

    /// The page shown now, if the current page key is one of these tabs.
    static func state(forPageKey key: String) -> LemelsonProviderPageState? {
        self.all.first { $0.provider.rawValue == key }
    }

    let spec: UsageProviderSpec
    let provider: UsageProvider
    let defaultsKey: String
    let writer: UsageQuotaLiveWriter

    private init(spec: UsageProviderSpec, provider: UsageProvider, defaultsKey: String, writer: UsageQuotaLiveWriter) {
        self.spec = spec
        self.provider = provider
        self.defaultsKey = defaultsKey
        self.writer = writer
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
    /// Whether the store was fetching the provider at the last look.
    var wasRefreshing = false
    /// When the page last asked the store for a fresh reading.
    var lastRefreshRequest: Date?
    /// Width of the last build of the page.
    var width: CGFloat = 0
    /// Rendered rows of the page while it is not in the menu, by row id.
    var warmRows: [String: NSView] = [:]
    var warmWidth: CGFloat = 0
    var isWarming = false
    var warmTimer: Timer?
}

extension StatusItemController {
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
    func addLemelsonProviderPage(to menu: NSMenu, context: MenuCardContext) -> Bool {
        guard let page = LemelsonProviderPageState.state(for: context.currentProvider),
              self.menuCardRenderingEnabledForController, !page.usesStockTab
        else { return false }
        // Several Codex accounts stacked on one tab: the page shows one account, the stock cards stay.
        if page.provider == .codex, context.codexAccountDisplay?.showAll == true {
            return false
        }
        let started = CACurrentMediaTime()
        let warm = self.lemelsonTakeWarmProviderRows(page, width: context.menuWidth)
        guard let built = self.addLemelsonProviderRows(page, to: menu, width: context.menuWidth) else { return false }
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
            if web.canShowBuyCredits {
                menu.addItem(self.lemelsonBuyCreditsItem())
                menu.addItem(.separator())
            }
        }
        // Its prompt cache row goes above the action rows, as on the Claude pages.
        session.pendingCacheRow = Self.lemelsonCacheRow(of: built)
        // Built for the tab cache's warm-up (another tab is shown): render the page's own rows now as well,
        // while warming is allowed; the tab cache is often emptied before the page is reached.
        if !page.isWarming, self.lemelsonCurrentPageKey() != page.provider.rawValue {
            self.lemelsonWarmProviderRows(page)
        }
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Self.lemelsonLog.notice("\(page.logName, privacy: .public) page built in \(ms) ms with \(warm) warm rows, \(built.rows.count) rows, open=\(self.openMenus[ObjectIdentifier(menu)] != nil)")
        }
        return true
    }

    /// "Buy Credits…" as the stock Codex card has it (the same action).
    private func lemelsonBuyCreditsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: L("Buy Credits..."),
            action: #selector(self.openCreditsPurchase),
            keyEquivalent: "")
        item.target = self
        if let image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil) {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        return item
    }

    /// The page's rows, without its cache row (see `lemelsonCacheRow(of:)`). Nil without a page.
    private func addLemelsonProviderRows(
        _ page: LemelsonProviderPageState,
        to menu: NSMenu,
        width: CGFloat) -> UsageProviderPage?
    {
        guard let state = UsagePanelStore.load() else { return nil }
        let refreshing = self.lemelsonProviderRefreshing(page)
        let now = Date()
        let codex = page.provider == .codex ? self.lemelsonCodexCard(now: now) : nil
        guard let built = UsageProviderPage(
            spec: page.spec,
            state: state,
            now: now,
            width: width,
            detailWidth: UsageHoverPanelController.panelWidth,
            refreshing: refreshing,
            account: codex?.account,
            extras: codex?.extras ?? [])
        else { return nil }
        page.renderedStateDate = UsagePanelStore.modificationDate()
        page.width = width

        for row in built.rows {
            // The footer's caption changes with the refreshing state.
            let fingerprint = row.part == .footer ? "\(row.heightFingerprint):\(refreshing)" : row.heightFingerprint
            if let detail = row.detail {
                // As the Claude limit rows: the detail panel shows the window's chart at once and morphs
                // between the two rows; the empty click handler keeps the row highlightable. A card row draws
                // its own chevron and highlight.
                self.lemelsonRegisterDetail(.swiftUI(key: row.id, width: built.detailWidth) {
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
        return built
    }

    /// The page's "Prompt cache" row in the shape the menu footer takes; nil without cache data.
    static func lemelsonCacheRow(of page: UsageProviderPage) -> LemelsonCacheRow? {
        guard let row = page.cacheRow, let detail = row.detail else { return nil }
        return LemelsonCacheRow(
            id: row.id,
            view: row.view,
            detail: detail,
            heightCacheScope: row.heightCacheScope,
            heightFingerprint: row.heightFingerprint)
    }

    // MARK: - Codex facts from CodexBar's own Codex card

    // Everything here is read from the stock Codex card's model, so the page follows the same visibility
    // settings ("show credits and extra usage"), the same redaction and the same selected account as the stock
    // tab, and never reads another provider's identity.

    /// The e-mail the stock Codex card shows in its header (already redacted when personal info is hidden),
    /// and the credits balance and the limit reset credits, each only when the stock Codex card shows it.
    private func lemelsonCodexCard(now: Date) -> (account: String?, extras: [UsageProviderPage.Extra])? {
        guard let model = self.menuCardModel(for: .codex), model.provider == .codex else { return nil }
        let email = model.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let resetCredits: [Date?]? = if model.limitResetCredits != nil,
                                        let credits = self.store.snapshot(for: .codex)?.codexResetCredits
        {
            credits.availableInventory(at: now).credits.map(\.expiresAt)
        } else {
            nil
        }
        let extras = UsageCodexFacts.extras(
            creditsLeft: model.creditsText == nil ? nil : model.creditsRemaining,
            creditsNote: model.creditsHintText,
            resetCredits: resetCredits,
            now: now,
            detailWidth: UsageHoverPanelController.panelWidth)
        return (email.isEmpty ? nil : email, extras)
    }

    // MARK: - Rows rendered ahead of time

    // A freshly created hosting view takes a tenth of a second or more to lay out and paint its first frame
    // (the spend chart has a layer per period). The menu's own tab cache would hide that, but every
    // collector pass and store change empties it, and its refill waits while pages turn: the page then
    // came in late on the first visit, after a few empty frames. So the page keeps rendered rows of its
    // own, as the Claude modes do: built shortly after the menu opens, handed to the menu's row recycling
    // when the page is built, and taken back when another tab replaces it.

    /// Inside a populate pass, before the page's rows are made: the rendered rows go to the recycle pool,
    /// where `makeMenuCardItem` picks them up by id. Returns how many.
    private func lemelsonTakeWarmProviderRows(_ page: LemelsonProviderPageState, width: CGFloat) -> Int {
        // Only for the page being shown: the tab cache's own warm-up builds the page too, and its rows are
        // dropped with that cache.
        guard !page.isWarming, self.lemelsonCurrentPageKey() == page.provider.rawValue else {
            return 0
        }
        if abs(page.warmWidth - width) > 0.5 {
            page.warmRows.removeAll()
        }
        let warm = page.warmRows
        page.warmRows.removeAll()
        for (id, view) in warm where self.menuCardViewRecyclePool[id] == nil {
            self.menuCardViewRecyclePool[id] = view
        }
        return warm.count
    }

    /// Inside a populate pass of another tab: the rows of a provider page that just left the menu are kept.
    func lemelsonKeepProviderRowsLeaving(except provider: UsageProvider?) {
        for page in LemelsonProviderPageState.all where page.provider != provider && !page.isWarming {
            let leaving = self.menuCardViewRecyclePool.filter { page.owns($0.key) }
            guard !leaving.isEmpty else { continue }
            for id in leaving.keys {
                self.menuCardViewRecyclePool.removeValue(forKey: id)
            }
            page.warmRows.merge(leaving) { _, new in new }
            page.warmWidth = page.width
        }
    }

    /// After a build of the open root menu: unless a page is shown or its rows are kept already, render
    /// them shortly, once pages have stopped turning. A common-modes timer: main-actor tasks do not run
    /// while the menu tracks the pointer.
    func lemelsonScheduleProviderWarmup() {
        guard !SettingsStore.isRunningTests else { return }
        let enabled = self.store.enabledFirstPartyProvidersForDisplay()
        for page in LemelsonProviderPageState.all {
            guard !page.usesStockTab, page.warmRows.isEmpty, page.width > 0, page.warmTimer == nil,
                  enabled.contains(page.provider)
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

    private func lemelsonWarmProviderRows(_ page: LemelsonProviderPageState) {
        guard page.warmRows.isEmpty, page.width > 0,
              self.lemelsonCurrentPageKey() != page.provider.rawValue
        else { return }
        let started = CACurrentMediaTime()
        let width = page.width
        let scratch = NSMenu()
        scratch.autoenablesItems = false
        page.isWarming = true
        defer { page.isWarming = false }
        guard let built = self.addLemelsonProviderRows(page, to: scratch, width: width) else { return }
        if let row = Self.lemelsonCacheRow(of: built) {
            self.addLemelsonCacheRow(row, to: scratch, width: width)
        }
        var rows: [String: NSView] = [:]
        for item in scratch.items {
            guard let id = item.representedObject as? String, page.owns(id), let view = item.view else { continue }
            // Laying out now makes the first attach draw in the same frame as the page turn.
            view.layoutSubtreeIfNeeded()
            item.view = nil
            rows[id] = view
        }
        scratch.removeAllItems()
        page.warmRows = rows
        page.warmWidth = width
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Self.lemelsonLog.notice("\(page.logName, privacy: .public) rows rendered ahead in \(ms) ms")
        }
    }

    // MARK: - Live readings

    /// Called once at start. Each provider's observation re-arms itself on every change of the store.
    func lemelsonObserveProviderPages() {
        guard !SettingsStore.isRunningTests else { return }
        for page in LemelsonProviderPageState.all {
            self.lemelsonObserve(page)
        }
    }

    private func lemelsonObserve(_ page: LemelsonProviderPageState) {
        withObservationTracking {
            _ = self.store.snapshot(for: page.provider.instanceID)?.updatedAt
            _ = self.store.refreshingProviders.contains(page.provider.instanceID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lemelsonObserve(page)
                self.lemelsonProviderStoreDidChange(page)
            }
        }
        self.lemelsonProviderStoreDidChange(page)
    }

    private func lemelsonProviderStoreDidChange(_ page: LemelsonProviderPageState) {
        let log = Self.lemelsonLog
        let name = page.logName
        let pageShown = !self.openMenus.isEmpty && self.lemelsonCurrentPageKey() == page.provider.rawValue

        let refreshing = self.store.refreshingProviders.contains(page.provider.instanceID)
        if refreshing != page.wasRefreshing {
            page.wasRefreshing = refreshing
            log.notice("\(name, privacy: .public) fetch \(refreshing ? "started" : "ended", privacy: .public)")
            // The footer shows the fetch while it runs.
            if pageShown, !page.usesStockTab {
                self.lemelsonRebuildOpenMenus()
            }
        }

        guard let snapshot = self.store.snapshot(for: page.provider.instanceID),
              snapshot.updatedAt != page.lastSnapshotAt
        else { return }
        page.lastSnapshotAt = snapshot.updatedAt
        let reading = page.provider == .codex
            ? Self.lemelsonCodexReading(snapshot)
            : Self.lemelsonAntigravityReading(snapshot)
        guard let reading else {
            log.notice("\(name, privacy: .public) live: no 5-hour or weekly window in the snapshot")
            return
        }
        let outcome = page.writer.record(reading)
        log.notice("\(name, privacy: .public) live: \(String(describing: outcome), privacy: .public) \(reading.jsonLine.dropLast(), privacy: .public)")
        // A new line only reaches the page through the collector; while the menu is open it runs now.
        guard outcome == .written, !self.openMenus.isEmpty else { return }
        self.lemelsonStartRefreshIfDue(force: true)
        if pageShown {
            self.lemelsonRebuildOpenMenus()
        }
    }

    /// The Gemini 5-hour and weekly quota of a snapshot. Other model groups ("Claude/GPT", versioned
    /// Gemini groups) are separate quotas and are not part of the page.
    static func lemelsonAntigravityReading(_ snapshot: UsageSnapshot) -> UsageQuotaLiveReading? {
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
            plan: snapshot.loginMethod(for: .antigravity))
        return reading.isEmpty ? nil : reading
    }

    /// Codex's session (5-hour) and weekly window. Codex reports them as the primary and the secondary
    /// window; the window length decides when it is known (a plan with only a weekly window reports that as
    /// the primary one). Model-specific extra windows are separate pools and not part of the page.
    static func lemelsonCodexReading(_ snapshot: UsageSnapshot) -> UsageQuotaLiveReading? {
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
        let reading = UsageQuotaLiveReading(at: snapshot.updatedAt, fiveHour: fiveHour, week: week, plan: plan)
        return reading.isEmpty ? nil : reading
    }

    // MARK: - Refresh while the page is shown

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
        if let updated = self.store.snapshot(for: page.provider.instanceID)?.updatedAt, now.timeIntervalSince(updated) < 120 {
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
