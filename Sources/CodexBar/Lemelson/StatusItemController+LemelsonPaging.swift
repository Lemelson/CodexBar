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
    /// The Spend account rows open this native submenu; a swipe closes it before turning the page.
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
            self.startStrip(with: start, key: restartKey, kind: kind, over: window)
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
        if let known = self.cached(target, width: self.width) {
            // The row that stays (its selected button) changes with the first frame of the slide.
            self.setTop(from: known)
        }
        CATransaction.commit()
        let duration = self.duration
        self.slideStrip(duration: duration)
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
        guard self.phase == .active, let menu = self.menu, let window = self.menuWindow,
              let snapshot = Self.snapshot(
                  window,
                  views: self.boundaryViews?(menu) ?? (nil, nil),
                  excluding: self.rootLayer)
        else { return }
        self.cache[key] = snapshot
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The clip follows the glass background, which already has the new height.
        self.layoutClip(height: (window.contentView?.bounds.height ?? window.frame.height) - self.boundary)
        if let slot = self.slots.first(where: { $0.key == key }) {
            self.fill(slot, from: snapshot, fade: !slot.hasImage)
        }
        if key == self.targetKey {
            self.setTop(from: snapshot)
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
        // One transaction in one window: the rows appear on the frame the copy disappears.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let window = self.menuWindow { Self.setRowsHidden(false, in: window) }
        self.rootLayer.opacity = 0
        self.clearStrip()
        CATransaction.commit()
        CATransaction.flush()
        self.phase = .idle
        self.log("done")
    }

    private func abort() {
        self.cancelTimers()
        self.captureTimer?.invalidate()
        self.captureTimer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let window = self.menuWindow { Self.setRowsHidden(false, in: window) }
        self.rootLayer.opacity = 0
        self.clearStrip()
        CATransaction.commit()
        self.host?.removeFromSuperview()
        self.phase = .idle
    }

    // MARK: - Strip

    /// Shows one page at rest, pixel-identical to the rows it covers, and hides the real rows.
    private func startStrip(with snapshot: Snapshot, key: String, kind: Boundary, over window: NSWindow) {
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
        self.setTop(from: snapshot)
        let slot = Slot(key: key, index: 0)
        self.slots = [slot]
        self.stripLayer.addSublayer(slot.layer)
        self.fill(slot, from: snapshot, fade: false)
        self.targetIndex = 0
        self.rootLayer.opacity = 1
        // Same window, same transaction: the copy appears on the frame the rows disappear.
        Self.setRowsHidden(true, in: window)
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

    private func setTop(from snapshot: Snapshot) {
        self.topLayer.contents = snapshot.crop(top: 0, height: self.boundary)
        self.topLayer.contentsScale = snapshot.scale
    }

    private func fill(_ slot: Slot, from snapshot: Snapshot?, fade: Bool) {
        guard let snapshot else { return }
        let height = snapshot.size.height - self.boundary
        guard height > 0 else { return }
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
            self.slideIn(slot)
        }
    }

    /// A page whose rows were built after the strip set off: it comes in from the edge it would have
    /// come from, on top of what is left of the strip's own motion, instead of appearing in place.
    private func slideIn(_ slot: Slot) {
        let target = self.width / 2 - CGFloat(self.targetIndex) * self.width
        let remaining = (self.stripLayer.presentation()?.position.x ?? target) - target
        let side: CGFloat = if abs(remaining) > 0.5 {
            remaining > 0 ? 1 : -1
        } else {
            self.lastForward ? 1 : -1
        }
        let offset = side * self.width - remaining
        guard abs(offset) > 1 else { return }
        let enter = CABasicAnimation(keyPath: "position.x")
        enter.isAdditive = true
        enter.fromValue = offset
        enter.toValue = 0
        enter.duration = Self.entranceDuration
        enter.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.2, 1)
        slot.layer.add(enter, forKey: "enter")
        self.entranceEnd = CACurrentMediaTime() + Self.entranceDuration
    }

    /// Moves the strip to the target page from wherever it is now.
    private func slideStrip(duration: CFTimeInterval) {
        let target = self.width / 2 - CGFloat(self.targetIndex) * self.width
        let current = self.stripLayer.presentation()?.position.x ?? self.stripLayer.position.x
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = current
        slide.toValue = target
        slide.duration = duration
        // Visible on the first frame, halfway in about 55 ms, then a soft landing.
        slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.4, 0.15, 1)
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

    /// Hides what the menu window draws (its rows and scroll arrows) but not the window: its glass
    /// background lives in a separate window that follows the menu window's alpha.
    private static func setRowsHidden(_ hidden: Bool, in window: NSWindow) {
        guard let content = window.contentView else { return }
        let alpha: CGFloat = hidden ? 0 : 1
        // Without actions: a layer's opacity otherwise fades over a quarter of a second, and the old
        // rows show through the copy as a ghost.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in content.subviews where !(view is HostView) {
            let target = (view as? NSScrollView)?.contentView ?? view
            target.alphaValue = alpha
            // The layer too, so the change belongs to the caller's transaction.
            target.layer?.opacity = Float(alpha)
            target.layer?.removeAnimation(forKey: "opacity")
        }
        CATransaction.commit()
    }

    private static func snapshot(_ window: NSWindow, views: BoundaryViews, excluding copy: CALayer) -> Snapshot? {
        guard let content = window.contentView else { return nil }
        // The rows may be hidden under the copy right now; draw them as they are on screen otherwise.
        let wasHidden = content.subviews.contains { ($0 as? NSScrollView)?.contentView.alphaValue == 0 }
        // The copy sits in the same window and must not end up in the picture. Nothing is committed
        // in between, so neither change reaches the screen. (Hiding the copy's view instead is no
        // good: AppKit brings a view back with a fade.)
        let copyOpacity = copy.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        copy.opacity = 0
        CATransaction.commit()
        if wasHidden {
            self.setRowsHidden(false, in: window)
        }
        defer {
            if wasHidden {
                self.setRowsHidden(true, in: window)
            }
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
