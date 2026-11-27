import AppKit
import CodexBarCore
import LemelsonUsageKit
import SwiftUI

// The Overview tab as one page of the fork (`UsageOverviewPage`), in place of the stock Overview rows: what
// every subscription on this Mac costs at API prices (all Claude accounts together, Codex, Antigravity), one
// row per subscription with its weekly limit and a hover panel, and the prompt cache of all of them together
// above the action rows. A click on a provider row opens that provider's tab, as the stock rows do.
//
// Entry points:
//   • `addLemelsonOverviewPage`: from `addPrimaryMenuContent` while the Overview tab is built;
//   • `lemelsonScheduleOverviewWarmup` / `lemelsonCancelOverviewWarmup`: the page's rows rendered ahead of a
//     visit, as the provider pages do;
//   • `lemelsonKeepOverviewRowsLeaving`: inside a populate pass of another tab, keeps the rows that just left.
//
// `defaults write com.steipete.codexbar lemelsonOverviewPage stock` brings the stock Overview back (next menu
// build, no restart).

@MainActor
final class LemelsonOverviewPageState {
    static let shared = LemelsonOverviewPageState()
    static let defaultsKey = "lemelsonOverviewPage"
    /// `lemelsonPageKey(selection: .overview, …)`.
    static let pageKey = "overview"

    /// Version of the summary the page was last built from.
    var renderedStateDate: Date?
    /// Width of the last build of the page.
    var width: CGFloat = 0
    /// Rendered rows of the page while it is not in the menu, by row id.
    var warmRows: [String: NSView] = [:]
    var warmWidth: CGFloat = 0
    var isWarming = false
    var warmTimer: Timer?

    private init() {}

    /// The stock tab: asked for, or under tests (they check the author's Overview rows).
    var usesStockTab: Bool {
        SettingsStore.isRunningTests || UserDefaults.standard.string(forKey: Self.defaultsKey) == "stock"
    }

    /// Rows of this page carry these ids (the prompt cache row included).
    func owns(_ id: String) -> Bool {
        id.hasPrefix(UsageOverviewPage.idPrefix)
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
        // Nothing another page left for the footer area belongs here.
        session.pendingLineRows = []
        session.pendingBuyCredits = false
        if menuWidth > 0 {
            session.menuWidth = menuWidth
        }
        let live = !page.isWarming && self.lemelsonCurrentPageKey() == LemelsonOverviewPageState.pageKey
        let warm = self.lemelsonTakeWarmOverviewRows(width: menuWidth)
        // The provider page that is left keeps its rendered rows for the next visit.
        self.lemelsonKeepProviderRowsLeaving(except: nil)
        let built = self.addLemelsonOverviewRows(state, to: menu, width: menuWidth, interactionMenu: captureMenu ?? menu)
        page.width = menuWidth
        session.pendingLineRows = Self.lemelsonOverviewLineRows(of: built)
        session.pendingBuyCredits = false
        // Built for the tab cache's warm-up: the page's own rows are rendered by the debounced warm-up.
        if !page.isWarming, !live {
            self.lemelsonScheduleOverviewWarmup()
        }
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Self.lemelsonLog.notice("overview page built in \(ms) ms with \(warm) warm rows, \(built.rows.count) rows, live=\(live), open=\(self.openMenus[ObjectIdentifier(menu)] != nil)")
        }
        return true
    }

    /// The page's rows, without its prompt cache row (see `lemelsonOverviewLineRows(of:)`).
    @discardableResult
    private func addLemelsonOverviewRows(
        _ state: UsagePanelState,
        to menu: NSMenu,
        width: CGFloat,
        interactionMenu: NSMenu) -> UsageOverviewPage
    {
        let page = LemelsonOverviewPageState.shared
        let refreshing = LemelsonPanelSession.shared.isRefreshing
        let built = UsageOverviewPage(
            state: state,
            now: Date(),
            width: width,
            detailWidth: UsageHoverPanelController.panelWidth,
            refreshing: refreshing)
        page.renderedStateDate = UsagePanelStore.modificationDate()
        // The spend chart's day panel, keyed by the spend row's id so warm-up and cached tab swaps keep it.
        if let chartDay = built.chartDayDetail {
            self.lemelsonRegisterChartDayDetail(
                forRowID: UsageOverviewSpend.defaultChartID,
                .swiftUI(key: chartDay.key, width: built.detailWidth) {
                    chartDay.build()
                })
        }
        let enabled = self.store.enabledFirstPartyProvidersForDisplay()
        for row in built.rows {
            // The footer's caption changes with the refreshing state.
            let fingerprint = row.part == .footer ? "\(row.heightFingerprint):\(refreshing)" : row.heightFingerprint
            if let detail = row.detail {
                // As the account rows of Claude Spend: the detail panel shows the provider's limits and models;
                // a click opens the provider's tab when it is enabled, otherwise the empty handler keeps the
                // row highlightable.
                self.lemelsonRegisterDetail(.swiftUI(key: row.id, width: built.detailWidth) {
                    detail()
                })
                var onClick: () -> Void = {}
                if let provider = row.providerKind.flatMap(Self.lemelsonOverviewProvider), enabled.contains(provider) {
                    onClick = { [weak self, weak interactionMenu] in
                        guard let self, let interactionMenu else { return }
                        self.selectOverviewProvider(provider.instanceID, menu: interactionMenu)
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

    /// Inside a populate pass, before the page's rows are made: the rendered rows go to the recycle pool,
    /// where `makeMenuCardItem` picks them up by id. Returns how many.
    private func lemelsonTakeWarmOverviewRows(width: CGFloat) -> Int {
        let page = LemelsonOverviewPageState.shared
        guard !page.isWarming, self.lemelsonCurrentPageKey() == LemelsonOverviewPageState.pageKey else {
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

    /// Inside a populate pass: unless Overview is the page being built, its rows that just left the menu are
    /// kept for the next visit (out of the recycle pool, where another page would take them over).
    func lemelsonKeepOverviewRowsLeaving(isOverview: Bool) {
        let page = LemelsonOverviewPageState.shared
        guard !isOverview, !page.isWarming else { return }
        let leaving = self.menuCardViewRecyclePool.filter { page.owns($0.key) }
        guard !leaving.isEmpty else { return }
        for id in leaving.keys {
            self.menuCardViewRecyclePool.removeValue(forKey: id)
        }
        page.warmRows.merge(leaving) { _, new in new }
        page.warmWidth = page.width
    }

    /// After a build of the open root menu: unless Overview is shown or its rows are kept already, render them
    /// shortly, once pages have stopped turning. A common-modes timer: main-actor tasks do not run while the
    /// menu tracks the pointer.
    func lemelsonScheduleOverviewWarmup() {
        guard !SettingsStore.isRunningTests else { return }
        let page = LemelsonOverviewPageState.shared
        guard self.lemelsonUsesCustomOverviewPage(), page.warmRows.isEmpty, page.warmTimer == nil,
              self.lemelsonOverviewWarmWidth() > 0,
              self.includesOverviewTab(enabledProviders: self.store.enabledFirstPartyProvidersForDisplay()),
              self.lemelsonCurrentPageKey() != LemelsonOverviewPageState.pageKey
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
        guard page.warmRows.isEmpty, width > 0,
              self.lemelsonCurrentPageKey() != LemelsonOverviewPageState.pageKey,
              let state = UsagePanelStore.load()
        else { return }
        let started = CACurrentMediaTime()
        let scratch = NSMenu()
        scratch.autoenablesItems = false
        page.isWarming = true
        defer { page.isWarming = false }
        let built = self.addLemelsonOverviewRows(state, to: scratch, width: width, interactionMenu: scratch)
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
        page.warmRows = rows
        page.warmWidth = width
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Self.lemelsonLog.notice("overview rows rendered ahead in \(ms) ms")
        }
    }
}
