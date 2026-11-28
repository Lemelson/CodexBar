import AppKit
import CodexBarCore
import LemelsonUsageKit
import SwiftUI

// Detail views of menu rows in one panel joined to the menu (`UsageHoverPanelController`), instead of
// native submenus: it appears at once, slides from row to row and cross-fades its content.
//
// The rows that have a detail view:
//   • the fork's own rows (Claude limits, Spend accounts) register a builder by row id when they are built;
//   • the author's rows with a hosted chart submenu are adopted (`+LemelsonDetailAdoption.swift`).
// After every build of the open root menu, the rows actually in it are published to the panel.
//
// `defaults write com.steipete.codexbar lemelsonDetailPanel native` brings the native submenus back
// (next menu build, no restart); anything else or unset means the panel. The limit rows keep the panel
// in both cases: they never had a submenu.

enum LemelsonDetailPanel {
    static let defaultsKey = "lemelsonDetailPanel"

    static var usesNativeSubmenus: Bool {
        UserDefaults.standard.string(forKey: self.defaultsKey) == "native"
    }
}

@MainActor
final class LemelsonDetailPanelState {
    static let shared = LemelsonDetailPanelState()

    /// Detail views of the fork's own rows, by row id. Filled whenever those rows are built (a later
    /// build of the same id replaces the builder).
    var ownEntries: [String: UsageHoverEntry] = [:]
    /// Day panels of per-day spend charts, keyed by the spend row's id (`chartID`, matching the menu item's
    /// `representedObject`). Published whenever a menu contains that row, so sibling warm-up and cached tab
    /// swaps never wipe or misattribute another tab's day panel.
    var chartDayEntries: [String: UsageHoverEntry] = [:]
    /// The detail key of every row of the open root menus that has one.
    var itemKeys: [ObjectIdentifier: String] = [:]
    /// Root menus between `menuWillOpen` and the last `menuDidClose`.
    var openRootMenus: [ObjectIdentifier: NSMenu] = [:]

    /// The menu an action inside a detail view should close: the panel's copies of the author's submenus
    /// are never opened, so for them it is the open root menu the panel belongs to.
    static func menuToClose(for menu: NSMenu?) -> NSMenu? {
        guard let menu, LemelsonAdoptionState.shared.copies.values.contains(where: { $0 === menu }) else {
            return menu
        }
        return self.shared.openRootMenus.values.first ?? menu
    }
}

extension StatusItemController {
    /// Called by the builders of the fork's own rows.
    func lemelsonRegisterDetail(_ entry: UsageHoverEntry) {
        LemelsonDetailPanelState.shared.ownEntries[entry.key] = entry
    }

    /// Called by the builders of a per-day spend chart: registers its day panel under the spend row's id.
    func lemelsonRegisterChartDayDetail(forRowID rowID: String, _ entry: UsageHoverEntry) {
        LemelsonDetailPanelState.shared.chartDayEntries[rowID] = entry
    }

    func lemelsonDetailRootMenuWillOpen(_ menu: NSMenu) {
        let state = LemelsonDetailPanelState.shared
        state.openRootMenus[ObjectIdentifier(menu)] = menu
        let panel = UsageHoverPanelController.shared
        panel.menuDidOpen()
        // The menu may open with the rows of an earlier build; a rebuild on open publishes again.
        self.lemelsonPublishDetails(in: menu)
    }

    func lemelsonDetailAllMenusDidClose() {
        let state = LemelsonDetailPanelState.shared
        // Never leave a row without its own submenu once the menu is closed.
        self.lemelsonRestoreAllAdoptedSubmenus()
        state.openRootMenus.removeAll()
        state.itemKeys.removeAll()
        UsageChartPointer.shared.cancelActiveInteraction()
        // A zoom lives as long as the menu: the next open starts on the chosen period.
        UsagePanelSelection.shared.clearCustomRange()
        UsageHoverPanelController.shared.menuDidClose()
    }

    /// Hook at the start of `populateMenu`: the author's code always sees its own submenus.
    func lemelsonMenuWillPopulate(_ menu: NSMenu) {
        // The page transition takes a picture of the rows that are about to go.
        LemelsonPageTransition.shared.menuWillPopulate(menu)
        self.lemelsonRestoreAdoptedSubmenus(in: menu)
    }

    /// After a build of an open root menu: tells the panel which rows of it have a detail view.
    func lemelsonDetailMenuDidPopulate(_ menu: NSMenu) {
        guard LemelsonDetailPanelState.shared.openRootMenus[ObjectIdentifier(menu)] != nil else { return }
        self.lemelsonPublishDetails(in: menu)
    }

    func lemelsonPublishDetails(in menu: NSMenu) {
        guard menu.supermenu == nil else { return }
        let state = LemelsonDetailPanelState.shared
        var entries: [UsageHoverEntry] = []
        var seenKeys = Set<String>()
        var keys: [ObjectIdentifier: String] = [:]
        for item in menu.items {
            guard let id = item.representedObject as? String else { continue }
            if let entry = state.ownEntries[id] {
                if seenKeys.insert(entry.key).inserted {
                    entries.append(entry)
                }
                keys[ObjectIdentifier(item)] = entry.key
            }
            if let dayEntry = state.chartDayEntries[id], seenKeys.insert(dayEntry.key).inserted {
                entries.append(dayEntry)
            }
        }
        entries += self.lemelsonAdoptDetails(in: menu, keys: &keys)
        state.itemKeys = keys
        UsageHoverPanelController.shared.setEntries(entries)
    }

    /// Called for every highlight change in a menu: shows the detail panel next to a row that has one.
    func lemelsonMenuWillHighlight(_ item: NSMenuItem?, in menu: NSMenu) {
        guard menu.supermenu == nil else { return }
        let panel = UsageHoverPanelController.shared
        // The rows under the pointer are a moving copy while the page slides.
        guard !LemelsonPageTransition.shared.isActive else {
            panel.hide(animated: false)
            return
        }
        guard let item, item.isEnabled,
              let key = LemelsonDetailPanelState.shared.itemKeys[ObjectIdentifier(item)],
              panel.hasEntry(key),
              let (rowRect, window) = self.lemelsonScreenRect(of: item, in: menu)
        else {
            // The pointer is on the spend chart's non-selectable row (`item == nil`): keep its day panel while
            // the pointer actually sits over the chart or the band leading to the panel. Highlighting any other
            // enabled menu row (e.g. via arrow keys) closes the day panel.
            if item == nil,
               panel.isShowingChartDayPanel,
               UsageDayFocus.shared.activeChartID != nil,
               UsageChartPointer.shared.isPointerOverChartOrBand(at: panel.lastPointerLocation)
            {
                return
            }
            // The chart's own row became the highlighted one (Overview → Limits: its row takes clicks for the
            // switches, so it highlights) in the same pointer move that reached the plot: the hover has just
            // begun, it is not over. Without this the pointed-at time was dropped until the next move.
            if let item,
               panel.isShowingChartDayPanel,
               let chartID = UsageDayFocus.shared.activeChartID,
               UsageChartPointer.shared.isPointerOverChartOrBand(at: panel.lastPointerLocation),
               let plot = UsageChartPointer.shared.plotScreenRect(chartID: chartID),
               let (rowRect, _) = self.lemelsonScreenRect(of: item, in: menu),
               rowRect.contains(NSPoint(x: plot.midX, y: plot.midY))
            {
                return
            }
            if item != nil, UsageDayFocus.shared.activeChartID != nil {
                UsageChartPointer.shared.trace?("chart focus cleared: a row without a panel is highlighted")
                UsageDayFocus.shared.clear()
            }
            panel.pointerLeftRows()
            return
        }
        // Onto a row with its own detail: the chart's hovered day ends, the panel moves to the row.
        if UsageDayFocus.shared.activeChartID != nil {
            UsageChartPointer.shared.trace?("chart focus cleared: a row with a panel is highlighted")
            UsageDayFocus.shared.clear()
        }
        panel.show(
            key: key,
            rowRect: rowRect,
            menuFrame: window.frame,
            screen: window.screen,
            appearance: window.effectiveAppearance)
    }

    /// The row's frame on screen and the menu window. Rows with a custom view know it; plain rows are
    /// found in the menu's own table.
    func lemelsonScreenRect(of item: NSMenuItem, in menu: NSMenu) -> (NSRect, NSWindow)? {
        if let view = item.view, let window = view.window {
            return (window.convertToScreen(view.convert(view.bounds, to: nil)), window)
        }
        guard let window = self.lemelsonMenuWindow(of: menu),
              let index = menu.items.firstIndex(where: { $0 === item }),
              let table = Self.lemelsonMenuTable(in: window.contentView),
              index < table.numberOfRows
        else { return nil }
        let rect = table.rect(ofRow: index)
        return (window.convertToScreen(table.convert(rect, to: nil)), window)
    }

    /// NSMenu draws its rows in a table view inside its scroll view, one table row per menu item.
    static func lemelsonMenuTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let table = self.lemelsonMenuTable(in: sub) { return table }
        }
        return nil
    }
}
