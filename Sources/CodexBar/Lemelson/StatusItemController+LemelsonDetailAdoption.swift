import AppKit
import CodexBarCore
import LemelsonUsageKit

// The author's rows whose details are a hosted submenu (cost history, Plan Usage, usage breakdown,
// credits, storage) show them in the detail panel instead.
//
// Only while a root menu is open, and only with menu refresh on (tests build menus without it, so they
// always see the author's submenus):
//   • after every build of the open menu (`lemelsonPublishDetails`), each such row's submenu is set
//     aside and replaced by an empty one. The empty submenu keeps the system arrow on plain rows and
//     keeps NSMenu treating the row as "has a submenu" (a click does not choose it and close the menu);
//     with no items, it never opens.
//   • at the start of every build (`lemelsonMenuWillPopulate`, one line in `populateMenu`) and when the
//     menu closes, the author's submenus are put back, so its reconcile, row caches and swaps always see
//     the original menu.
// The panel never shows the author's submenu itself: it shows a private copy, a placeholder made by the
// author's own factory and filled by the author's own hydrate / refresh functions. The refresh keeps the
// rendered views while their data signature is unchanged, so a menu rebuild does not reset a chart.
//
// Status Page (a list with an action) and the command submenus stay native.

@MainActor
final class LemelsonAdoptionState {
    static let shared = LemelsonAdoptionState()

    struct Record {
        weak var item: NSMenuItem?
        let original: NSMenu
        let stub: NSMenu
    }

    /// Rows whose submenu is set aside now, by row.
    var records: [ObjectIdentifier: Record] = [:]
    /// The panel's copies, by "chart id|provider".
    var copies: [String: NSMenu] = [:]
    var copyWidths: [String: CGFloat] = [:]
    /// The stacked views shown by the panel, by the same key; rebuilt when the copy's rows change.
    var stacks: [String: LemelsonDetailStackView] = [:]
}

extension StatusItemController {
    static let lemelsonAdoptedKeyPrefix = "author:"

    /// Sets the hosted submenus of `menu`'s rows aside and returns the panel entries that replace them.
    func lemelsonAdoptDetails(in menu: NSMenu, keys: inout [ObjectIdentifier: String]) -> [UsageHoverEntry] {
        guard self.isMenuRefreshEnabled, self.menuCardRenderingEnabledForController,
              !LemelsonDetailPanel.usesNativeSubmenus
        else { return [] }
        let state = LemelsonAdoptionState.shared
        let width = self.renderedMenuWidth(for: menu)
        var entries: [UsageHoverEntry] = []
        var seen = Set<String>()
        for item in menu.items {
            let itemID = ObjectIdentifier(item)
            // A row adopted by an earlier pass that this build kept as it was.
            let submenu = state.records[itemID].flatMap { $0.item === item && item.submenu === $0.stub ? $0.original : nil }
                ?? item.submenu
            guard let submenu, let identity = self.lemelsonAdoptableIdentity(of: submenu) else { continue }
            let key = "\(Self.lemelsonAdoptedKeyPrefix)\(identity.chartID)|\(identity.provider ?? "")"
            if item.submenu === submenu {
                let stub = NSMenu(title: "")
                stub.autoenablesItems = false
                state.records[itemID] = .init(item: item, original: submenu, stub: stub)
                item.submenu = stub
            }
            keys[itemID] = key
            guard seen.insert(key).inserted else { continue }
            entries.append(UsageHoverEntry(key: key, width: width, content: .view { [weak self] in
                self?.lemelsonAdoptedDetailView(
                    key: key,
                    chartID: identity.chartID,
                    provider: identity.provider,
                    width: width) ?? NSView()
            }))
        }
        return entries
    }

    /// Puts the author's submenus back on the rows of `menu` (and on rows no longer in any menu).
    func lemelsonRestoreAdoptedSubmenus(in menu: NSMenu) {
        let state = LemelsonAdoptionState.shared
        guard !state.records.isEmpty else { return }
        for (id, record) in state.records {
            guard let item = record.item else {
                state.records.removeValue(forKey: id)
                continue
            }
            guard item.menu === menu || item.menu == nil else { continue }
            if item.submenu === record.stub {
                item.submenu = record.original
            }
            state.records.removeValue(forKey: id)
        }
    }

    func lemelsonRestoreAllAdoptedSubmenus() {
        let state = LemelsonAdoptionState.shared
        for record in state.records.values {
            if let item = record.item, item.submenu === record.stub {
                item.submenu = record.original
            }
        }
        state.records.removeAll()
    }

    private func lemelsonAdoptableIdentity(of submenu: NSMenu) -> (chartID: String, provider: String?)? {
        guard self.isHostedSubviewMenu(submenu),
              let first = submenu.items.first(where: { $0.representedObject is String }),
              let chartID = first.representedObject as? String,
              chartID != Self.statusComponentsID
        else { return nil }
        return (chartID, first.toolTip)
    }

    /// The copy for `key`, filled or refreshed, stacked into one view for the panel.
    private func lemelsonAdoptedDetailView(
        key: String,
        chartID: String,
        provider: String?,
        width: CGFloat) -> NSView
    {
        let state = LemelsonAdoptionState.shared
        let copy: NSMenu
        if let existing = state.copies[key], state.copyWidths[key].map({ abs($0 - width) < 0.5 }) == true {
            copy = existing
            self.refreshHostedSubviewMenu(copy)
        } else {
            copy = self.makeHostedSubviewPlaceholderMenu(
                chartID: chartID,
                provider: provider.flatMap(UsageProvider.init(rawValue:)),
                width: width)
            // The copy is never opened: no delegate calls.
            copy.delegate = nil
            self.hydrateHostedSubviewMenuIfNeeded(copy, width: width)
            state.copies[key] = copy
            state.copyWidths[key] = width
        }
        let stack = state.stacks[key] ?? LemelsonDetailStackView()
        state.stacks[key] = stack
        stack.show(copy.items, width: width)
        return stack
    }
}

/// The rows of a hosted submenu stacked top to bottom: their views as they are, separators as hairlines,
/// a plain title row ("No data available") as a label. Follows the height changes of its rows (Storage
/// grows when a group is expanded) by changing its own frame, which the panel watches.
final class LemelsonDetailStackView: NSView {
    private var rows: [NSView] = []
    private var signature: [ObjectIdentifier] = []
    private var observers: [any NSObjectProtocol] = []
    private var width: CGFloat = 0

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    /// The rows are placed by `relayout` only; neither autoresizing nor a layout pass may move them.
    override func resizeSubviews(withOldSize _: NSSize) {
        self.relayout()
    }

    override func layout() {
        super.layout()
        self.relayout()
    }

    func show(_ items: [NSMenuItem], width: CGFloat) {
        let signature = items.map { ObjectIdentifier($0.view ?? $0) }
        guard signature != self.signature || abs(width - self.width) > 0.5 else {
            self.relayout()
            return
        }
        self.signature = signature
        self.width = width
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.observers.removeAll()
        for row in self.rows {
            row.removeFromSuperview()
        }
        self.rows = items.map { item in
            if item.isSeparatorItem {
                return LemelsonDetailSeparatorView(frame: NSRect(x: 0, y: 0, width: width, height: 9))
            }
            if let view = item.view {
                // A hosting view gets put back at its superview's origin by something outside this
                // stack; inside a wrapper of its own that is where it belongs.
                let wrapper = LemelsonDetailRowWrapper(row: view)
                view.postsFrameChangedNotifications = true
                self.observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: view,
                    queue: nil)
                { [weak self, weak wrapper] _ in
                    MainActor.assumeIsolated {
                        wrapper?.fit()
                        self?.relayout()
                    }
                })
                return wrapper
            }
            let label = NSTextField(labelWithString: item.title)
            label.textColor = .secondaryLabelColor
            label.font = .menuFont(ofSize: 0)
            label.sizeToFit()
            let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
            label.frame.origin = NSPoint(x: 14, y: (26 - label.frame.height) / 2)
            box.addSubview(label)
            return box
        }
        for row in self.rows {
            self.addSubview(row)
        }
        self.relayout()
    }

    private var isLayingOut = false

    private func relayout() {
        guard !self.isLayingOut else { return }
        self.isLayingOut = true
        defer { self.isLayingOut = false }
        var y: CGFloat = 0
        var widest = self.width
        for row in self.rows {
            let size = row.frame.size
            row.autoresizingMask = []
            if row.frame.origin != NSPoint(x: 0, y: y) {
                row.setFrameOrigin(NSPoint(x: 0, y: y))
            }
            y += max(0, size.height)
            widest = max(widest, size.width)
        }
        let size = NSSize(width: ceil(widest), height: max(1, ceil(y)))
        if self.frame.size != size {
            self.setFrameSize(size)
        }
    }
}

private final class LemelsonDetailRowWrapper: NSView {
    private let row: NSView

    init(row: NSView) {
        self.row = row
        super.init(frame: NSRect(origin: .zero, size: row.frame.size))
        self.autoresizesSubviews = false
        row.removeFromSuperview()
        self.addSubview(row)
        self.fit()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    /// Takes the row's size and keeps the row at the origin.
    func fit() {
        if self.row.frame.origin != .zero {
            self.row.setFrameOrigin(.zero)
        }
        if self.frame.size != self.row.frame.size {
            self.setFrameSize(self.row.frame.size)
        }
    }
}

private final class LemelsonDetailSeparatorView: NSView {
    override func draw(_: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 10, y: floor(self.bounds.midY), width: self.bounds.width - 20, height: 1).fill()
    }
}
