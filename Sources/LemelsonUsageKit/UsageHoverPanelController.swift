import AppKit
import QuartzCore
import SwiftUI

// The detail panel that replaces native submenus.
//
// A native NSMenu submenu waits for the pointer to settle, closes the previous submenu and opens the
// next one from scratch, in a window of its own. This panel is one window that stays up while the
// pointer moves between rows: it appears at once, slides to the hovered row and cross-fades its
// content, joined to the menu's edge. Every row's content is rendered ahead of time, so nothing is
// computed at hover time.
//
// While a menu is open, AppKit reads every event in the menu's own tracking loop and never hands
// mouse events to other windows. The app's event filter passes them here (`routeTrackedEvent`): the
// ones over the panel are delivered to the panel window and kept from the menu, so the controls inside
// work and the menu neither closes nor drops the highlight of the row the panel belongs to.

/// One detail view the panel can show.
public struct UsageHoverEntry {
    public enum Content {
        /// SwiftUI content; the panel hosts it and refreshes it in place.
        case swiftUI(() -> AnyView)
        /// An AppKit view built (and kept up to date) by the caller. Its frame size is its size in the
        /// panel; the panel follows later changes of that size.
        case view(() -> NSView)
    }

    public let key: String
    public let width: CGFloat
    public let content: Content

    public init(key: String, width: CGFloat, content: Content) {
        self.key = key
        self.width = width
        self.content = content
    }

    public static func swiftUI(
        key: String,
        width: CGFloat = UsageHoverPanelController.panelWidth,
        _ build: @escaping () -> AnyView) -> UsageHoverEntry
    {
        UsageHoverEntry(key: key, width: width, content: .swiftUI(build))
    }
}

/// Clicks reach the panel while another app is active and the panel is not key: without this a first
/// click would only be taken as "focus this window".
private final class UsageHoverHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

/// Holds one entry's content; its layer opacity is what cross-fades. Every slot stays rendered (a hidden
/// view would paint a frame late when shown), so the ones not shown are only kept out of hit testing.
private final class UsageHoverSlotView: NSView {
    var isActive = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        self.isActive ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}

@MainActor
public final class UsageHoverPanelController: NSObject {
    public static let shared = UsageHoverPanelController()

    /// Width of the fork's own detail views.
    public nonisolated static let panelWidth: CGFloat = 340

    /// Seconds the panel stays after the pointer leaves the rows, so crossing an account header or
    /// moving onto the panel itself does not close it.
    private static let grace: TimeInterval = 0.22
    private static let screenMargin: CGFloat = 8
    private static let shadowMargin: CGFloat = 44

    private struct Placement: Equatable {
        var bottom: CGFloat
        var height: CGFloat
        var width: CGFloat
    }

    @MainActor
    private final class Slot {
        let view = UsageHoverSlotView()
        var content: NSView?
        var size = NSSize.zero
        var frameObserver: (any NSObjectProtocol)?
    }

    private var entries: [String: UsageHoverEntry] = [:]
    private var order: [String] = []
    private var slots: [String: Slot] = [:]
    private var stale: Set<String> = []
    private var warmTimer: Timer?
    private var menuOpen = false

    private var window: NSPanel?
    private let shadowView = UsageHoverDecorationView()
    private let effectView = NSVisualEffectView()
    /// Lies on top of the content: it must not take the clicks meant for the controls under it.
    private let borderView = UsageHoverDecorationView()
    private let borderLayer = CAShapeLayer()
    /// Brings the blurred background to the tone of the system menu, so the joint does not show.
    private let tintLayer = CAShapeLayer()
    private let clipView = NSView()
    /// Common-modes timer driving morph and fade: a `CADisplayLink` created on an off-screen panel window can
    /// fail to fire during `NSMenu` tracking, freezing the card's geometry and alpha.
    private var tickTimer: Timer?

    private var currentKey: String?
    private var anchorRow = NSRect.zero
    private var menuFrame = NSRect.zero
    /// Width of the window's card area: the widest entry. The card is right-aligned in it.
    private var cardAreaWidth: CGFloat = 0
    private var topFillet = false
    private var bottomFillet = false
    private var shape = UsageHoverShape.fused
    private var maskSignature = ""

    private var from = Placement(bottom: 0, height: 0, width: 0)
    private var to = Placement(bottom: 0, height: 0, width: 0)
    private var shown = Placement(bottom: 0, height: 0, width: 0)
    private var moveStarted: CFTimeInterval = 0
    private var moveStyle = UsageHoverStyle.morph
    private var moving = false

    private var alpha: CGFloat = 0
    private var alphaTarget: CGFloat = 0
    private var lastTick: CFTimeInterval = 0

    private var graceTimer: Timer?
    private var pointerLeftAt: Date?

    // Mouse routing.
    /// True while an event is being delivered to the panel window. Controls that track the mouse run
    /// their own loop then, which also goes through the app's event filter; those events are theirs.
    private var forwarding = false
    /// The last pointer position seen in a mouse event during this menu session (screen coordinates).
    private var lastPointer: NSPoint?
    private var pointerInside = false
    private var pressInside = false
    /// The view a press inside the panel went to; the drags and the release of that press follow it.
    private weak var pressedView: NSView?
    private var pressedSegment: Int?
    /// Tracking areas of the shown entry that contain the pointer.
    private var hoveredAreas: [(area: NSTrackingArea, view: NSView)] = []

    /// Self-test log hook.
    public var trace: ((String) -> Void)?

    /// True while the panel is on screen (or fading in).
    public var isVisible: Bool {
        self.alphaTarget > 0
    }

    /// The entry shown now, if the panel is visible.
    public var visibleKey: String? {
        self.isVisible ? self.currentKey : nil
    }

    /// Whether the panel has a detail view for `key`.
    public func hasEntry(_ key: String) -> Bool {
        self.entries[key] != nil
    }

    /// The panel window, for the self-test to find views inside it.
    public var panelWindow: NSWindow? {
        self.window
    }

    /// The content of the entry shown now, for the self-test to find views inside it.
    public var visibleContentView: NSView? {
        guard self.isVisible, let key = self.currentKey else { return nil }
        return self.slots[key]?.content
    }

    // MARK: - Content

    /// Replaces the set of detail views. Views that are already rendered are refreshed in place, so a
    /// panel that is on screen only changes its numbers.
    public func setEntries(_ entries: [UsageHoverEntry]) {
        self.entries = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var seen = Set<String>()
        self.order = entries.map(\.key).filter { seen.insert($0).inserted }
        for key in Array(self.slots.keys) where self.entries[key] == nil {
            self.removeSlot(key)
        }
        self.stale = Set(self.slots.keys)
        if let key = self.currentKey, self.isVisible {
            if self.entries[key] == nil {
                self.hide(animated: false)
            } else {
                self.prepareSlot(for: key)
                self.retarget(animated: true)
            }
        }
        self.scheduleWarmup()
    }

    /// The old entry point: SwiftUI views at the fork's own width.
    public func setEntries(_ entries: [(key: String, build: () -> AnyView)]) {
        self.setEntries(entries.map { UsageHoverEntry.swiftUI(key: $0.key, $0.build) })
    }

    public func menuDidOpen() {
        self.menuOpen = true
        self.lastPointer = nil
        self.scheduleWarmup()
    }

    public func menuDidClose() {
        // A drag or a hovered day on a per-day chart ends with the menu.
        UsageChartPointer.shared.cancelActiveInteraction()
        self.menuOpen = false
        self.warmTimer?.invalidate()
        self.warmTimer = nil
        self.hide(animated: false)
        self.lastPointer = nil
        self.forwarding = false
    }

    /// Renders the detail views one by one while the menu is open, so hovering never waits for SwiftUI.
    private func scheduleWarmup() {
        guard self.menuOpen, self.warmTimer == nil else { return }
        guard self.order.contains(where: { self.slots[$0] == nil || self.stale.contains($0) }) else { return }
        // A common-modes timer: main-actor tasks do not run while an NSMenu tracks the pointer.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.warmNext()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.warmTimer = timer
    }

    private func warmNext() {
        guard self.menuOpen,
              let key = self.order.first(where: { self.slots[$0] == nil || self.stale.contains($0) })
        else {
            self.warmTimer?.invalidate()
            self.warmTimer = nil
            return
        }
        self.prepareSlot(for: key)
    }

    @discardableResult
    private func prepareSlot(for key: String) -> Slot? {
        guard let entry = self.entries[key] else { return nil }
        self.ensureWindow()
        let slot: Slot
        if let existing = self.slots[key] {
            guard self.stale.contains(key) else { return existing }
            slot = existing
        } else {
            slot = Slot()
            slot.view.wantsLayer = true
            slot.view.layer?.opacity = 0
            self.clipView.addSubview(slot.view)
            self.slots[key] = slot
        }
        self.stale.remove(key)

        switch entry.content {
        case let .swiftUI(build):
            let host: UsageHoverHostingView
            if let existing = slot.content as? UsageHoverHostingView {
                existing.rootView = build()
                host = existing
            } else {
                slot.content?.removeFromSuperview()
                host = UsageHoverHostingView(rootView: build())
                slot.view.addSubview(host)
                slot.content = host
            }
            host.frame = NSRect(x: 0, y: 0, width: entry.width, height: 1)
            let height = ceil(host.fittingSize.height)
            host.frame = NSRect(x: 0, y: 0, width: entry.width, height: height)
            slot.size = NSSize(width: entry.width, height: height)
            // SwiftUI commits a fresh hosting view a frame late; laying it out now makes the first show complete.
            host.layoutSubtreeIfNeeded()
        case let .view(build):
            let view = build()
            if slot.content !== view {
                slot.content?.removeFromSuperview()
                if let observer = slot.frameObserver {
                    NotificationCenter.default.removeObserver(observer)
                    slot.frameObserver = nil
                }
                slot.view.addSubview(view)
                slot.content = view
                // Some views change their own height later (an expanded list); the panel follows.
                view.postsFrameChangedNotifications = true
                slot.frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: view,
                    queue: nil)
                { [weak self] _ in
                    MainActor.assumeIsolated { self?.contentFrameDidChange(key) }
                }
            }
            view.setFrameOrigin(.zero)
            slot.size = NSSize(width: max(1, view.frame.width), height: max(1, ceil(view.frame.height)))
        }
        self.layoutSlot(slot)
        return slot
    }

    private func removeSlot(_ key: String) {
        guard let slot = self.slots.removeValue(forKey: key) else { return }
        if let observer = slot.frameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        slot.view.removeFromSuperview()
    }

    private func contentFrameDidChange(_ key: String) {
        guard let slot = self.slots[key], let view = slot.content else { return }
        let size = NSSize(width: max(1, view.frame.width), height: max(1, ceil(view.frame.height)))
        guard size != slot.size else { return }
        slot.size = size
        if view.frame.origin != .zero {
            view.setFrameOrigin(.zero)
        }
        if key == self.currentKey, self.isVisible {
            self.retarget(animated: true)
        } else {
            self.layoutSlot(slot)
        }
    }

    // MARK: - Showing

    /// The pointer is over the row `key`. `rowRect` and `menuFrame` are in screen coordinates.
    public func show(key: String, rowRect: NSRect, menuFrame: NSRect, screen: NSScreen?, appearance: NSAppearance?) {
        guard self.entries[key] != nil, let slot = self.prepareSlot(for: key) else {
            self.hide(animated: true)
            return
        }
        self.stopGrace()
        guard let window = self.window else { return }
        let wasVisible = self.isVisible
        let previousKey = self.currentKey
        let visible = (screen ?? window.screen ?? NSScreen.main)?.visibleFrame ?? menuFrame
        let style = UsageHoverStyle.current
        let shape = UsageHoverShape.current
        let areaWidth = max(Self.panelWidth, self.entries.values.map(\.width).max() ?? Self.panelWidth)

        if menuFrame != self.menuFrame || shape != self.shape || areaWidth != self.cardAreaWidth || !wasVisible {
            self.menuFrame = menuFrame
            self.shape = shape
            self.cardAreaWidth = areaWidth
            // Fused: cover the menu's own hairline border. Card: leave a gap.
            let overlap: CGFloat = shape == .fused ? UsageHoverOutline.overlap : -6
            let right = menuFrame.minX + overlap
            let frame = NSRect(
                x: right - areaWidth - Self.shadowMargin,
                y: visible.minY,
                width: areaWidth + Self.shadowMargin,
                height: visible.height)
            if window.frame != frame {
                window.setFrame(frame, display: false)
            }
        }
        window.appearance = appearance
        self.anchorRow = rowRect
        self.currentKey = key

        let previousTarget = self.to
        self.to = self.placement(for: key, visible: visible)
        if !wasVisible || style == .instant {
            self.shown = self.to
            self.moving = false
        } else if previousKey != key || self.to != previousTarget {
            self.from = self.shown
            self.moveStyle = style
            self.moveStarted = CACurrentMediaTime()
            self.moving = true
        }
        self.updateFillets()

        if previousKey != key, !self.hoveredAreas.isEmpty {
            self.dispatchHover(nil)
        }
        for (other, otherSlot) in self.slots where other != key {
            otherSlot.view.isActive = false
            self.fade(otherSlot.view, to: 0, duration: wasVisible ? style.fadeDuration : 0)
        }
        slot.view.isActive = true
        self.fade(slot.view, to: 1, duration: wasVisible ? style.fadeDuration : 0)

        self.alphaTarget = 1
        if !wasVisible {
            self.alpha = style == .instant ? 1 : 0
            window.alphaValue = self.alpha
            window.orderFront(nil)
        }
        self.applyLayout()
        self.startTicking()
        if previousKey != key || !wasVisible {
            self.trace?("panel show \(key) size=\(Int(slot.size.width))x\(Int(slot.size.height))")
        }
    }

    /// True while the panel shows a per-day chart's day panel (keys end in ":day").
    public var isShowingChartDayPanel: Bool {
        self.isVisible && self.currentKey?.hasSuffix(":day") == true
    }

    /// For a pointer that keeps moving over one anchor (a per-day chart): the first call shows the entry, later
    /// calls for the same entry only keep it up and move its anchor, with no new slide or fade.
    public func showIfNeededOrKeep(
        key: String,
        rowRect: NSRect,
        menuFrame: NSRect,
        screen: NSScreen?,
        appearance: NSAppearance?)
    {
        if self.isVisible, self.currentKey == key, self.menuFrame == menuFrame {
            self.stopGrace()
            self.anchorRow = rowRect
            return
        }
        self.show(key: key, rowRect: rowRect, menuFrame: menuFrame, screen: screen, appearance: appearance)
    }

    /// Adds (or replaces) one entry without touching the others, e.g. a chart's day panel. The next
    /// `setEntries` replaces the whole set: pass the entry there too to keep it.
    public func registerDynamicEntry(_ entry: UsageHoverEntry) {
        if self.entries[entry.key] == nil {
            self.order.append(entry.key)
        }
        self.entries[entry.key] = entry
        if self.slots[entry.key] != nil {
            self.stale.insert(entry.key)
        }
        self.scheduleWarmup()
    }

    /// The pointer left the rows: close after a short grace period unless it is over the panel.
    public func pointerLeftRows() {
        guard self.isVisible, self.graceTimer == nil else { return }
        self.pointerLeftAt = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkPointer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.graceTimer = timer
    }

    public func hide(animated: Bool) {
        self.stopGrace()
        self.pointerInside = false
        self.pressInside = false
        guard self.isVisible || self.alpha > 0 else { return }
        self.alphaTarget = 0
        self.trace?("panel hide animated=\(animated)")
        if !animated || UsageHoverStyle.current == .instant {
            self.alpha = 0
            self.finishHide()
        } else {
            self.startTicking()
        }
    }

    /// The last pointer position seen in a tracked menu event (or `NSEvent.mouseLocation` before any event).
    public var lastPointerLocation: NSPoint {
        self.pointerLocation
    }

    private var pointerLocation: NSPoint {
        self.lastPointer ?? NSEvent.mouseLocation
    }

    private func checkPointer() {
        guard self.isVisible else {
            self.stopGrace()
            return
        }
        let pointer = self.pointerLocation
        if self.cardScreenRect.insetBy(dx: -6, dy: -6).contains(pointer) || self.anchorRow.contains(pointer) {
            self.pointerLeftAt = Date()
            return
        }
        if let left = self.pointerLeftAt, Date().timeIntervalSince(left) >= Self.grace {
            self.hide(animated: true)
        }
    }

    private func stopGrace() {
        self.graceTimer?.invalidate()
        self.graceTimer = nil
        self.pointerLeftAt = nil
    }

    private func finishHide() {
        if !self.hoveredAreas.isEmpty {
            self.dispatchHover(nil)
        }
        self.window?.alphaValue = 0
        self.window?.orderOut(nil)
        self.currentKey = nil
        self.moving = false
        for slot in self.slots.values {
            slot.view.isActive = false
            slot.view.layer?.removeAnimation(forKey: "fade")
            slot.view.layer?.opacity = 0
        }
        self.stopTickingIfIdle()
    }

    // MARK: - Mouse routing

    /// Called by the app's event filter for every event the menu's tracking loop dequeues. Returns true
    /// when the event belongs to the panel: it was delivered there and must not reach the menu.
    public func routeTrackedEvent(_ event: NSEvent) -> Bool {
        guard Self.isPointerEvent(event.type) else { return false }
        // A control inside the panel is tracking the mouse in a loop of its own: the event is its.
        guard !self.forwarding else { return false }
        let point = Self.screenLocation(of: event)
        self.lastPointer = point
        guard self.isVisible, let window = self.window, window.isVisible else {
            self.pointerInside = false
            self.pressInside = false
            return false
        }
        let inside = self.cardScreenRect.contains(point)
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if inside || self.pressInside {
                if !self.pointerInside {
                    self.trace?("pointer entered panel")
                }
                self.pointerInside = inside
                self.stopGrace()
                self.deliver(event, at: point)
                return true
            }
            if self.pointerInside {
                // One more move at the new position, so tracking areas inside see the pointer leave.
                self.pointerInside = false
                self.trace?("pointer left panel")
                self.deliver(event, at: point)
            }
            // The menu keeps its row highlighted while the pointer is over the panel (it never saw the
            // pointer leave), so it will not report the pointer leaving the rows: the panel notices it.
            if !self.menuFrame.contains(point), !self.anchorRow.contains(point) {
                self.pointerLeftRows()
            }
            return false
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard inside else { return false }
            self.pressInside = true
            self.trace?("press in panel")
            self.deliver(event, at: point)
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard inside || self.pressInside else { return false }
            self.pressInside = false
            self.deliver(event, at: point)
            return true
        case .scrollWheel:
            guard inside else { return false }
            self.deliver(event, at: point)
            return true
        case .mouseEntered, .mouseExited:
            // The menu's own tracking areas fire when the pointer crosses into the panel; the menu must
            // not take that as the pointer leaving its row.
            return inside
        default:
            return false
        }
    }

    /// While a control inside the panel tracks the mouse in its own loop, the events it reads are
    /// addressed to the panel window, wherever the pointer is.
    public func rewriteNestedEvent(_ event: NSEvent) -> NSEvent? {
        guard self.forwarding, let window = self.window, Self.isPointerEvent(event.type),
              event.type != .scrollWheel, event.type != .mouseEntered, event.type != .mouseExited,
              event.windowNumber != window.windowNumber
        else { return nil }
        return Self.retarget(event, to: window, at: Self.screenLocation(of: event))
    }

    private func deliver(_ event: NSEvent, at point: NSPoint) {
        guard let window = self.window else { return }
        self.forwarding = true
        defer { self.forwarding = false }
        if event.type == .scrollWheel {
            // A scroll event cannot be rebuilt for another window; the view under the pointer gets it.
            guard let content = window.contentView else { return }
            let local = window.convertPoint(fromScreen: point)
            let target = content.hitTest(content.superview?.convert(local, from: nil) ?? local)
            target?.scrollWheel(with: event)
            return
        }
        let target = event.windowNumber == window.windowNumber ? event : Self.retarget(event, to: window, at: point)
        guard let target else { return }
        switch target.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Straight to the view under the pointer: `NSWindow.sendEvent` treats a click in a window that
            // is not key as a request to make it key and does not always pass it on.
            guard let content = window.contentView else { return }
            var hit = content.hitTest(content.superview?.convert(target.locationInWindow, from: nil)
                ?? target.locationInWindow)
            // An AppKit view embedded in SwiftUI (a segmented picker, the "Browse sessions" click target)
            // is hidden behind the hosting view's own hit test, and the hosting view does not pass a press
            // made outside a key window on to it. The view gets the press itself; it then tracks the mouse
            // in its own loop.
            if let found = hit, !(found is NSControl),
               let control = Self.control(in: found, at: target.locationInWindow)
            {
                hit = control
            }
            self.pressedView = hit
            self.trace?("press target \(hit.map { String(describing: type(of: $0)) } ?? "none")")
            if let segmented = hit as? NSSegmentedControl, target.type == .leftMouseDown {
                self.pressedSegment = Self.segment(of: segmented, at: target.locationInWindow)
                return
            }
            switch target.type {
            case .leftMouseDown: hit?.mouseDown(with: target)
            case .rightMouseDown: hit?.rightMouseDown(with: target)
            default: hit?.otherMouseDown(with: target)
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let view = self.pressedView else { return window.sendEvent(target) }
            switch target.type {
            case .leftMouseDragged: view.mouseDragged(with: target)
            case .rightMouseDragged: view.rightMouseDragged(with: target)
            default: view.otherMouseDragged(with: target)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let view = self.pressedView else { return }
            self.pressedView = nil
            if let segmented = view as? NSSegmentedControl {
                // The segmented control's own tracking reads the hardware button state, which says
                // "up" for a click handed over from the menu's loop: it is clicked here instead.
                let pressed = self.pressedSegment
                self.pressedSegment = nil
                guard target.type == .leftMouseUp, let pressed,
                      Self.segment(of: segmented, at: target.locationInWindow) == pressed,
                      segmented.isEnabled(forSegment: pressed)
                else { return }
                segmented.selectedSegment = pressed
                segmented.sendAction(segmented.action, to: segmented.target)
                self.trace?("segment \(pressed) selected")
                return
            }
            switch target.type {
            case .leftMouseUp: view.mouseUp(with: target)
            case .rightMouseUp: view.rightMouseUp(with: target)
            default: view.otherMouseUp(with: target)
            }
        case .mouseMoved:
            self.dispatchHover(target)
        default:
            window.sendEvent(target)
        }
    }

    /// Tracking areas live in the window server's view of the pointer, which never reaches a window the
    /// menu's loop holds the events for: a forwarded move does not fire them. The panel works out which
    /// areas of the shown entry contain the pointer and sends enter, move and exit to their owners.
    /// `event` nil means the pointer is gone (the entry changed or the panel closed).
    private func dispatchHover(_ event: NSEvent?) {
        var current: [(area: NSTrackingArea, view: NSView)] = []
        if let event, let key = self.currentKey, let root = self.slots[key]?.content {
            let point = event.locationInWindow
            func visit(_ view: NSView) {
                guard !view.isHidden else { return }
                for area in view.trackingAreas {
                    // `visibleRect` of a view hosted by SwiftUI can reach past its own bounds.
                    let rect = area.options.contains(.inVisibleRect)
                        ? view.visibleRect.intersection(view.bounds)
                        : area.rect
                    if !rect.isEmpty, view.convert(rect, to: nil).contains(point) {
                        current.append((area, view))
                    }
                }
                for sub in view.subviews {
                    visit(sub)
                }
            }
            visit(root)
        }
        let windowNumber = self.window?.windowNumber ?? 0
        func enterExit(_ type: NSEvent.EventType, _ area: NSTrackingArea) {
            guard area.options.contains(.mouseEnteredAndExited), let owner = area.owner as? NSResponder,
                  let built = NSEvent.enterExitEvent(
                      with: type,
                      location: event?.locationInWindow ?? .zero,
                      modifierFlags: [],
                      timestamp: event?.timestamp ?? ProcessInfo.processInfo.systemUptime,
                      windowNumber: windowNumber,
                      context: nil,
                      eventNumber: 0,
                      trackingNumber: 0,
                      userData: nil)
            else { return }
            if type == .mouseEntered {
                owner.mouseEntered(with: built)
            } else {
                owner.mouseExited(with: built)
            }
        }
        for old in self.hoveredAreas where !current.contains(where: { $0.area === old.area }) {
            enterExit(.mouseExited, old.area)
        }
        for new in current where !self.hoveredAreas.contains(where: { $0.area === new.area }) {
            enterExit(.mouseEntered, new.area)
        }
        if let event {
            for item in current where item.area.options.contains(.mouseMoved) {
                (item.area.owner as? NSResponder)?.mouseMoved(with: event)
            }
        }
        if let event, current.count != self.hoveredAreas.count || current.isEmpty {
            let owners = current.map { String(describing: type(of: $0.view)) }.joined(separator: ",")
            self.trace?("hover \(Int(event.locationInWindow.x)),\(Int(event.locationInWindow.y)) areas=\(current.count) [\(owners)]")
        }
        self.hoveredAreas = current
    }

    /// The deepest enabled control under `point` (window coordinates) among `view`'s descendants.
    /// The deepest AppKit view under `point` that handles clicks itself: an enabled control, or a view of
    /// the app's own that accepts the first click (a click target laid over SwiftUI content). SwiftUI's
    /// internal views are skipped: their clicks go through the hosting view.
    private static func control(in view: NSView, at point: NSPoint) -> NSView? {
        for sub in view.subviews.reversed() where !sub.isHidden && sub.alphaValue > 0 {
            guard sub.convert(sub.bounds, to: nil).contains(point) else { continue }
            if let deeper = self.control(in: sub, at: point) {
                return deeper
            }
            if let control = sub as? NSControl {
                if control.isEnabled { return control }
                continue
            }
            if Bundle(for: type(of: sub)) != self.swiftUIBundle, sub.acceptsFirstMouse(for: nil) {
                return sub
            }
        }
        return nil
    }

    private static let swiftUIBundle = Bundle(for: NSHostingView<EmptyView>.self)

    private static func segment(of control: NSSegmentedControl, at windowPoint: NSPoint) -> Int? {
        let local = control.convert(windowPoint, from: nil)
        guard control.bounds.contains(local), control.segmentCount > 0 else { return nil }
        // Segments may have their own widths; 0 means "share the rest equally".
        let fixed = (0..<control.segmentCount).map { control.width(forSegment: $0) }
        let flexible = fixed.filter { $0 <= 0 }.count
        let spare = max(0, control.bounds.width - fixed.filter { $0 > 0 }.reduce(0, +))
        var x: CGFloat = 0
        for index in 0..<control.segmentCount {
            let width = fixed[index] > 0 ? fixed[index] : spare / CGFloat(max(1, flexible))
            if local.x < x + width { return index }
            x += width
        }
        return control.segmentCount - 1
    }

    private static func retarget(_ event: NSEvent, to window: NSWindow, at point: NSPoint) -> NSEvent? {
        let type = event.type
        let isPressOrDrag: Bool = switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            true
        default:
            false
        }
        let isRelease = type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp
        return NSEvent.mouseEvent(
            with: type,
            location: window.convertPoint(fromScreen: point),
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: isPressOrDrag ? event.eventNumber : 0,
            clickCount: isPressOrDrag ? event.clickCount : 0,
            pressure: isPressOrDrag && !isRelease ? 1 : 0)
    }

    private static func isPointerEvent(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
             .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel,
             .mouseEntered, .mouseExited:
            true
        default:
            false
        }
    }

    /// The event's position on screen. An event with no window carries screen coordinates.
    public static func screenLocation(of event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        if event.windowNumber > 0, let window = NSApp.window(withWindowNumber: event.windowNumber) {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return event.locationInWindow
    }

    // MARK: - Geometry

    /// The card's frame inside the window: right-aligned, so its edge stays joined to the menu while
    /// its width changes.
    private var cardX: CGFloat {
        (self.window?.frame.width ?? 0) - self.shown.width
    }

    /// The visible card, in screen coordinates.
    public var cardScreenRect: NSRect {
        guard let window = self.window, self.isVisible else { return .zero }
        return NSRect(
            x: window.frame.minX + self.cardX,
            y: window.frame.minY + self.shown.bottom,
            width: self.shown.width,
            height: self.shown.height)
    }

    /// Where the panel for `key` sits, in window coordinates: its top follows the hovered row and it
    /// stays inside the menu's height when it fits there, otherwise inside the screen.
    private func placement(for key: String, visible: NSRect) -> Placement {
        guard let window = self.window else { return self.shown }
        let size = self.slots[key]?.size ?? NSSize(width: Self.panelWidth, height: 200)
        let height = min(size.height, visible.height - 2 * Self.screenMargin)
        let inset = UsageHoverOutline.radius + UsageHoverOutline.fillet
        var highest = visible.maxY - Self.screenMargin
        var lowest = visible.minY + Self.screenMargin
        if self.menuFrame.height - 2 * inset >= height {
            highest = min(highest, self.menuFrame.maxY - inset)
            lowest = max(lowest, self.menuFrame.minY + inset)
        }
        var top = self.anchorRow.maxY + 6
        top = min(top, highest)
        top = max(top, lowest + height)
        return Placement(
            bottom: top - height - window.frame.minY,
            height: height,
            width: min(size.width, self.cardAreaWidth > 0 ? self.cardAreaWidth : size.width))
    }

    private func updateFillets() {
        guard let window = self.window else { return }
        let top = window.frame.minY + self.to.bottom + self.to.height
        let bottom = window.frame.minY + self.to.bottom
        let fused = self.shape == .fused
        self.topFillet = fused && top + UsageHoverOutline.fillet <= self.menuFrame.maxY - 4
        self.bottomFillet = fused && bottom - UsageHoverOutline.fillet >= self.menuFrame.minY + 4
    }

    private func retarget(animated: Bool) {
        guard let key = self.currentKey, let window = self.window else { return }
        let visible = window.screen?.visibleFrame ?? self.menuFrame
        let target = self.placement(for: key, visible: visible)
        guard target != self.to else {
            self.applyLayout()
            return
        }
        self.to = target
        let style = UsageHoverStyle.current
        if animated, style != .instant {
            self.from = self.shown
            self.moveStyle = style
            self.moveStarted = CACurrentMediaTime()
            self.moving = true
            self.startTicking()
        } else {
            self.shown = target
            self.applyLayout()
        }
        self.updateFillets()
    }

    private func layoutSlot(_ slot: Slot) {
        let body = self.clipView.bounds
        slot.view.frame = NSRect(
            x: body.width - slot.size.width,
            y: body.height - slot.size.height,
            width: slot.size.width,
            height: slot.size.height)
        slot.content?.frame = NSRect(origin: .zero, size: slot.size)
    }

    private func applyLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let fillet = UsageHoverOutline.fillet
        let body = NSRect(x: self.cardX, y: self.shown.bottom, width: self.shown.width, height: self.shown.height)
        let outer = body.insetBy(dx: 0, dy: -fillet)
        self.effectView.frame = outer
        self.shadowView.frame = outer
        self.borderView.frame = outer
        self.clipView.frame = body

        let signature = "\(self.topFillet)-\(self.bottomFillet)"
        if signature != self.maskSignature {
            self.maskSignature = signature
            self.effectView.maskImage = UsageHoverOutline.mask(
                topFillet: self.topFillet,
                bottomFillet: self.bottomFillet)
        }
        let dark = self.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.borderLayer.frame = self.borderView.bounds
        self.borderLayer.path = UsageHoverOutline.border(
            size: outer.size,
            topFillet: self.topFillet,
            bottomFillet: self.bottomFillet,
            rightEdge: self.shape == .card)
        self.borderLayer.strokeColor = (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.14)).cgColor
        self.tintLayer.frame = self.borderView.bounds
        self.tintLayer.path = UsageHoverOutline.closed(
            size: outer.size,
            topFillet: self.topFillet,
            bottomFillet: self.bottomFillet)
        self.tintLayer.fillColor = dark
            ? NSColor(red: 0.90, green: 0.92, blue: 1, alpha: 0.036).cgColor
            : NSColor.clear.cgColor
        self.shadowView.layer?.shadowPath = UsageHoverOutline.closed(
            size: outer.size,
            topFillet: self.topFillet,
            bottomFillet: self.bottomFillet)

        for slot in self.slots.values {
            self.layoutSlot(slot)
        }
    }

    private func fade(_ view: NSView, to value: Float, duration: Double) {
        guard let layer = view.layer else { return }
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "fade")
        layer.opacity = value
        guard duration > 0, current != value else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = current
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "fade")
    }

    // MARK: - Window and ticking

    private func ensureWindow() {
        guard self.window == nil else { return }
        let panel = UsageHoverWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth + Self.shadowMargin, height: 800),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Mouse events over the card are addressed to this window; the app's event filter hands them over
        // (see `routeTrackedEvent`).
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.alphaValue = 0

        let root = UsageHoverRootView(frame: panel.contentLayoutRect)
        root.wantsLayer = true
        root.isCard = { [weak self] point in
            guard let self else { return false }
            return self.isVisible && NSRect(
                x: self.cardX,
                y: self.shown.bottom,
                width: self.shown.width,
                height: self.shown.height).contains(point)
        }
        panel.contentView = root

        self.shadowView.wantsLayer = true
        self.shadowView.layer?.shadowColor = NSColor.black.cgColor
        self.shadowView.layer?.shadowOpacity = 0.30
        self.shadowView.layer?.shadowRadius = 16
        self.shadowView.layer?.shadowOffset = CGSize(width: 0, height: -6)

        self.effectView.material = .menu
        self.effectView.blendingMode = .behindWindow
        self.effectView.state = .active

        self.borderView.wantsLayer = true
        self.borderLayer.fillColor = nil
        self.borderLayer.lineWidth = 1
        self.borderView.layer?.addSublayer(self.tintLayer)
        self.borderView.layer?.addSublayer(self.borderLayer)

        self.clipView.wantsLayer = true
        self.clipView.layer?.masksToBounds = true
        self.clipView.layer?.cornerRadius = UsageHoverOutline.radius
        self.clipView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]

        root.addSubview(self.shadowView)
        root.addSubview(self.effectView)
        root.addSubview(self.clipView)
        root.addSubview(self.borderView)
        self.window = panel
    }

    private func startTicking() {
        guard self.moving || self.alpha != self.alphaTarget else {
            self.stopTickingIfIdle()
            return
        }
        guard self.tickTimer == nil else { return }
        self.lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.tickTimer = timer
    }

    private func stopTickingIfIdle() {
        if !self.moving, self.alpha == self.alphaTarget {
            self.tickTimer?.invalidate()
            self.tickTimer = nil
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let delta = min(0.05, max(0, now - self.lastTick))
        self.lastTick = now

        if self.moving {
            let elapsed = now - self.moveStarted
            let progress = CGFloat(self.moveStyle.progress(at: elapsed))
            self.shown = Placement(
                bottom: self.from.bottom + (self.to.bottom - self.from.bottom) * progress,
                height: max(40, self.from.height + (self.to.height - self.from.height) * progress),
                width: max(60, self.from.width + (self.to.width - self.from.width) * progress))
            if elapsed >= self.moveStyle.moveDuration {
                self.shown = self.to
                self.moving = false
            }
            self.applyLayout()
        }

        if self.alpha != self.alphaTarget {
            let step = CGFloat(delta / 0.07)
            self.alpha = self.alphaTarget > self.alpha
                ? min(self.alphaTarget, self.alpha + step)
                : max(self.alphaTarget, self.alpha - step)
            self.window?.alphaValue = self.alpha
            if self.alpha == 0, self.alphaTarget == 0 {
                self.finishHide()
                return
            }
        }
        self.stopTickingIfIdle()
    }
}

/// The panel never becomes key: the menu keeps the keyboard, and the app is not activated.
private final class UsageHoverWindow: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// Drawn only: never the target of a click.
private final class UsageHoverDecorationView: NSView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

/// Outside the card (the shadow margin and the rest of the screen-high window) the window takes no
/// clicks: they fall through to whatever is below.
private final class UsageHoverRootView: NSView {
    var isCard: ((NSPoint) -> Bool)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = self.convert(point, from: self.superview)
        guard self.isCard?(local) ?? false else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}
