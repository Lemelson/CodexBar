import AppKit
import CodexBarCore
import LemelsonUsageKit
import SwiftUI

// The Antigravity tab as one page of the fork (`UsageAntigravityPage`), in place of the stock card and the
// stock rows under it (Plan Usage, Cost: the stock Cost counts copied conversations twice).
//
// Entry points:
//   • `addLemelsonAntigravityPage`: from `addLemelsonUsagePanel` while the Antigravity tab is built;
//   • `lemelsonObserveAntigravity`: once at start (`wireBindings`): every fresh Antigravity snapshot of the
//     store goes into the live readings file (`UsageAntigravityLiveWriter`), and while a menu is open the
//     collector then runs and the page is rebuilt with the new numbers;
//   • `lemelsonAntigravityPageMayBeShown`: on menu open and after each build of the open menu: asks the
//     store for a fresh Antigravity reading when the page is shown (the fetch takes about half a minute,
//     the footer says "refreshing" meanwhile).
//
// `defaults write com.steipete.codexbar lemelsonAntigravityPage stock` brings the stock tab back (next menu
// build, no restart).

@MainActor
final class LemelsonAntigravityState {
    static let shared = LemelsonAntigravityState()
    static let defaultsKey = "lemelsonAntigravityPage"

    /// The stock tab: asked for, or under tests (they check the author's Antigravity card, and must never
    /// write test readings into the real live file).
    static var usesStockTab: Bool {
        SettingsStore.isRunningTests || UserDefaults.standard.string(forKey: self.defaultsKey) == "stock"
    }

    /// Version of the summary the page was last built from.
    var renderedStateDate: Date?
    /// `updatedAt` of the last store snapshot handed to the live writer.
    var lastSnapshotAt: Date?
    /// Whether the store was fetching Antigravity at the last look.
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
    /// Rows of the Antigravity page carry these ids (the warm rows of the Claude modes leave them alone).
    static func lemelsonIsAntigravityRow(_ id: String) -> Bool {
        id.hasPrefix(UsageAntigravityPage.idPrefix) || id.hasPrefix(UsageAntigravityPage.limitRowPrefix)
    }

    /// The store is fetching Antigravity now, or the collector is rewriting the summary.
    var lemelsonAntigravityRefreshing: Bool {
        LemelsonPanelSession.shared.isRefreshing || self.store.refreshingProviders.contains(.antigravity)
    }

    // MARK: - The page

    /// Draws the Antigravity tab. Returns false (the stock card stays) without the summary's Antigravity
    /// block or with `lemelsonAntigravityPage stock`.
    func addLemelsonAntigravityPage(to menu: NSMenu, context: MenuCardContext) -> Bool {
        guard self.menuCardRenderingEnabledForController, !LemelsonAntigravityState.usesStockTab else {
            return false
        }
        let started = CACurrentMediaTime()
        let warm = self.lemelsonTakeWarmAntigravityRows(width: context.menuWidth)
        guard let page = self.addLemelsonAntigravityRows(to: menu, width: context.menuWidth) else { return false }
        // The page replaces the stock Cost, Usage history and Plan Usage rows.
        LemelsonPanelSession.shared.stockExtrasVisible = false
        // Its prompt cache row goes above the action rows, as on the Claude pages.
        LemelsonPanelSession.shared.pendingCacheRow = Self.lemelsonCacheRow(of: page)
        // Built for the tab cache's warm-up (another tab is shown): render the page's own rows now as well,
        // while warming is allowed; the tab cache is often emptied before the page is reached.
        if !LemelsonAntigravityState.shared.isWarming,
           self.lemelsonCurrentPageKey() != UsageProvider.antigravity.rawValue
        {
            self.lemelsonWarmAntigravityRows()
        }
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Self.lemelsonLog.notice("antigravity page built in \(ms) ms with \(warm) warm rows, open=\(self.openMenus[ObjectIdentifier(menu)] != nil)")
        }
        return true
    }

    /// The page's rows, without its cache row (see `lemelsonCacheRow(of:)`). Nil without a page.
    private func addLemelsonAntigravityRows(to menu: NSMenu, width: CGFloat) -> UsageAntigravityPage? {
        guard let state = UsagePanelStore.load() else { return nil }
        let refreshing = self.lemelsonAntigravityRefreshing
        guard let page = UsageAntigravityPage(
            state: state,
            now: Date(),
            width: width,
            detailWidth: UsageHoverPanelController.panelWidth,
            refreshing: refreshing)
        else { return nil }
        let shared = LemelsonAntigravityState.shared
        shared.renderedStateDate = UsagePanelStore.modificationDate()
        shared.width = width

        for row in page.rows {
            // The footer's caption changes with the refreshing state.
            let fingerprint = row.part == .footer ? "\(row.heightFingerprint):\(refreshing)" : row.heightFingerprint
            if let detail = row.detail {
                // As the Claude limit rows: the detail panel shows the window's chart at once and morphs
                // between the two rows; the empty click handler keeps the row highlightable.
                self.lemelsonRegisterDetail(.swiftUI(key: row.id, width: page.detailWidth) {
                    detail()
                })
                menu.addItem(self.makeMenuCardItem(
                    LemelsonHighlightBridge(content: row.view, showsChevron: true),
                    id: row.id,
                    width: width,
                    heightCacheScope: row.heightCacheScope,
                    heightCacheFingerprint: fingerprint,
                    onClick: {}))
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
        return page
    }

    /// The page's "Prompt cache" row in the shape the menu footer takes; nil without cache data.
    static func lemelsonCacheRow(of page: UsageAntigravityPage) -> LemelsonCacheRow? {
        guard let row = page.cacheRow, let detail = row.detail else { return nil }
        return LemelsonCacheRow(
            id: row.id,
            view: row.view,
            detail: detail,
            heightCacheScope: row.heightCacheScope,
            heightFingerprint: row.heightFingerprint)
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
    private func lemelsonTakeWarmAntigravityRows(width: CGFloat) -> Int {
        let shared = LemelsonAntigravityState.shared
        // Only for the page being shown: the tab cache's own warm-up builds the page too, and its rows are
        // dropped with that cache.
        guard !shared.isWarming, self.lemelsonCurrentPageKey() == UsageProvider.antigravity.rawValue else {
            return 0
        }
        if abs(shared.warmWidth - width) > 0.5 {
            shared.warmRows.removeAll()
        }
        let warm = shared.warmRows
        shared.warmRows.removeAll()
        for (id, view) in warm where self.menuCardViewRecyclePool[id] == nil {
            self.menuCardViewRecyclePool[id] = view
        }
        return warm.count
    }

    /// Inside a populate pass of another tab: the page's rows that just left the menu are kept.
    func lemelsonKeepAntigravityRowsLeaving() {
        let shared = LemelsonAntigravityState.shared
        guard !shared.isWarming else { return }
        let leaving = self.menuCardViewRecyclePool.filter { Self.lemelsonIsAntigravityRow($0.key) }
        guard !leaving.isEmpty else { return }
        for id in leaving.keys {
            self.menuCardViewRecyclePool.removeValue(forKey: id)
        }
        shared.warmRows.merge(leaving) { _, new in new }
        shared.warmWidth = shared.width
    }

    /// After a build of the open root menu: unless the page is shown or its rows are kept already, render
    /// them shortly, once pages have stopped turning. A common-modes timer: main-actor tasks do not run
    /// while the menu tracks the pointer.
    func lemelsonScheduleAntigravityWarmup() {
        let shared = LemelsonAntigravityState.shared
        guard !SettingsStore.isRunningTests, !LemelsonAntigravityState.usesStockTab,
              shared.warmRows.isEmpty, shared.width > 0, shared.warmTimer == nil,
              self.store.enabledFirstPartyProvidersForDisplay().contains(.antigravity)
        else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                LemelsonAntigravityState.shared.warmTimer = nil
                guard let self, !self.openMenus.isEmpty else { return }
                guard !self.lemelsonPostponesWarmup() else {
                    self.lemelsonScheduleAntigravityWarmup()
                    return
                }
                self.lemelsonWarmAntigravityRows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shared.warmTimer = timer
    }

    private func lemelsonWarmAntigravityRows() {
        let shared = LemelsonAntigravityState.shared
        guard shared.warmRows.isEmpty, shared.width > 0,
              self.lemelsonCurrentPageKey() != UsageProvider.antigravity.rawValue
        else { return }
        let started = CACurrentMediaTime()
        let width = shared.width
        let scratch = NSMenu()
        scratch.autoenablesItems = false
        shared.isWarming = true
        defer { shared.isWarming = false }
        guard let page = self.addLemelsonAntigravityRows(to: scratch, width: width) else { return }
        if let row = Self.lemelsonCacheRow(of: page) {
            self.addLemelsonCacheRow(row, to: scratch, width: width)
        }
        var rows: [String: NSView] = [:]
        for item in scratch.items {
            guard let id = item.representedObject as? String, Self.lemelsonIsAntigravityRow(id),
                  let view = item.view
            else { continue }
            // Laying out now makes the first attach draw in the same frame as the page turn.
            view.layoutSubtreeIfNeeded()
            item.view = nil
            rows[id] = view
        }
        scratch.removeAllItems()
        shared.warmRows = rows
        shared.warmWidth = width
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            Self.lemelsonLog.notice("antigravity rows rendered ahead in \(ms) ms")
        }
    }

    // MARK: - Live readings

    /// Called once at start. Re-arms itself on every change of the store.
    func lemelsonObserveAntigravity() {
        guard !SettingsStore.isRunningTests else { return }
        withObservationTracking {
            _ = self.store.snapshot(for: .antigravity)?.updatedAt
            _ = self.store.refreshingProviders.contains(.antigravity)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lemelsonObserveAntigravity()
                self.lemelsonAntigravityStoreDidChange()
            }
        }
        self.lemelsonAntigravityStoreDidChange()
    }

    private func lemelsonAntigravityStoreDidChange() {
        let state = LemelsonAntigravityState.shared
        let log = Self.lemelsonLog
        let pageShown = !self.openMenus.isEmpty
            && self.lemelsonCurrentPageKey() == UsageProvider.antigravity.rawValue

        let refreshing = self.store.refreshingProviders.contains(.antigravity)
        if refreshing != state.wasRefreshing {
            state.wasRefreshing = refreshing
            log.notice("antigravity fetch \(refreshing ? "started" : "ended", privacy: .public)")
            // The footer shows the fetch while it runs.
            if pageShown {
                self.lemelsonRebuildOpenMenus()
            }
        }

        guard let snapshot = self.store.snapshot(for: .antigravity),
              snapshot.updatedAt != state.lastSnapshotAt
        else { return }
        state.lastSnapshotAt = snapshot.updatedAt
        guard let reading = Self.lemelsonAntigravityReading(snapshot) else {
            log.notice("antigravity live: no Gemini 5-hour or weekly window in the snapshot")
            return
        }
        let outcome = UsageAntigravityLiveWriter.shared.record(reading)
        log.notice("antigravity live: \(String(describing: outcome), privacy: .public) \(reading.jsonLine.dropLast(), privacy: .public)")
        // A new line only reaches the page through the collector; while the menu is open it runs now.
        guard outcome == .written, !self.openMenus.isEmpty else { return }
        self.lemelsonStartRefreshIfDue(force: true)
        if pageShown {
            self.lemelsonRebuildOpenMenus()
        }
    }

    /// The Gemini 5-hour and weekly quota of a snapshot. Other model groups ("Claude/GPT", versioned
    /// Gemini groups) are separate quotas and are not part of the page.
    static func lemelsonAntigravityReading(_ snapshot: UsageSnapshot) -> UsageAntigravityLiveReading? {
        let windows = (snapshot.extraRateWindows ?? []).filter {
            $0.usageKnown && AntigravityStatusSnapshot.isQuotaSummaryWindowID($0.id)
        }
        func window(_ title: String) -> UsageAntigravityLiveReading.Window? {
            windows.first { $0.title == title }.map {
                UsageAntigravityLiveReading.Window(pct: $0.window.usedPercent, resetsAt: $0.window.resetsAt)
            }
        }
        // The plan or tier name the fetch gave (Google's paid tier, plan type or current tier), as is.
        let reading = UsageAntigravityLiveReading(
            at: snapshot.updatedAt,
            fiveHour: window("Gemini 5-hour"),
            week: window("Gemini weekly"),
            plan: snapshot.loginMethod(for: .antigravity))
        return reading.isEmpty ? nil : reading
    }

    // MARK: - Refresh while the page is shown

    /// The page is (or may now be) on screen: unless the store fetched Antigravity in the last two minutes
    /// or is fetching it now, ask for a fresh reading.
    func lemelsonAntigravityPageMayBeShown(in menu: NSMenu) {
        guard menu.supermenu == nil, self.openMenus[ObjectIdentifier(menu)] != nil,
              self.menuCardRenderingEnabledForController,
              !LemelsonAntigravityState.usesStockTab,
              self.lemelsonCurrentPageKey() == UsageProvider.antigravity.rawValue,
              !self.store.refreshingProviders.contains(.antigravity)
        else { return }
        let state = LemelsonAntigravityState.shared
        let now = Date()
        if let last = state.lastRefreshRequest, now.timeIntervalSince(last) < 120 { return }
        if let updated = self.store.snapshot(for: .antigravity)?.updatedAt, now.timeIntervalSince(updated) < 120 {
            return
        }
        state.lastRefreshRequest = now
        Self.lemelsonLog.notice("antigravity: page shown, asking the store for a fresh reading")
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ProviderInteractionContext.$current.withValue(.background) {
                await self.store.refreshProvider(.antigravity, coalesceIfRefreshing: true)
            }
        }
    }
}
