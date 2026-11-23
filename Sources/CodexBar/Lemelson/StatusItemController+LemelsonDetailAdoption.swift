import AppKit
import CodexBarCore
import LemelsonUsageKit

// The author's rows whose details are a hosted submenu (cost history, Plan Usage, usage breakdown,
// credits, storage, the live component list of Status Page) show them in the detail panel instead.
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
// Status Page: its list of components is shown by the panel, with "Open Status Page" as a clickable row
// under it, and a click on the Status Page row itself opens the page too (`lemelsonClickStatusRow`): an
// item with a submenu never sends its own action. The command submenus stay native.

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
              let chartID = first.representedObject as? String
        else { return nil }
        // The status link names its provider in `identifier`, the other rows in `toolTip`.
        return (chartID, first.toolTip ?? first.identifier?.rawValue)
    }

    static var lemelsonStatusKeyPrefix: String {
        "\(Self.lemelsonAdoptedKeyPrefix)\(Self.statusComponentsID)|"
    }

    /// A click (mouse up) on an adopted Status Page row of an open root menu opens the provider's status page
    /// and closes the menu, as the plain Status Page row does. Returns true when it was such a click.
    func lemelsonClickStatusRow(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseUp else { return false }
        let state = LemelsonDetailPanelState.shared
        for menu in state.openRootMenus.values {
            guard let item = self.highlightedMenuItems[ObjectIdentifier(menu)] ?? menu.highlightedItem,
                  let key = state.itemKeys[ObjectIdentifier(item)], key.hasPrefix(Self.lemelsonStatusKeyPrefix),
                  let (rect, _) = self.lemelsonScreenRect(of: item, in: menu),
                  rect.contains(NSEvent.mouseLocation) || rect.contains(Self.lemelsonScreenPoint(of: event))
            else { continue }
            let provider = String(key.dropFirst(Self.lemelsonStatusKeyPrefix.count))
            self.lemelsonOpenStatusPage(provider: provider, menu: menu)
            return true
        }
        return false
    }

    /// Opens the status page of `provider` and closes the menu. While a self-test runs it only logs, so a
    /// test never opens a browser.
    func lemelsonOpenStatusPage(provider: String, menu: NSMenu?) {
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
            Self.lemelsonLog.notice("status page of \(provider, privacy: .public) would open now")
        } else {
            let sender = NSMenuItem()
            sender.identifier = NSUserInterfaceItemIdentifier(provider)
            self.openStatusPageFromMenuItem(sender)
        }
        (LemelsonDetailPanelState.menuToClose(for: menu) ?? menu)?.cancelTracking()
    }

    static func lemelsonScreenPoint(of event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        if event.windowNumber > 0, let window = NSApp.window(withWindowNumber: event.windowNumber) {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
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
        stack.perform = { [weak self] item in
            self?.lemelsonPerformDetailAction(item)
        }
        stack.show(copy.items, width: width)
        return stack
    }

    /// A plain row of a copy with an action ("Open Status Page") was clicked in the panel.
    private func lemelsonPerformDetailAction(_ item: NSMenuItem) {
        let menu = LemelsonDetailPanelState.shared.openRootMenus.values.first
        if item.action == #selector(self.openStatusPageFromMenuItem(_:)) {
            self.lemelsonOpenStatusPage(provider: item.identifier?.rawValue ?? "", menu: menu)
            return
        }
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
        menu?.cancelTracking()
    }
}

/// The rows of a hosted submenu stacked top to bottom: their views as they are, separators as hairlines,
/// a plain title row with an action ("Open Status Page") as a clickable menu row, one without ("No data
/// available") as a label. Follows the height changes of its rows (Storage
/// grows when a group is expanded) by changing its own frame, which the panel watches.
final class LemelsonDetailStackView: NSView {
    private var rows: [NSView] = []
    private var signature: [ObjectIdentifier] = []
    private var observers: [any NSObjectProtocol] = []
    private var width: CGFloat = 0
    /// Runs the action of a clicked action row.
    var perform: ((NSMenuItem) -> Void)?

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
            if item.action != nil {
                return LemelsonDetailActionRow(item: item, width: width) { [weak self] item in
                    self?.perform?(item)
                }
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

/// A plain menu row inside the panel: the item's icon and title in the menu's font, highlighted under the
/// pointer, and its action on click. The panel sends it enter, exit, press and release itself.
private final class LemelsonDetailActionRow: NSView {
    private let item: NSMenuItem
    private let onClick: (NSMenuItem) -> Void
    private var hovered = false {
        didSet { if self.hovered != oldValue { self.needsDisplay = true } }
    }

    private var pressed = false

    static let height: CGFloat = 24

    init(item: NSMenuItem, width: CGFloat, onClick: @escaping (NSMenuItem) -> Void) {
        self.item = item
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        self.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
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

    /// The row takes the clicks itself, not a subview.
    override func hitTest(_ point: NSPoint) -> NSView? {
        self.frame.contains(point) ? self : nil
    }

    override func mouseEntered(with _: NSEvent) {
        self.hovered = true
    }

    override func mouseExited(with _: NSEvent) {
        self.hovered = false
    }

    override func mouseDown(with _: NSEvent) {
        self.pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { self.pressed = false }
        guard self.pressed, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
        self.onClick(self.item)
    }

    override func draw(_: NSRect) {
        // Same selection shape as the menu's own rows.
        if self.hovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: self.bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
        let ink: NSColor = self.hovered ? .selectedMenuItemTextColor : .controlTextColor
        var x: CGFloat = 14
        if let image = self.item.image {
            let size = NSSize(width: 16, height: 16)
            let rect = NSRect(x: x, y: (self.bounds.height - size.height) / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { bounds in
                image.draw(in: bounds)
                ink.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
            x += size.width + 6
        }
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSAttributedString(string: self.item.title, attributes: [.font: font, .foregroundColor: ink])
        let height = title.size().height
        title.draw(at: NSPoint(x: x, y: (self.bounds.height - height) / 2))
    }
}

private final class LemelsonDetailSeparatorView: NSView {
    override func draw(_: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 10, y: floor(self.bounds.midY), width: self.bounds.width - 20, height: 1).fill()
    }
}
