import AppKit
import CodexBarCore
import LemelsonUsageKit
import SwiftUI

// The Overview tab as one page of the fork (`UsageOverviewPage`), in place of the stock Overview rows: what
// every subscription on this Mac costs at API prices (all Claude accounts together, Codex, Antigravity), one
// row per subscription with its weekly limit and a hover panel, and the prompt cache of all of them together
// above the action rows. A click on a provider row opens that provider's tab, as the stock rows do.
//
// The page has two modes with a mode row of its own, as the Claude and the Codex tab (`LemelsonModeTab.overview`,
// `LemelsonModeStore.overview`): Limits (the cumulative you-against-others chart and every account's weekly
// limit) and Spend (the page above). Both are pages of the line the arrow keys and swipes turn
// ("overview:limits", "overview:spend"), and each keeps its own rendered rows.
//
// Entry points:
//   • `addLemelsonOverviewPage`: from `addPrimaryMenuContent` while the Overview tab is built;
//   • `lemelsonScheduleOverviewWarmup` / `lemelsonCancelOverviewWarmup`: the page's rows rendered ahead of a
//     visit, as the provider pages do;
//   • `lemelsonKeepOverviewRowsLeaving`: inside a populate pass of another tab, keeps the rows that just left.
//
// `defaults write com.steipete.codexbar lemelsonOverviewPage stock` brings the stock Overview back (next menu
// build, no restart). `defaults write com.steipete.codexbar lemelsonOverviewLimits off` keeps the fork's
// Overview as the one Spend page it was, without a mode row.

@MainActor
final class LemelsonOverviewPageState {
    static let shared = LemelsonOverviewPageState()
    static let defaultsKey = "lemelsonOverviewPage"
    /// `lemelsonPageKey(selection: .overview, …)` of the page without modes; with them the key is
    /// "overview:limits" or "overview:spend".
    static let pageKey = "overview"

    /// Whether a page key names Overview (in any mode).
    static func isShown(onPage key: String) -> Bool {
        key == self.pageKey || key.hasPrefix(self.pageKey + ":")
    }

    /// Version of the summary the page was last built from.
    var renderedStateDate: Date?
    /// Width of the last build of the page.
    var width: CGFloat = 0
    /// Rendered rows of each mode while it is not in the menu, by row id. Without modes: under `.spend`.
    var warmRows: [LemelsonPanelMode: [String: NSView]] = [:]
    var warmWidth: CGFloat = 0
    /// The mode whose rows are in the menu now (or were, when another tab replaced the page).
    var renderedMode: LemelsonPanelMode?
    var isWarming = false
    var warmTimer: Timer?

    private init() {}

    /// The stock tab: asked for, or under tests (they check the author's Overview rows).
    var usesStockTab: Bool {
        SettingsStore.isRunningTests || UserDefaults.standard.string(forKey: Self.defaultsKey) == "stock"
    }

    /// Limits and Spend with a mode row; false with the stock tab or after `lemelsonOverviewLimits off`.
    var usesModes: Bool {
        !self.usesStockTab && UsageOverviewMode.isEnabled()
    }

    /// The mode shown; the page without modes is Spend.
    var mode: LemelsonPanelMode {
        self.usesModes ? LemelsonModeStore.overview.mode : .spend
    }

    /// The modes whose rows can be rendered ahead.
    var warmableModes: [LemelsonPanelMode] {
        self.usesModes ? LemelsonModeTab.overview.modes : [.spend]
    }

    /// Rows of this page carry these ids (the prompt cache row included).
    func owns(_ id: String) -> Bool {
        id.hasPrefix(UsageOverviewPage.idPrefix)
    }

    /// After `lemelsonOverviewLimits` or `lemelsonOverviewPage` was toggled: the rendered rows of a mode the
    /// page no longer has (Limits, with the Spend-only page) are let go, and that mode is not "shown last".
    func dropRowsOfRetiredModes() {
        let modes = self.warmableModes
        self.warmRows = self.warmRows.filter { modes.contains($0.key) }
        if let rendered = self.renderedMode, !modes.contains(rendered) {
            self.renderedMode = nil
        }
    }
}

extension StatusItemController {
    /// A row of the Overview page.
    static func lemelsonIsOverviewPageRow(_ id: String) -> Bool {
        LemelsonOverviewPageState.shared.owns(id)
    }

    /// Whether the Overview tab is the fork's page: card rendering on, not asked for the stock tab, and the
    /// collector's summary on disk.
    func lemelsonUsesCustomOverviewPage() -> Bool {
        self.menuCardRenderingEnabledForController
            && !LemelsonOverviewPageState.shared.usesStockTab
            && FileManager.default.fileExists(atPath: UsagePanelStore.defaultURL.path)
    }

    // MARK: - The page

    /// Draws the Overview tab. Returns false (the stock Overview stays) with `lemelsonOverviewPage stock` or
    /// without a readable summary. Adds its own footer; its prompt cache row goes above the action rows
    /// (`addLemelsonPendingRows`).
    func addLemelsonOverviewPage(to menu: NSMenu, menuWidth: CGFloat, captureMenu: NSMenu?) -> Bool {
        guard self.lemelsonUsesCustomOverviewPage(), let state = UsagePanelStore.load() else { return false }
        let started = CACurrentMediaTime()
        let page = LemelsonOverviewPageState.shared
        let session = LemelsonPanelSession.shared
        page.dropRowsOfRetiredModes()
        // Nothing another page left for the footer area belongs here.
        session.pendingLineRows = []
        session.pendingBuyCredits = false
        if menuWidth > 0 {
            session.menuWidth = menuWidth
        }
        let live = !page.isWarming && LemelsonOverviewPageState.isShown(onPage: self.lemelsonCurrentPageKey())
        let mode = page.mode
        let warm = self.lemelsonTakeWarmOverviewRows(width: menuWidth)
        // The provider page that is left keeps its rendered rows for the next visit.
        self.lemelsonKeepProviderRowsLeaving(except: nil)
        if page.usesModes {
            // The page's own mode row and pin, as on the Claude and the Codex tab.
            let tab: LemelsonModeTab = .overview
            let modes = LemelsonModeStore.overview
            let capture = captureMenu ?? menu
            let switcher = NSMenuItem()
            switcher.view = LemelsonModeSwitcherView(
                tab: tab,
                selected: modes.mode,
                pinnedMode: modes.pinnedMode,
                width: menuWidth,
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
        let built = self.addLemelsonOverviewRows(
            state, mode: mode, to: menu, width: menuWidth, interactionMenu: captureMenu ?? menu)
        page.width = menuWidth
        if live {
            page.renderedMode = mode
        }
        session.pendingLineRows = Self.lemelsonOverviewLineRows(of: built)
        session.pendingBuyCredits = false
        // The other mode (or, built for the tab cache's warm-up while another tab is shown, both) is rendered
        // by the debounced warm-up, not a second time inside this pass.
        if !page.isWarming {
            self.lemelsonScheduleOverviewWarmup()
        }
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Self.lemelsonLog.notice("overview page (\(mode.rawValue, privacy: .public)) built in \(ms) ms with \(warm) warm rows, \(built.rows.count) rows, live=\(live), open=\(self.openMenus[ObjectIdentifier(menu)] != nil)")
        }
        return true
    }

    /// The page's rows in one mode, without its prompt cache row (see `lemelsonOverviewLineRows(of:)`).
    @discardableResult
    private func addLemelsonOverviewRows(
        _ state: UsagePanelState,
        mode: LemelsonPanelMode,
        to menu: NSMenu,
        width: CGFloat,
        interactionMenu: NSMenu) -> UsageOverviewPage
    {
        let page = LemelsonOverviewPageState.shared
        let refreshing = LemelsonPanelSession.shared.isRefreshing
        // Codex as its own tab shows it: the system account CodexBar sees marked active, CodexBar's newer
        // readings in place of the summary's, and the private names while personal info is hidden. Limits
        // then never shows another percent or another name than the Codex tab.
        let codex = LemelsonProviderPageState.codex
        let built = UsageOverviewPage(
            state: self.lemelsonCodexStateWithSystemAccount(state),
            now: Date(),
            width: width,
            detailWidth: UsageHoverPanelController.panelWidth,
            refreshing: refreshing,
            // Without modes: the Spend-only page with its ids from before the modes.
            mode: page.usesModes ? mode.overviewMode : nil,
            codexLive: codex.liveByAccount,
            codexPrivateNames: self.settings.hidePersonalInfo ? self.lemelsonCodexPrivateNames() : nil)
        // A warm-up renders rows ahead; only a build for the menu says which summary the page shows.
        if !page.isWarming {
            page.renderedStateDate = UsagePanelStore.modificationDate()
        }
        // The chart's panel (Spend: the pointed-at day; Limits: every account at the pointed-at time), keyed
        // by the chart row's id so warm-up and cached tab swaps keep it.
        if let chartDay = built.chartDayDetail {
            self.lemelsonRegisterChartDayDetail(
                forRowID: built.chartRowID,
                .swiftUI(key: chartDay.key, width: built.detailWidth) {
                    chartDay.build()
                })
        }
        let enabled = self.store.enabledFirstPartyProvidersForDisplay()
        for row in built.rows {
            // The footer's caption changes with the refreshing state.
            let fingerprint = row.part == .footer ? "\(row.heightFingerprint):\(refreshing)" : row.heightFingerprint
            if let detail = row.detail {
                // As the account rows of Claude Spend: the detail panel shows the provider's limits and models
                // (Limits: the account's weekly limit); a click opens the provider's tab when it is enabled,
                // otherwise the empty handler keeps the row highlightable.
                self.lemelsonRegisterDetail(.swiftUI(key: row.id, width: built.detailWidth) {
                    detail()
                })
                var onClick: () -> Void = {}
                if let provider = row.providerKind.flatMap(Self.lemelsonOverviewProvider), enabled.contains(provider) {
                    let part = row.part
                    onClick = { [weak self, weak interactionMenu] in
                        guard let self, let interactionMenu else { return }
                        self.lemelsonOpenProviderTab(provider, fromOverview: part, menu: interactionMenu)
                    }
                }
                menu.addItem(self.makeMenuCardItem(
                    LemelsonHighlightBridge(content: row.view, showsChevron: true),
                    id: row.id,
                    width: width,
                    heightCacheScope: row.heightCacheScope,
                    heightCacheFingerprint: fingerprint,
                    onClick: onClick))
            } else {
                menu.addItem(self.makeMenuCardItem(
                    row.view,
                    id: row.id,
                    width: width,
                    heightCacheScope: row.heightCacheScope,
                    heightCacheFingerprint: fingerprint,
                    // The period and split switches take clicks; without this the row ignores them.
                    containsInteractiveControls: row.hasControls))
            }
            if row.separatorAfter {
                menu.addItem(.separator())
            }
        }
        return built
    }

    /// The mode a provider's tab opens in after a click on an Overview row: an account's weekly limit leads to
    /// that provider's Limits (where the limit is), whatever mode its tab was left in. A provider row of
    /// Spend keeps the tab's own mode (nil).
    static func lemelsonOverviewClickMode(for part: UsageOverviewPage.Part) -> LemelsonPanelMode? {
        if case .account = part {
            return .limits
        }
        return nil
    }

    /// A click on an Overview row with a provider: opens that provider's tab. From an account row of Limits,
    /// a tab with modes (Claude, Codex) is put on Limits first and its cached rows, rendered in the mode it
    /// was left in, are dropped. The hover panel and any chart interaction end before the tab changes, as
    /// with a click on the provider switcher.
    func lemelsonOpenProviderTab(
        _ provider: UsageProvider,
        fromOverview part: UsageOverviewPage.Part,
        menu: NSMenu)
    {
        if let mode = Self.lemelsonOverviewClickMode(for: part),
           let tab = Self.lemelsonModeTab(of: .provider(provider.instanceID)),
           tab.modes.contains(mode)
        {
            LemelsonModeStore.store(for: tab).mode = mode
            self.lemelsonDropCachedContent(of: provider)
        }
        self.lemelsonWillSelectProviderTab()
        self.selectOverviewProvider(provider.instanceID, menu: menu)
    }

    /// CodexBar's read of a Codex account changed (new numbers, another system account): Overview's Limits
    /// lists the same accounts, so its cached rows go and, when it is the page shown, the menu is rebuilt.
    func lemelsonCodexLiveDidChangeForOverview() {
        guard self.lemelsonUsesCustomOverviewPage() else { return }
        self.lemelsonDropCachedOverviewContent()
        let page = LemelsonOverviewPageState.shared
        guard !self.openMenus.isEmpty, page.mode == .limits,
              LemelsonOverviewPageState.isShown(onPage: self.lemelsonCurrentPageKey())
        else { return }
        self.lemelsonRebuildOpenMenus()
    }

    /// The CodexBar provider of an Overview row.
    private static func lemelsonOverviewProvider(_ kind: UsageOverviewProviderKind) -> UsageProvider? {
        switch kind {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: .antigravity
        }
    }

    /// The page's "Prompt cache" row in the shape the menu footer takes.
    static func lemelsonOverviewLineRows(of page: UsageOverviewPage) -> [LemelsonLineRow] {
        page.lineRows.compactMap { row in
            guard let detail = row.detail else { return nil }
            return LemelsonLineRow(
                id: row.id,
                view: row.view,
                detail: detail,
                heightCacheScope: row.heightCacheScope,
                heightFingerprint: row.heightFingerprint)
        }
    }

    // MARK: - Rows rendered ahead of time

    // As the provider pages (`+LemelsonProviderPages.swift`): a fresh hosting view paints its first frame a
    // tenth of a second late (the spend chart has two layers per period), so the page keeps rendered rows of
    // its own, built shortly after the menu opens and handed to the menu's row recycling when it is shown.

    /// Inside a populate pass, before the page's rows are made: the rows of the mode last shown that the
    /// outgoing menu left in the recycle pool are kept for that mode, and the rendered rows of the mode shown
    /// now go to the pool, where `makeMenuCardItem` picks them up by id. Returns how many.
    private func lemelsonTakeWarmOverviewRows(width: CGFloat) -> Int {
        let page = LemelsonOverviewPageState.shared
        guard !page.isWarming, LemelsonOverviewPageState.isShown(onPage: self.lemelsonCurrentPageKey()) else {
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

    /// Inside a populate pass: unless Overview is the page being built, its rows that just left the menu are
    /// kept for the mode they were built in (out of the recycle pool, where another page would take them over).
    func lemelsonKeepOverviewRowsLeaving(isOverview: Bool) {
        let page = LemelsonOverviewPageState.shared
        guard !isOverview, !page.isWarming else { return }
        let leaving = self.menuCardViewRecyclePool.filter { page.owns($0.key) }
        guard !leaving.isEmpty else { return }
        for id in leaving.keys {
            self.menuCardViewRecyclePool.removeValue(forKey: id)
        }
        page.warmRows[page.renderedMode ?? page.mode, default: [:]].merge(leaving) { _, new in new }
        page.warmWidth = page.width
    }

    /// The modes with no rendered rows kept, but the one the menu shows (its rows are in the menu).
    private func lemelsonMissingWarmOverviewModes() -> [LemelsonPanelMode] {
        let page = LemelsonOverviewPageState.shared
        let shown = LemelsonOverviewPageState.isShown(onPage: self.lemelsonCurrentPageKey()) ? page.mode : nil
        return page.warmableModes.filter { $0 != shown && page.warmRows[$0] == nil }
    }

    /// After a build of the open root menu: render the modes that have no rows kept, shortly, once pages have
    /// stopped turning. A common-modes timer: main-actor tasks do not run while the menu tracks the pointer.
    func lemelsonScheduleOverviewWarmup() {
        guard !SettingsStore.isRunningTests else { return }
        let page = LemelsonOverviewPageState.shared
        guard self.lemelsonUsesCustomOverviewPage(), page.warmTimer == nil,
              self.lemelsonOverviewWarmWidth() > 0,
              self.includesOverviewTab(enabledProviders: self.store.enabledFirstPartyProvidersForDisplay()),
              !self.lemelsonMissingWarmOverviewModes().isEmpty
        else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                LemelsonOverviewPageState.shared.warmTimer = nil
                guard let self, !self.openMenus.isEmpty else { return }
                guard !self.lemelsonPostponesWarmup() else {
                    self.lemelsonScheduleOverviewWarmup()
                    return
                }
                self.lemelsonWarmOverviewRows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        page.warmTimer = timer
    }

    func lemelsonCancelOverviewWarmup() {
        let page = LemelsonOverviewPageState.shared
        page.warmTimer?.invalidate()
        page.warmTimer = nil
    }

    /// A page never shown yet is rendered at the width of the menu's last build.
    private func lemelsonOverviewWarmWidth() -> CGFloat {
        let page = LemelsonOverviewPageState.shared
        return page.width > 0 ? page.width : LemelsonPanelSession.shared.menuWidth
    }

    private func lemelsonWarmOverviewRows() {
        let page = LemelsonOverviewPageState.shared
        let width = self.lemelsonOverviewWarmWidth()
        guard width > 0, self.lemelsonUsesCustomOverviewPage(), let state = UsagePanelStore.load() else { return }
        if abs(page.warmWidth - width) > 0.5 {
            page.warmRows.removeAll()
        }
        page.dropRowsOfRetiredModes()
        let missing = self.lemelsonMissingWarmOverviewModes()
        guard !missing.isEmpty else { return }
        let started = CACurrentMediaTime()
        page.isWarming = true
        defer { page.isWarming = false }
        for mode in missing {
            let scratch = NSMenu()
            scratch.autoenablesItems = false
            let built = self.addLemelsonOverviewRows(
                state, mode: mode, to: scratch, width: width, interactionMenu: scratch)
            self.addLemelsonLineRows(Self.lemelsonOverviewLineRows(of: built), to: scratch, width: width)
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
            Self.lemelsonLog.notice("overview rows rendered ahead (\(modes, privacy: .public)) in \(ms) ms")
        }
    }
}
