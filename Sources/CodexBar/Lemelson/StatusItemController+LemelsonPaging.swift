import AppKit
import CodexBarCore
import LemelsonUsageKit
import os

// One bounded line of pages for the merged menu:
//   Overview, Codex, …, Claude:Limits, Claude:Spend, Claude:Value, Claude:Classic, …
// Left/right arrow keys and a horizontal two-finger swipe move along it, never past either end and never
// out of CodexBar to the neighbouring menu bar items. Hooks in the author's code:
//   • `navigateProviderSwitcher` (ProviderNavigation): Claude modes first, hard edges, the landing mode;
//   • `handleProviderSwitcherShortcut` (ProviderSwitcher): left/right left to `LemelsonMenuEventFilter`;
//   • `populateMenu` (Menu): tells the page transition that the new rows are in.

/// What a scroll event says, without AppKit. The swipe logic works on these, so the self-test can
/// drive exactly the code that real trackpad events go through.
struct LemelsonScrollSample {
    enum Phase {
        /// A classic wheel or a legacy device: no gesture phases.
        case none
        case mayBegin
        case began
        case changed
        case ended
        case cancelled
    }

    var dx: CGFloat
    var dy: CGFloat
    var phase: Phase
    var isMomentum: Bool
    /// Trackpad or Magic Mouse: deltas in points rather than wheel lines.
    var isPrecise: Bool
    var time: TimeInterval

    init(
        dx: CGFloat,
        dy: CGFloat,
        phase: Phase,
        isMomentum: Bool = false,
        isPrecise: Bool = true,
        time: TimeInterval)
    {
        self.dx = dx
        self.dy = dy
        self.phase = phase
        self.isMomentum = isMomentum
        self.isPrecise = isPrecise
        self.time = time
    }

    init(event: NSEvent) {
        let phase: Phase = if event.phase.contains(.began) {
            .began
        } else if event.phase.contains(.ended) {
            .ended
        } else if event.phase.contains(.cancelled) {
            .cancelled
        } else if event.phase.contains(.mayBegin) {
            .mayBegin
        } else if event.phase.contains(.changed) || event.phase.contains(.stationary) {
            .changed
        } else {
            .none
        }
        self.init(
            dx: event.scrollingDeltaX,
            dy: event.scrollingDeltaY,
            phase: phase,
            isMomentum: !event.momentumPhase.isEmpty,
            isPrecise: event.hasPreciseScrollingDeltas,
            time: event.timestamp)
    }
}

/// One swipe = one page. The axis is decided once per gesture from the first few points of travel; a
/// vertical gesture belongs to the menu (it keeps scrolling), a horizontal one to the pager, momentum
/// included, so the tail of a flick cannot flip a second page.
struct LemelsonSwipeRecognizer {
    enum Action: Equatable {
        /// Leave the event to NSMenu.
        case pass
        /// Take the event away from NSMenu and do nothing with it.
        case swallow
        case page(StatusItemMenuProviderNavigationDirection)
    }

    private enum Axis {
        case undecided
        case horizontal
        case vertical
    }

    /// Travel (points) before the axis is decided.
    static let decisionDistance: CGFloat = 6
    /// Horizontal travel (points) that turns a page.
    static let pageDistance: CGFloat = 28
    /// A gesture is horizontal when its horizontal travel is this many times its vertical travel.
    static let horizontalRatio: CGFloat = 1.3
    /// A wheel without phases (tilt wheel, shift+wheel) turns at most one page per this interval.
    static let wheelLockout: TimeInterval = 0.35

    private var axis = Axis.undecided
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var fired = false
    private var lastWheelPage: TimeInterval = -.infinity

    mutating func reset() {
        self.axis = .undecided
        self.travelX = 0
        self.travelY = 0
        self.fired = false
    }

    /// Content follows the fingers, as in a scroll view: a positive delta moves the content right, which
    /// reveals the previous page. The deltas already carry the user's natural-scrolling setting.
    private static func direction(forTravel dx: CGFloat) -> StatusItemMenuProviderNavigationDirection {
        dx < 0 ? .next : .previous
    }

    mutating func feed(_ sample: LemelsonScrollSample) -> Action {
        if sample.isMomentum {
            return self.axis == .horizontal ? .swallow : .pass
        }
        switch sample.phase {
        case .none:
            guard abs(sample.dx) > abs(sample.dy), sample.dx != 0 else { return .pass }
            guard sample.time - self.lastWheelPage >= Self.wheelLockout else { return .swallow }
            self.lastWheelPage = sample.time
            return .page(Self.direction(forTravel: sample.dx))
        case .mayBegin, .began:
            self.reset()
            return .pass
        case .ended, .cancelled:
            // NSMenu saw the beginning of the gesture, so it also sees its end. Momentum may follow and
            // keeps the axis that was decided.
            return .pass
        case .changed:
            break
        }
        self.travelX += sample.dx
        self.travelY += sample.dy
        if self.axis == .undecided {
            guard hypot(self.travelX, self.travelY) >= Self.decisionDistance else { return .pass }
            self.axis = abs(self.travelX) > abs(self.travelY) * Self.horizontalRatio ? .horizontal : .vertical
        }
        guard self.axis == .horizontal else { return .pass }
        if !self.fired, abs(self.travelX) >= Self.pageDistance {
            self.fired = true
            return .page(Self.direction(forTravel: self.travelX))
        }
        return .swallow
    }
}

@MainActor
final class LemelsonPagingState {
    static let shared = LemelsonPagingState()
    var swipe = LemelsonSwipeRecognizer()
    /// With `lemelsonDetailPanel native`, the Spend account rows open this native submenu; a swipe closes
    /// it before turning the page.
    weak var openSubpanelMenu: NSMenu?

    /// When the last page turn was requested. Background rendering waits for a pause in paging.
    var lastPageRequest: CFTimeInterval = 0

    /// Experimental, off by default: vertical trackpad scrolling moves the menu by the exact deltas
    /// instead of NSMenu's row-by-row steps.
    /// `defaults write com.steipete.codexbar lemelsonSmoothScroll -bool YES` (no rebuild; next menu open).
    var smoothScroll = false
}

extension StatusItemController {
    static let lemelsonLog = Logger(subsystem: "com.steipete.codexbar.lemelson", category: "paging")

    // MARK: - Event entry points

    /// Installed once; sees every event the menu tracking loop dequeues.
    func lemelsonInstallMenuEventFilter() {
        LemelsonMenuEventFilter.installIfNeeded()
        guard LemelsonMenuEventFilter.handler == nil else { return }
        LemelsonMenuEventFilter.handler = { [weak self] event in
            self?.lemelsonHandleTrackedEvent(event) ?? false
        }
        LemelsonMenuEventFilter.rewrite = { event in
            UsageHoverPanelController.shared.rewriteNestedEvent(event)
        }
    }

    /// The root menu that pages, while it is open: the merged menu with the provider row, or a menu that
    /// shows the Claude mode row.
    func lemelsonPagedRootMenu() -> NSMenu? {
        if let id = self.providerSwitcherShortcutMenuID, let menu = self.openMenus[id], menu.supermenu == nil,
           menu.items.first?.view is ProviderSwitcherView
        {
            return menu
        }
        return self.openMenus.values.first { $0.supermenu == nil && self.lemelsonModeRowItem(in: $0) != nil }
    }

    /// Returns true when the event was used and must not reach NSMenu.
    func lemelsonHandleTrackedEvent(_ event: NSEvent) -> Bool {
        // Pointer events over the detail panel are the panel's: its controls work and the menu keeps the
        // row the panel belongs to highlighted.
        if UsageHoverPanelController.shared.routeTrackedEvent(event) {
            return true
        }
        switch event.type {
        case .keyDown:
            guard let menu = self.lemelsonPagedRootMenu() else { return false }
            return self.lemelsonHandleKey(event, menu: menu)
        case .scrollWheel:
            guard let menu = self.lemelsonPagedRootMenu() else { return false }
            // Only gestures over the root menu turn pages: a chart in a submenu scrolls sideways itself.
            guard let window = self.lemelsonMenuWindow(of: menu),
                  window.frame.contains(NSEvent.mouseLocation)
            else {
                LemelsonPagingState.shared.swipe.reset()
                return false
            }
            return self.lemelsonHandleScrollSample(LemelsonScrollSample(event: event), menu: menu)
        default:
            return false
        }
    }

    func lemelsonHandleKey(_ event: NSEvent, menu: NSMenu) -> Bool {
        let isArrow = event.keyCode == 123 || event.keyCode == 124
        let direction = StatusItemMenu.providerNavigationDirection(
            for: event,
            mapping: self.settings.providerSwitcherShortcuts)
        guard isArrow || direction != nil else { return false }
        // With a submenu open, left closes it and right works inside it, as in any menu.
        guard !self.lemelsonSubmenuIsOpen(of: menu) else { return false }
        if let direction {
            self.lemelsonNavigatePage(direction, menu: menu)
        }
        // A plain arrow is always kept, even at the ends of the line: NSMenu would hand it to the
        // neighbouring menu bar item.
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        return direction != nil || modifiers.isEmpty
    }

    func lemelsonHandleScrollSample(_ sample: LemelsonScrollSample, menu: NSMenu) -> Bool {
        let action = LemelsonPagingState.shared.swipe.feed(sample)
        switch action {
        case .pass:
            return self.lemelsonSmoothScroll(sample, menu: menu)
        case .swallow:
            return true
        case let .page(direction):
            if let subpanel = LemelsonPagingState.shared.openSubpanelMenu {
                subpanel.cancelTrackingWithoutAnimation()
            }
            self.lemelsonNavigatePage(direction, menu: menu)
            return true
        }
    }

    /// Applies a vertical trackpad delta (momentum included) to the menu's own scroll view.
    private func lemelsonSmoothScroll(_ sample: LemelsonScrollSample, menu: NSMenu) -> Bool {
        guard LemelsonPagingState.shared.smoothScroll, sample.isPrecise, sample.dy != 0,
              !LemelsonPageTransition.shared.isActive,
              let scrollView = Self.attachedMenuScrollView(in: menu),
              let document = scrollView.documentView, document.isFlipped
        else { return false }
        let clip = scrollView.contentView
        let maxOffset = document.frame.height - clip.bounds.height
        guard maxOffset > 0.5 else { return false }
        // Content follows the fingers: a positive delta moves it down, towards the top of the document.
        let offset = min(max(0, clip.bounds.origin.y - sample.dy), maxOffset)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: offset))
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    // MARK: - The line of pages

    /// The single navigation entry point of keys and swipes.
    func lemelsonNavigatePage(_ direction: StatusItemMenuProviderNavigationDirection, menu: NSMenu) {
        if self.shouldMergeIcons, menu.items.first?.view is ProviderSwitcherView {
            self.navigateProviderSwitcher(direction, menu: menu)
        } else {
            _ = self.lemelsonStepClaudeMode(direction, menu: menu)
        }
    }

    /// Called by `navigateProviderSwitcher` while Claude is selected. Moves to the neighbouring mode and
    /// returns true, or returns false at the first/last mode (and without the panel) so the provider tabs move.
    func lemelsonStepClaudeMode(_ direction: StatusItemMenuProviderNavigationDirection, menu: NSMenu?) -> Bool {
        guard let menu = menu ?? self.lemelsonPagedRootMenu(), self.lemelsonModeRowItem(in: menu) != nil else {
            return false
        }
        let modes = LemelsonPanelMode.allCases
        let session = LemelsonPanelSession.shared
        guard let index = modes.firstIndex(of: session.mode) else { return false }
        let target = index + (direction == .next ? 1 : -1)
        guard modes.indices.contains(target) else { return false }
        self.lemelsonSelectMode(modes[target], menu: menu)
        return true
    }

    /// Called by `navigateProviderSwitcher` right before it changes the provider tab.
    func lemelsonWillSwitchProvider(
        to selection: ProviderSwitcherSelection,
        direction: StatusItemMenuProviderNavigationDirection,
        menu: NSMenu?)
    {
        guard let menu = menu ?? self.lemelsonPagedRootMenu() else { return }
        let session = LemelsonPanelSession.shared
        // Entering Claude from the left lands on its first mode, from the right on its last.
        var landing = session.mode
        var entersClaudePanel = false
        if case let .provider(id) = selection, id.firstPartyProvider == .claude,
           FileManager.default.fileExists(atPath: UsagePanelStore.defaultURL.path)
        {
            landing = direction == .next ? .limits : .classic
            entersClaudePanel = true
        }
        self.lemelsonBeginPageTransition(
            menu: menu,
            boundary: .providerRow,
            forward: direction == .next,
            target: Self.lemelsonPageKey(selection: selection, mode: landing))
        guard entersClaudePanel, session.mode != landing else { return }
        session.mode = landing
        UsageHoverPanelController.shared.hide(animated: false)
        // Rows cached for the Claude tab were rendered in another mode.
        self.mergedSwitcherContentCaches[ObjectIdentifier(menu)]?.removeValue(forKey: selection)
    }

    /// Rendering rows ahead of time takes the main thread for a tenth of a second or more. While pages
    /// are being turned that would hold back the end of a slide and the next key press, so it waits.
    func lemelsonPostponesWarmup() -> Bool {
        LemelsonPageTransition.shared.isActive ||
            CACurrentMediaTime() - LemelsonPagingState.shared.lastPageRequest < 0.6
    }

    /// The mode buttons, arrow keys and swipes all end here.
    func lemelsonSelectMode(_ mode: LemelsonPanelMode, menu: NSMenu?) {
        let session = LemelsonPanelSession.shared
        guard session.mode != mode else { return }
        let modes = LemelsonPanelMode.allCases
        let forward = (modes.firstIndex(of: mode) ?? 0) > (modes.firstIndex(of: session.mode) ?? 0)
        if let menu {
            self.lemelsonBeginPageTransition(
                menu: menu,
                boundary: .modeRow,
                forward: forward,
                target: Self.lemelsonPageKey(selection: nil, mode: mode))
        }
        session.mode = mode
        UsageHoverPanelController.shared.hide(animated: false)
        self.lemelsonRebuildAfterModeChange(menu: menu)
    }

    // MARK: - Page names

    /// The name of a page of the line: "overview", "codex", "claude:limits".
    static func lemelsonPageKey(selection: ProviderSwitcherSelection?, mode: LemelsonPanelMode) -> String {
        switch selection {
        case .overview:
            return "overview"
        case let .provider(id):
            guard let provider = id.firstPartyProvider else { return "plugin:\(id)" }
            return provider == .claude ? "claude:\(mode.rawValue)" : provider.rawValue
        case nil:
            // A menu of its own for Claude, without the provider row.
            return "claude:\(mode.rawValue)"
        }
    }

    /// The page the menu shows now.
    func lemelsonCurrentPageKey() -> String {
        let providers = self.store.enabledFirstPartyProvidersForDisplay()
        return Self.lemelsonPageKey(
            selection: self.resolvedMergedMenuSelection(enabledProviders: providers),
            mode: LemelsonPanelSession.shared.mode)
    }

    // MARK: - Page transition

    func lemelsonMenuWindow(of menu: NSMenu) -> NSWindow? {
        for item in menu.items {
            if let window = item.view?.window {
                return window
            }
        }
        return nil
    }

    func lemelsonSubmenuIsOpen(of menu: NSMenu) -> Bool {
        if LemelsonPanelSession.shared.openSubpanels > 0 { return true }
        if self.openMenus.values.contains(where: { $0.supermenu != nil }) { return true }
        // Submenus without a delegate: every open menu level has its own popup window.
        let rootWindow = self.lemelsonMenuWindow(of: menu)
        return NSApp.windows.contains { window in
            window !== rootWindow && window.isVisible && String(describing: type(of: window)) == "NSPopupMenuWindow"
        }
    }

    func lemelsonBeginPageTransition(
        menu: NSMenu,
        boundary: LemelsonPageTransition.Boundary,
        forward: Bool,
        target: String)
    {
        guard let window = self.lemelsonMenuWindow(of: menu) else { return }
        LemelsonPagingState.shared.lastPageRequest = CACurrentMediaTime()
        // The rows the panel belongs to are leaving.
        UsageHoverPanelController.shared.hide(animated: false)
        LemelsonPageTransition.shared.begin(
            menu: menu,
            window: window,
            from: self.lemelsonCurrentPageKey(),
            target: target,
            forward: forward,
            kind: boundary,
            boundaryViews: { [weak self] menu in
                (menu.items.first?.view, self?.lemelsonModeRowItem(in: menu)?.view)
            },
            currentKey: { [weak self] in
                self?.lemelsonCurrentPageKey() ?? ""
            })
    }

    /// Hook at the end of `populateMenu`.
    func lemelsonMenuDidPopulate(_ menu: NSMenu) {
        self.lemelsonDetailMenuDidPopulate(menu)
        LemelsonPageTransition.shared.menuDidPopulate(menu)
    }
}

/// Slides the content under the mode row (or the provider row) sideways when the page changes.
///
/// NSMenu cannot animate its rows, and the pages differ in height. So the transition shows copies:
/// a view on top of the menu's own rows holds a strip of page snapshots side by side, the rows are
/// hidden (the window and its glass background stay), the real rows are swapped underneath, and the
/// strip slides to the new page. At the end the copy and the real rows change places in one Core
/// Animation transaction, so the text is never drawn twice and never missing.
///
/// The copy lives inside the menu window on purpose. In a window of its own it reached the screen a
/// frame apart from the rows now and then, and a frame with both showed the text doubled: a flash.
/// The view stays in place, transparent, until the menu closes.
///
/// The strip starts to move on the frame of the key press or swipe and keeps one continuous motion:
/// another request while it moves only gives it a new target, from where it is. A page that was shown
/// before is in the strip from the first frame (its last snapshot is kept for a while); a page seen for
/// the first time joins as soon as its rows are built.
@MainActor
final class LemelsonPageTransition {
    enum Boundary {
        case providerRow
        case modeRow
    }

    static let shared = LemelsonPageTransition()
    /// `defaults write com.steipete.codexbar lemelsonSlideDuration -float 0.3` changes it without a rebuild.
    static let defaultDuration: CFTimeInterval = 0.24
    /// The rebuild normally lands within a few frames; after this the transition gives up.
    static let rebuildTimeout: TimeInterval = 0.6
    /// How long a page built after the strip set off takes to come in from the edge.
    static let entranceDuration: CFTimeInterval = 0.16
    /// How long the menu window takes to grow or shrink to the height of the new page.
    /// Seconds the menu window takes to reach the height of the new page.
    /// `defaults write com.steipete.codexbar lemelsonHeightDuration -float 0.4` changes it without a rebuild.
    static var heightDuration: CFTimeInterval {
        let custom = UserDefaults.standard.double(forKey: "lemelsonHeightDuration")
        return custom >= 0.06 && custom <= 1 ? custom : 0.3
    }
    /// Page snapshots are dropped this long after the menu closes.
    static let cacheLifetime: TimeInterval = 600

    private struct Snapshot {
        let image: CGImage
        let size: NSSize
        /// Distance from the top of the window to the bottom of the provider row / the mode row.
        let providerBoundary: CGFloat
        let modeBoundary: CGFloat?

        var scale: CGFloat {
            CGFloat(self.image.width) / max(1, self.size.width)
        }

        func boundary(_ kind: Boundary) -> CGFloat {
            switch kind {
            case .providerRow: self.providerBoundary
            case .modeRow: self.modeBoundary ?? self.providerBoundary
            }
        }

        func crop(top: CGFloat, height: CGFloat) -> CGImage? {
            guard height > 0 else { return nil }
            let rect = CGRect(
                x: 0,
                y: (top * self.scale).rounded(),
                width: CGFloat(self.image.width),
                height: (height * self.scale).rounded())
            return self.image.cropping(to: rect)
        }
    }

    /// One page of the strip. `index` counts pages from the one the strip started on.
    private final class Slot {
        var key: String
        let index: Int
        let layer = CALayer()
        var hasImage = false

        init(key: String, index: Int) {
            self.key = key
            self.index = index
            self.layer.contentsGravity = .resize
            self.layer.anchorPoint = .zero
            self.layer.actions = LemelsonPageTransition.noImplicitActions
        }
    }

    private enum Phase {
        /// The real rows are visible. The copy view may still be there, fully transparent.
        case idle
        /// The strip is on screen and the real rows are hidden.
        case active
    }

    typealias BoundaryViews = (providerRow: NSView?, modeRow: NSView?)

    /// Takes no part in menu tracking: the pointer goes through to the rows.
    private final class HostView: NSView {
        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }

    private var phase = Phase.idle
    private var host: HostView?
    private let rootLayer = CALayer()
    private let topLayer = CALayer()
    private let clipLayer = CALayer()
    private let stripLayer = CALayer()
    private var slots: [Slot] = []
    private var kind = Boundary.modeRow
    private var boundary: CGFloat = 0
    private var panelHeight: CGFloat = 0
    private var width: CGFloat = 0
    private var targetIndex = 0
    private var targetKey = ""
    /// The real rows show the target page (they were rebuilt after the last request).
    private var targetIsFresh = false
    private var stripHasArrived = false
    private var lastForward = true
    private var entranceEnd: CFTimeInterval = 0
    /// The page whose real rows are on screen and move with the strip; nil while the rows under the
    /// row that stays are masked out and only copies show.
    private var realKey: String?
    private let rowMask = CALayer()
    /// Height animation of the menu window (see "Height" below).
    private var heightObserver: (any NSObjectProtocol)?
    private var heightTimer: Timer?
    private var applyingHeight = false
    private var shownHeight: CGFloat = 0
    private var heightFrom: CGFloat = 0
    private var heightTo: CGFloat = 0
    private var heightStart: CFTimeInterval = 0
    private var glassMargin = NSSize.zero
    /// Height the menu's scroll view is given while the window is between two heights: the taller of
    /// the two, so the rows that a growing window uncovers are already drawn.
    private var scrollHeight: CGFloat?
    private var slideStart: CFTimeInterval = 0
    private var slideFrom: CGFloat = 0
    private var slideDuration: CFTimeInterval = 0
    private weak var menu: NSMenu?
    private weak var menuWindow: NSWindow?
    private var boundaryViews: ((NSMenu) -> BoundaryViews)?
    private var currentKey: (() -> String)?
    private var timers: [Timer] = []
    private var captureTimer: Timer?
    private var cache: [String: Snapshot] = [:]
    private var cacheAppearance: NSAppearance.Name?
    private var cachePurgeTimer: Timer?
    /// Self-test log hook.
    var trace: ((String) -> Void)?

    var isActive: Bool {
        self.phase != .idle
    }

    private var duration: CFTimeInterval {
        let custom = UserDefaults.standard.double(forKey: "lemelsonSlideDuration")
        return custom > 0 ? min(max(custom, 0.06), 1) : Self.defaultDuration
    }

    /// Core Animation animates most property changes by itself. The worst one here: a change of
    /// `sublayers` cross-fades the parent for a quarter of a second, so adding the layer of the next
    /// page left the old page hanging in place as a fading ghost. Every animation here is explicit.
    fileprivate nonisolated static var noImplicitActions: [String: any CAAction] {
        [
            "sublayers": NSNull(), "contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
            "opacity": NSNull(), "frame": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
        ]
    }

    private init() {
        for layer in [self.rootLayer, self.topLayer, self.clipLayer, self.stripLayer] {
            layer.actions = Self.noImplicitActions
        }
        self.clipLayer.masksToBounds = true
        self.rowMask.backgroundColor = NSColor.black.cgColor
        self.rowMask.actions = Self.noImplicitActions
        self.topLayer.contentsGravity = .resize
        self.clipLayer.addSublayer(self.stripLayer)
        self.rootLayer.addSublayer(self.clipLayer)
        self.rootLayer.addSublayer(self.topLayer)
    }

    // MARK: - Requests

    /// `from` and `target` name the page on screen and the page to show; `currentKey` names the page the
    /// real rows show at the moment it is called.
    func begin(
        menu: NSMenu,
        window: NSWindow,
        from: String,
        target: String,
        forward: Bool,
        kind: Boundary,
        boundaryViews: @escaping (NSMenu) -> BoundaryViews,
        currentKey: @escaping () -> String)
    {
        self.cachePurgeTimer?.invalidate()
        self.cachePurgeTimer = nil
        let appearance = window.effectiveAppearance.name
        if self.cacheAppearance != appearance {
            self.cache.removeAll()
            self.cacheAppearance = appearance
        }
        self.cancelTimers()
        self.entranceEnd = 0
        self.menu = menu
        self.menuWindow = window
        self.boundaryViews = boundaryViews
        self.currentKey = currentKey
        let wasIdle = self.phase != .active
        if !wasIdle {
            self.freezeRealRows()
        } else {
            // The picture of the page at rest needs the window at its full height.
            self.finishHeight()
        }
        self.watchHeight(of: window)

        if self.phase != .active || self.kind != kind {
            // A fresh strip. If one was moving under another boundary, it restarts from its target page.
            let restartKey = self.phase == .active ? self.targetKey : from
            var start = self.phase == .active ? self.cached(restartKey, width: window.frame.width) : nil
            if start == nil {
                start = Self.snapshot(window, views: boundaryViews(menu), excluding: self.rootLayer)
            }
            guard let start else {
                self.abort()
                return
            }
            if self.phase != .active {
                self.cache[from] = start
            }
            self.startStrip(with: start, key: restartKey, kind: kind, over: window, showCopy: !wasIdle)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let existing = self.slots.first(where: { $0.key == target }) {
            // Going back to a page that is still in the strip.
            self.targetIndex = existing.index
        } else if let current = self.slot(at: self.targetIndex), !current.hasImage {
            // The page the strip was heading to never got its rows: its place goes to the new target.
            current.key = target
            self.fill(current, from: self.cached(target, width: self.width), fade: false)
        } else {
            let index = self.targetIndex + (forward ? 1 : -1)
            self.removeSlot(at: index)
            let slot = Slot(key: target, index: index)
            self.slots.append(slot)
            self.stripLayer.addSublayer(slot.layer)
            self.fill(slot, from: self.cached(target, width: self.width), fade: false)
            self.targetIndex = index
        }
        self.targetKey = target
        self.targetIsFresh = false
        self.stripHasArrived = false
        self.lastForward = forward
        CATransaction.commit()
        let duration = self.duration
        self.slideStrip(duration: duration)
        if wasIdle, let first = self.slot(at: 0) {
            // Until the menu rebuilds its rows, the page that leaves is the real rows themselves.
            self.revealRealRows(of: first, enterOffset: nil)
        }
        self.phase = .active
        self.schedule(after: duration) { [weak self] in
            guard let self else { return }
            self.stripHasArrived = true
            self.settleIfReady()
        }
        self.schedule(after: duration + Self.rebuildTimeout) { [weak self] in
            self?.log("rebuild timeout")
            self?.abort()
        }
        self.log("begin \(from) -> \(target) index=\(self.targetIndex)")
    }

    /// Hook at the end of `populateMenu`: the real rows now show `currentKey()`.
    func menuDidPopulate(_ menu: NSMenu) {
        guard self.phase == .active, menu === self.menu, let key = self.currentKey?() else { return }
        // The rows now belong to another page: the copy of the old one takes over, and the new rows
        // stay out of sight until they are placed.
        self.freezeRealRows()
        self.setRowsMasked(true)
        // NSMenu applies the new rows and its new size on its next pass; capture one frame later.
        self.captureTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture(key: key) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.captureTimer = timer
    }

    func menuDidClose() {
        self.abort()
        if let observer = self.heightObserver {
            NotificationCenter.default.removeObserver(observer)
            self.heightObserver = nil
        }
        self.cachePurgeTimer?.invalidate()
        let timer = Timer(timeInterval: Self.cacheLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cache.removeAll()
                self?.cachePurgeTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.cachePurgeTimer = timer
    }

    // MARK: - Steps

    private func capture(key: String) {
        self.captureTimer = nil
        guard self.phase == .active, let menu = self.menu, let window = self.menuWindow else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The picture needs the rows unmasked; nothing is committed until the end of this block.
        self.setRowsMasked(false)
        // The window may be between two heights; the picture is taken at the final one.
        let shown = self.shownHeight
        let resizing = self.heightTimer != nil
        if resizing { self.setWindowHeight(self.heightTo, display: false) }
        let taken = Self.snapshot(
            window,
            views: self.boundaryViews?(menu) ?? (nil, nil),
            excluding: self.rootLayer)
        if resizing { self.setWindowHeight(shown, display: false) }
        guard let snapshot = taken else {
            self.setRowsMasked(true)
            CATransaction.commit()
            return
        }
        self.cache[key] = snapshot
        self.layoutClip(height: (window.contentView?.bounds.height ?? window.frame.height) - self.boundary)
        let slot = self.slots.first(where: { $0.key == key })
        var enterOffset: CGFloat?
        if let slot {
            enterOffset = self.fill(slot, from: snapshot, fade: !slot.hasImage)
        }
        if key == self.targetKey, let slot {
            // The page that arrives is the real rows, not a picture of them: a picture draws the
            // dimmed (vibrant) text brighter than the menu does, which showed as a flash at rest.
            self.revealRealRows(of: slot, enterOffset: enterOffset)
        } else {
            self.setRowsMasked(true)
        }
        CATransaction.commit()
        CATransaction.flush()
        self.log("capture \(key) height=\(Int(snapshot.size.height))")
        if key == self.targetKey {
            self.targetIsFresh = true
            self.settleIfReady()
        }
    }

    /// The strip is at rest on the target page and the real rows show the same page: swap them.
    private func settleIfReady() {
        guard self.phase == .active, self.stripHasArrived, self.targetIsFresh else { return }
        let entranceLeft = self.entranceEnd - CACurrentMediaTime()
        guard entranceLeft <= 0 else {
            // The target page is still coming in.
            self.cancelTimers()
            self.schedule(after: entranceLeft) { [weak self] in
                self?.settleIfReady()
            }
            return
        }
        self.cancelTimers()
        // The real rows are already in place; only the pages that left are removed.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.setRowsMasked(false)
        self.rootLayer.opacity = 0
        self.clearStrip()
        CATransaction.commit()
        CATransaction.flush()
        self.realKey = nil
        self.phase = .idle
        self.log("done")
    }

    private func abort() {
        self.finishHeight()
        self.cancelTimers()
        self.captureTimer?.invalidate()
        self.captureTimer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.setRowsMasked(false)
        for layer in self.lowerRowLayers() {
            layer.removeAnimation(forKey: Self.followKey)
            layer.removeAnimation(forKey: Self.enterKey)
        }
        self.rootLayer.opacity = 0
        self.clearStrip()
        CATransaction.commit()
        self.realKey = nil
        self.host?.removeFromSuperview()
        self.phase = .idle
    }

    // MARK: - Strip

    /// Lays out a strip with one page at rest. Who shows that page, its copy or the real rows, is up
    /// to the caller.
    private func startStrip(
        with snapshot: Snapshot,
        key: String,
        kind: Boundary,
        over window: NSWindow,
        showCopy: Bool)
    {
        guard let content = window.contentView else { return }
        self.kind = kind
        self.width = content.bounds.width
        self.boundary = min(snapshot.boundary(kind), content.bounds.height)
        // Tall enough for any page: from the top of the menu to the bottom of the screen.
        let screenBottom = (window.screen ?? NSScreen.main)?.frame.minY ?? window.frame.minY
        self.panelHeight = max(content.bounds.height, window.frame.maxY - screenBottom)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.attachHost(to: content)
        self.clearStrip()
        self.rootLayer.frame = CGRect(x: 0, y: 0, width: self.width, height: self.panelHeight)
        self.topLayer.frame = CGRect(
            x: 0,
            y: self.panelHeight - self.boundary,
            width: self.width,
            height: self.boundary)
        self.stripLayer.removeAllAnimations()
        self.stripLayer.bounds = CGRect(x: 0, y: 0, width: self.width, height: self.panelHeight - self.boundary)
        self.stripLayer.position.x = self.width / 2
        self.layoutClip(height: content.bounds.height - self.boundary)
        if self.phase == .active {
            // The row that stays may have changed: the mask follows it.
            self.setRowsMasked(true)
        }
        let slot = Slot(key: key, index: 0)
        self.slots = [slot]
        self.stripLayer.addSublayer(slot.layer)
        self.fill(slot, from: snapshot, fade: false)
        // From rest the page is still the real rows; its copy waits, unseen, for the rebuild.
        slot.layer.isHidden = !showCopy
        self.targetIndex = 0
        self.rootLayer.opacity = 1
        CATransaction.commit()
        CATransaction.flush()
    }

    /// Puts the copy view over the rows, glued to the top edge: the window grows and shrinks downwards.
    private func attachHost(to content: NSView) {
        let host: HostView
        if let existing = self.host {
            host = existing
        } else {
            host = HostView()
            // The view gets a plain layer of its own. AppKit animates the properties of a view's
            // layer by itself (the copy used to fade in over the hidden rows); `rootLayer` is only
            // a sublayer, so its opacity changes exactly when it is told to.
            let container = CALayer()
            container.actions = Self.noImplicitActions
            host.layer = container
            host.wantsLayer = true
            container.addSublayer(self.rootLayer)
            self.host = host
        }
        let frame = NSRect(
            x: 0,
            y: content.isFlipped ? 0 : content.bounds.height - self.panelHeight,
            width: self.width,
            height: self.panelHeight)
        host.autoresizingMask = content.isFlipped ? [.maxYMargin] : [.minYMargin]
        if host.superview !== content {
            self.rootLayer.opacity = 0
            host.removeFromSuperview()
            host.frame = frame
            content.addSubview(host, positioned: .above, relativeTo: nil)
        } else if host.frame != frame {
            host.frame = frame
        }
    }

    /// The clip starts under the row that stays and is as tall as the menu's content under that row.
    /// Layer geometry is bottom-up; the strip keeps its top edge at the top of the clip.
    private func layoutClip(height: CGFloat) {
        let clipHeight = max(0, min(height, self.panelHeight - self.boundary))
        self.clipLayer.frame = CGRect(
            x: 0,
            y: self.panelHeight - self.boundary - clipHeight,
            width: self.width,
            height: clipHeight)
        self.stripLayer.position.y = clipHeight - self.stripLayer.bounds.height / 2
    }

    /// Returns the offset the page comes in from, when it joins a strip that is already moving.
    @discardableResult
    private func fill(_ slot: Slot, from snapshot: Snapshot?, fade: Bool) -> CGFloat? {
        guard let snapshot else { return nil }
        let height = snapshot.size.height - self.boundary
        guard height > 0 else { return nil }
        slot.layer.contents = snapshot.crop(top: self.boundary, height: height)
        slot.layer.contentsScale = snapshot.scale
        slot.layer.frame = CGRect(
            x: CGFloat(slot.index) * self.width,
            y: self.stripLayer.bounds.height - height,
            width: self.width,
            height: height)
        let isNew = !slot.hasImage
        slot.hasImage = true
        if fade, isNew, slot.key == self.targetKey {
            return self.slideIn(slot)
        }
        return nil
    }

    /// A page whose rows were built after the strip set off: it comes in from the edge it would have
    /// come from, on top of what is left of the strip's own motion, instead of appearing in place.
    private func slideIn(_ slot: Slot) -> CGFloat? {
        let target = self.width / 2 - CGFloat(self.targetIndex) * self.width
        let remaining = (self.stripLayer.presentation()?.position.x ?? target) - target
        let side: CGFloat = if abs(remaining) > 0.5 {
            remaining > 0 ? 1 : -1
        } else {
            self.lastForward ? 1 : -1
        }
        let offset = side * self.width - remaining
        guard abs(offset) > 1 else { return nil }
        slot.layer.add(Self.entrance(from: offset), forKey: Self.enterKey)
        self.entranceEnd = CACurrentMediaTime() + Self.entranceDuration
        return offset
    }

    private static let followKey = "lemelsonFollow"
    private static let enterKey = "lemelsonEnter"
    /// Visible on the first frame, halfway in about 55 ms, then a soft landing.
    private static var slideTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.3, 0.4, 0.15, 1)
    }

    private static func entrance(from offset: CGFloat) -> CABasicAnimation {
        let enter = CABasicAnimation(keyPath: "position.x")
        enter.isAdditive = true
        enter.fromValue = offset
        enter.toValue = 0
        enter.duration = self.entranceDuration
        enter.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.2, 1)
        return enter
    }

    // MARK: - Real rows

    private var rowClipView: NSClipView? {
        self.menuWindow?.contentView?.subviews.lazy.compactMap { ($0 as? NSScrollView)?.contentView }.first
    }

    /// The menu's own layers that lie under the row that stays. The walk goes over layers, not views:
    /// the menu draws its plain items (Settings…, Quit) in layers that belong to no view of their own.
    private func lowerRowLayers() -> [CALayer] {
        guard let root = self.menuWindow?.contentView?.layer, let document = self.rowClipView?.documentView?.layer
        else { return [] }
        var layers: [CALayer] = []
        func visit(_ layer: CALayer, depth: Int) {
            for sub in layer.sublayers ?? [] where !sub.isHidden {
                let rect = sub.convert(sub.bounds, to: root)
                guard rect.height > 0.5, rect.width > 0.5 else { continue }
                let top = root.isGeometryFlipped ? rect.minY - root.bounds.minY : root.bounds.maxY - rect.maxY
                if top >= self.boundary - 1 {
                    layers.append(sub)
                } else if top + rect.height > self.boundary + 1, depth < 6 {
                    visit(sub, depth: depth + 1)
                }
            }
        }
        visit(document, depth: 0)
        return layers
    }

    /// Hides everything the menu draws under the row that stays, or shows it again. The row itself
    /// and what is above it are never covered: they stay the menu's own.
    private func setRowsMasked(_ masked: Bool) {
        guard let content = self.menuWindow?.contentView, let clip = self.rowClipView, let layer = clip.layer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if masked {
            let top = NSRect(
                x: 0,
                y: content.isFlipped ? 0 : content.bounds.height - self.boundary,
                width: content.bounds.width,
                height: self.boundary)
            // A view's layer uses the view's own coordinates, flipped or not.
            self.rowMask.frame = clip.convert(top, from: content)
            if layer.mask !== self.rowMask {
                layer.mask = self.rowMask
            }
        } else if layer.mask === self.rowMask {
            layer.mask = nil
        }
        CATransaction.commit()
    }

    /// The real rows take the place of `slot`'s picture and move exactly as the strip does.
    private func revealRealRows(of slot: Slot, enterOffset: CGFloat?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slot.layer.isHidden = true
        self.setRowsMasked(false)
        let rest = self.width / 2 - CGFloat(slot.index) * self.width
        let target = self.width / 2 - CGFloat(self.targetIndex) * self.width
        let moving = CACurrentMediaTime() < self.slideStart + self.slideDuration
        for layer in self.lowerRowLayers() {
            layer.removeAnimation(forKey: Self.followKey)
            layer.removeAnimation(forKey: Self.enterKey)
            if moving || abs(target - rest) > 0.5 {
                let follow = CABasicAnimation(keyPath: "position.x")
                follow.isAdditive = true
                follow.fromValue = self.slideFrom - rest
                follow.toValue = target - rest
                follow.duration = self.slideDuration
                follow.timingFunction = Self.slideTiming
                follow.beginTime = layer.convertTime(self.slideStart, from: nil)
                // A page that leaves stays out until its rows are replaced.
                follow.fillMode = .forwards
                follow.isRemovedOnCompletion = abs(target - rest) <= 0.5
                layer.add(follow, forKey: Self.followKey)
            }
            if let enterOffset {
                layer.add(Self.entrance(from: enterOffset), forKey: Self.enterKey)
            }
        }
        CATransaction.commit()
        self.realKey = slot.key
        self.log("real rows \(slot.key)")
    }

    /// The copy of the page takes over from the real rows, in the same place.
    private func freezeRealRows() {
        guard let key = self.realKey else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.slots.first { $0.key == key }?.layer.isHidden = false
        self.setRowsMasked(true)
        for layer in self.lowerRowLayers() {
            layer.removeAnimation(forKey: Self.followKey)
            layer.removeAnimation(forKey: Self.enterKey)
        }
        CATransaction.commit()
        self.realKey = nil
    }

    /// Moves the strip to the target page from wherever it is now.
    private func slideStrip(duration: CFTimeInterval) {
        let target = self.width / 2 - CGFloat(self.targetIndex) * self.width
        let current = self.stripLayer.presentation()?.position.x ?? self.stripLayer.position.x
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = current
        slide.toValue = target
        slide.duration = duration
        slide.timingFunction = Self.slideTiming
        self.slideStart = CACurrentMediaTime()
        self.slideFrom = current
        self.slideDuration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.stripLayer.position.x = target
        self.stripLayer.add(slide, forKey: "slide")
        CATransaction.commit()
        CATransaction.flush()
    }

    private func slot(at index: Int) -> Slot? {
        self.slots.first { $0.index == index }
    }

    private func removeSlot(at index: Int) {
        for slot in self.slots where slot.index == index {
            slot.layer.removeFromSuperlayer()
        }
        self.slots.removeAll { $0.index == index }
    }

    private func clearStrip() {
        for slot in self.slots {
            slot.layer.removeFromSuperlayer()
        }
        self.slots.removeAll()
        self.stripLayer.removeAllAnimations()
        self.topLayer.contents = nil
    }

    private func cached(_ key: String, width: CGFloat) -> Snapshot? {
        guard let snapshot = self.cache[key], abs(snapshot.size.width - width) < 0.5 else { return nil }
        return snapshot
    }

    // MARK: - Height

    /// NSMenu gives its window the height of the new page in one step. While a page turns, that step
    /// is taken back on the spot (the resize notification arrives before anything is drawn) and the
    /// window is walked to the new height over a few frames instead. Its top edge stays where it is.
    private func watchHeight(of window: NSWindow) {
        guard self.heightObserver == nil else { return }
        self.shownHeight = window.frame.height
        if let glass = window.childWindows?.first {
            self.glassMargin = NSSize(
                width: (glass.frame.width - window.frame.width) / 2,
                height: (glass.frame.height - window.frame.height) / 2)
        }
        self.heightObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: nil)
        { [weak self] _ in
            MainActor.assumeIsolated { self?.windowDidResize() }
        }
    }

    private func windowDidResize() {
        guard !self.applyingHeight, let window = self.menuWindow else { return }
        let final = window.frame.height
        guard self.phase == .active || self.heightTimer != nil else {
            self.shownHeight = final
            return
        }
        guard abs(final - self.shownHeight) > 0.5 else { return }
        self.heightFrom = self.shownHeight
        self.heightTo = final
        self.heightStart = CACurrentMediaTime()
        self.scrollHeight = max(self.heightFrom, final)
        self.setWindowHeight(self.shownHeight, display: false, force: true)
        self.log("height \(Int(self.heightFrom)) -> \(Int(final))")
        guard self.heightTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickHeight() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.heightTimer = timer
    }

    private func tickHeight() {
        let progress = min(1, (CACurrentMediaTime() - self.heightStart) / Self.heightDuration)
        let eased = 1 - pow(1 - progress, 3)
        if progress >= 1 {
            self.finishHeight()
        } else {
            let height = self.heightFrom + (self.heightTo - self.heightFrom) * eased
            self.setWindowHeight((height * 2).rounded() / 2, display: true)
        }
    }

    private func finishHeight() {
        guard let timer = self.heightTimer else { return }
        timer.invalidate()
        self.heightTimer = nil
        self.scrollHeight = nil
        self.setWindowHeight(self.heightTo, display: true)
        // Back to the menu's own layout: the scroll view fills the window.
        if let content = self.menuWindow?.contentView {
            for case let scroll as NSScrollView in content.subviews where scroll.frame != content.bounds {
                scroll.frame = content.bounds
            }
        }
    }

    private func setWindowHeight(_ height: CGFloat, display: Bool, force: Bool = false) {
        guard let window = self.menuWindow, height > 1 else { return }
        var frame = window.frame
        guard force || abs(frame.height - height) > 0.01 else { return }
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        self.applyingHeight = true
        window.setFrame(frame, display: display)
        // The glass background is a child window of its own; it does not resize with its parent.
        if let glass = window.childWindows?.first {
            glass.setFrame(
                frame.insetBy(dx: -self.glassMargin.width, dy: -self.glassMargin.height),
                display: display)
        }
        // The menu's scroll view keeps its own height and sits at the bottom of the window. Between
        // two heights it gets the taller one and is held against the top, so the rows neither ride
        // up or down nor stay undrawn in the part a growing window uncovers.
        if let content = window.contentView, !content.isFlipped {
            for case let scroll as NSScrollView in content.subviews {
                let scrollHeight = self.scrollHeight ?? scroll.frame.height
                let target = NSRect(
                    x: scroll.frame.minX,
                    y: content.bounds.height - scrollHeight,
                    width: scroll.frame.width,
                    height: scrollHeight)
                if abs(scroll.frame.minY - target.minY) > 0.01 || abs(scroll.frame.height - scrollHeight) > 0.01 {
                    scroll.frame = target
                    scroll.layoutSubtreeIfNeeded()
                }
            }
        }
        self.applyingHeight = false
        self.shownHeight = height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layoutClip(height: height - self.boundary)
        CATransaction.commit()
    }

    // MARK: - Plumbing

    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated(action)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timers.append(timer)
    }

    private func cancelTimers() {
        for timer in self.timers {
            timer.invalidate()
        }
        self.timers.removeAll()
    }

    private func log(_ message: String) {
        self.trace?(message)
    }

    private static func snapshot(_ window: NSWindow, views: BoundaryViews, excluding copy: CALayer) -> Snapshot? {
        guard let content = window.contentView else { return nil }
        // The copy sits in the same window and must not end up in the picture. Nothing is committed
        // in between, so neither change reaches the screen. (Hiding the copy's view instead is no
        // good: AppKit brings a view back with a fade.)
        let copyOpacity = copy.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        copy.opacity = 0
        CATransaction.commit()
        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            copy.opacity = copyOpacity
            CATransaction.commit()
        }
        content.layoutSubtreeIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        content.cacheDisplay(in: bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        let distance: (NSView?) -> CGFloat? = { view in
            guard let view, view.window === window else { return nil }
            let rect = content.convert(view.bounds, from: view)
            return min(max(0, bounds.height - rect.minY), bounds.height).rounded()
        }
        return Snapshot(
            image: image,
            size: bounds.size,
            providerBoundary: distance(views.providerRow) ?? 0,
            modeBoundary: distance(views.modeRow))
    }
}
