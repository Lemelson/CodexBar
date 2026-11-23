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
        UsageHoverPanelController.shared.menuDidClose()
    }

    /// Hook at the start of `populateMenu`: the author's code always sees its own submenus.
    func lemelsonMenuWillPopulate(_ menu: NSMenu) {
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
        var keys: [ObjectIdentifier: String] = [:]
        for item in menu.items {
            guard let id = item.representedObject as? String, let entry = state.ownEntries[id] else { continue }
            entries.append(entry)
            keys[ObjectIdentifier(item)] = entry.key
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
            panel.pointerLeftRows()
            return
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
