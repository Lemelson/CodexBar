import AppKit
import CodexBarCore
import ImageIO
import LemelsonUsageKit
import os

// One bounded line of pages for the merged menu:
//   Overview, Codex:Limits, Codex:Spend, Codex:Value, Claude:Limits, Claude:Spend, Claude:Value, Antigravity
// Left/right arrow keys and a horizontal two-finger swipe move along it, never past either end and never
// out of CodexBar to the neighbouring menu bar items. Hooks in the author's code:
//   • `navigateProviderSwitcher` (ProviderNavigation): the tab's modes first (Claude, Codex), hard edges, the
//     landing mode;
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
    /// When the pointer last moved in a tracked menu. Background rendering also waits while the pointer
    /// moves: a render of 50–90 ms that starts as it heads for a row holds back that row's detail panel
    /// (a hover took 99 ms instead of 6 in a self-test).
    var lastPointerMove: CFTimeInterval = 0

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
        if event.type == .mouseMoved {
            LemelsonPagingState.shared.lastPointerMove = CACurrentMediaTime()
        }
        let chartPointer = UsageChartPointer.shared
        // A drag on a spend chart owns every pointer, key and scroll event until it ends, also when the
        // pointer crosses into the day panel left of the menu.
        if chartPointer.hasActiveDrag || chartPointer.isDragging {
            if chartPointer.routeTrackedEvent(event) {
                return true
            }
        }
        // Pointer events over the detail panel are the panel's: its controls work and the menu keeps the
        // row the panel belongs to highlighted.
        if UsageHoverPanelController.shared.routeTrackedEvent(event) {
            return true
        }
        // Hover, press, double click and drag start over the visible spend chart.
        if chartPointer.routeTrackedEvent(event) {
            return true
        }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                // Escape: first ends a drag, then zooms out of a custom range; only then closes the menu.
                if chartPointer.hasActiveDrag || chartPointer.isDragging {
                    chartPointer.cancelActiveInteraction()
                    return true
                }
                if UsagePanelSelection.shared.customRange != nil,
                   chartPointer.activeChartPlotScreenRect() != nil
                {
                    UsagePanelSelection.shared.clearCustomRange()
                    return true
                }
            }
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
        case .leftMouseUp:
            // A Status Page row whose list the panel shows keeps its own click: it opens the page.
            return self.lemelsonClickStatusRow(event)
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
            _ = self.lemelsonStepMode(direction, menu: menu)
        }
    }

    /// Called by `navigateProviderSwitcher` while a tab with modes (Overview, Claude, Codex) is selected. Moves
    /// to the neighbouring mode of the tab whose mode row the menu shows and returns true, or returns false at
    /// the first/last mode (and without a mode row) so the provider tabs move.
    func lemelsonStepMode(_ direction: StatusItemMenuProviderNavigationDirection, menu: NSMenu?) -> Bool {
        guard let menu = menu ?? self.lemelsonPagedRootMenu(), let tab = self.lemelsonModeTab(in: menu) else {
            return false
        }
        let modes = tab.modes
        guard let index = modes.firstIndex(of: LemelsonModeStore.store(for: tab).mode) else { return false }
        let target = index + (direction == .next ? 1 : -1)
        guard modes.indices.contains(target) else { return false }
        self.lemelsonSelectMode(modes[target], tab: tab, menu: menu)
        return true
    }

    /// The tab with modes a selection names, when its page is the fork's (the Claude panel needs the summary;
    /// the Codex page also needs `lemelsonCodexPage` not set to "stock").
    static func lemelsonModeTab(of selection: ProviderSwitcherSelection) -> LemelsonModeTab? {
        guard FileManager.default.fileExists(atPath: UsagePanelStore.defaultURL.path) else { return nil }
        guard case let .provider(id) = selection else {
            // Overview: Limits and Spend, unless its stock tab or the Spend-only page was asked for.
            return LemelsonOverviewPageState.shared.usesModes ? .overview : nil
        }
        switch id.firstPartyProvider {
        case .claude: return .claude
        case .codex: return LemelsonProviderPageState.codex.usesStockTab ? nil : .codex
        default: return nil
        }
    }

    /// Called when the user clicks a provider tab in `ProviderSwitcherView`.
    func lemelsonWillSelectProviderTab() {
        UsageChartPointer.shared.cancelActiveInteraction()
        UsageHoverPanelController.shared.hide(animated: false)
    }

    /// Called by `navigateProviderSwitcher` right before it changes the provider tab.
    func lemelsonWillSwitchProvider(
        to selection: ProviderSwitcherSelection,
        direction: StatusItemMenuProviderNavigationDirection,
        menu: NSMenu?)
    {
        guard let menu = menu ?? self.lemelsonPagedRootMenu() else { return }
        // Entering a tab with modes (Overview, Claude, Codex) from the left lands on its first mode, from the
        // right on its last.
        let tab = Self.lemelsonModeTab(of: selection)
        let store = tab.map(LemelsonModeStore.store(for:))
        let landing: LemelsonPanelMode? = tab.map { Self.lemelsonLandingMode(direction, tab: $0) }
        self.lemelsonBeginPageTransition(
            menu: menu,
            boundary: .providerRow,
            forward: direction == .next,
            target: Self.lemelsonPageKey(selection: selection, mode: landing))
        guard let store, let landing, store.mode != landing else { return }
        store.mode = landing
        UsageHoverPanelController.shared.hide(animated: false)
        // Rows cached for the tab were rendered in another mode.
        self.mergedSwitcherContentCaches[ObjectIdentifier(menu)]?.removeValue(forKey: selection)
    }

    /// The mode a tab with modes opens in when the line enters it: its first from the left, its last from the
    /// right.
    static func lemelsonLandingMode(
        _ direction: StatusItemMenuProviderNavigationDirection,
        tab: LemelsonModeTab = .claude) -> LemelsonPanelMode
    {
        direction == .next ? tab.modes.first ?? .limits : tab.modes.last ?? .limits
    }

    /// A page turn is waiting for a rebuild of `menu` while a native row (Status Page, Settings…) is
    /// highlighted. The author holds such rebuilds until the pointer moves, because NSMenu would keep drawing
    /// the highlight where the row was; the slide then timed out and the old page came back. The row leaves
    /// the menu instead, which drops its highlight, and the rebuild puts the new page's rows in. Returns true
    /// when the rebuild may go ahead.
    func lemelsonReleaseNativeHighlightForPageTurn(_ menu: NSMenu) -> Bool {
        let key = ObjectIdentifier(menu)
        guard LemelsonPageTransition.shared.isActive, menu === self.lemelsonPagedRootMenu(),
              let item = self.highlightedMenuItems[key], item.menu === menu, item.view == nil
        else { return false }
        self.highlightedMenuItems.removeValue(forKey: key)
        menu.removeItem(item)
        return true
    }

    /// Rendering rows ahead of time takes the main thread for a tenth of a second or more. While pages
    /// are being turned that would hold back the end of a slide and the next key press, so it waits.
    func lemelsonPostponesWarmup() -> Bool {
        LemelsonPageTransition.shared.isActive ||
            CACurrentMediaTime() - LemelsonPagingState.shared.lastPageRequest < 0.6 ||
            CACurrentMediaTime() - LemelsonPagingState.shared.lastPointerMove < 0.3
    }

    /// The mode buttons, arrow keys and swipes all end here.
    func lemelsonSelectMode(_ mode: LemelsonPanelMode, tab: LemelsonModeTab = .claude, menu: NSMenu?) {
        let store = LemelsonModeStore.store(for: tab)
        let modes = tab.modes
        guard store.mode != mode, modes.contains(mode) else { return }
        let forward = (modes.firstIndex(of: mode) ?? 0) > (modes.firstIndex(of: store.mode) ?? 0)
        if let menu {
            self.lemelsonBeginPageTransition(
                menu: menu,
                boundary: .modeRow,
                forward: forward,
                target: Self.lemelsonPageKey(tab: tab, mode: mode))
        }
        store.mode = mode
        UsageHoverPanelController.shared.hide(animated: false)
        self.lemelsonRebuildAfterModeChange(menu: menu, tab: tab)
    }

    // MARK: - Page names

    /// The name of a page of the line: "overview:limits", "codex:limits", "claude:spend", "antigravity";
    /// "overview" while Overview has no modes (its stock tab, or the Spend-only page). `mode` is the mode of
    /// the selected tab; nil takes the mode it shows now.
    static func lemelsonPageKey(selection: ProviderSwitcherSelection?, mode: LemelsonPanelMode? = nil) -> String {
        switch selection {
        case .overview:
            guard LemelsonOverviewPageState.shared.usesModes else { return LemelsonOverviewPageState.pageKey }
            return Self.lemelsonPageKey(tab: .overview, mode: mode)
        case let .provider(id):
            guard let provider = id.firstPartyProvider else { return "plugin:\(id)" }
            switch provider {
            case .claude:
                return Self.lemelsonPageKey(tab: .claude, mode: mode)
            case .codex where !LemelsonProviderPageState.codex.usesStockTab:
                return Self.lemelsonPageKey(tab: .codex, mode: mode)
            default:
                return provider.rawValue
            }
        case nil:
            // A menu of its own for Claude, without the provider row.
            return Self.lemelsonPageKey(tab: .claude, mode: mode)
        }
    }

    /// "claude:limits", "codex:value", "overview:spend".
    static func lemelsonPageKey(tab: LemelsonModeTab, mode: LemelsonPanelMode?) -> String {
        "\(tab.rawValue):\((mode ?? LemelsonModeStore.store(for: tab).mode).rawValue)"
    }

    /// The page the menu shows now.
    func lemelsonCurrentPageKey() -> String {
        let providers = self.store.enabledFirstPartyProvidersForDisplay()
        return Self.lemelsonPageKey(selection: self.resolvedMergedMenuSelection(enabledProviders: providers))
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
        // The rows the panel belongs to are leaving, and so is the chart a drag or hover was on.
        UsageChartPointer.shared.cancelActiveInteraction()
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
        self.lemelsonProviderPageMayBeShown(in: menu)
        if self.openMenus[ObjectIdentifier(menu)] != nil, menu.supermenu == nil {
            self.lemelsonScheduleProviderWarmup()
            self.lemelsonScheduleOverviewWarmup()
        }
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
/// before is in the strip from the first frame: its last picture is kept for as long as the app runs
/// (as a bitmap while the menu is in use, compressed after that). A page that was never shown has
/// nothing to slide in, so the strip stays where it is until the rows of that page are built (a few
/// frames) and then slides to them; it never moves towards an empty half.
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
    /// A page that came in as real rows gets its picture taken after resting this long.
    static let pictureDelay: TimeInterval = 0.3
    /// A picture of the page at rest younger than this is not taken again.
    static let pictureFreshness: CFTimeInterval = 30
    /// How long the menu window takes to grow or shrink to the height of the new page.
    /// Seconds the menu window takes to reach the height of the new page.
    /// `defaults write com.steipete.codexbar lemelsonHeightDuration -float 0.4` changes it without a rebuild.
    static var heightDuration: CFTimeInterval {
        let custom = UserDefaults.standard.double(forKey: "lemelsonHeightDuration")
        return custom >= 0.06 && custom <= 1 ? custom : 0.3
    }
    /// This long after the menu closes the page pictures are compressed (see `archivePictures`). A debug
    /// build takes `lemelsonPictureArchiveDelay` (seconds) instead, so a self-test can reach the archive.
    static var cacheLifetime: TimeInterval {
        #if DEBUG
        let custom = UserDefaults.standard.double(forKey: "lemelsonPictureArchiveDelay")
        if custom > 0 { return custom }
        #endif
        return 600
    }

    /// `CGImage` is immutable, so a picture can be compressed and decoded off the main thread.
    private struct Snapshot: @unchecked Sendable {
        let image: CGImage
        let size: NSSize
        /// Distance from the top of the window to the bottom of the provider row / the mode row.
        let providerBoundary: CGFloat
        let modeBoundary: CGFloat?
        /// When it was taken (`CACurrentMediaTime`); 0 for a picture that came back from the archive.
        var taken: CFTimeInterval = 0
        /// The archive holds this very picture: it is not compressed a second time.
        var archived = false

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

    /// A page picture as PNG data: a few hundred kilobytes instead of a few megabytes.
    private struct Archived: Sendable {
        let png: Data
        let size: NSSize
        let providerBoundary: CGFloat
        let modeBoundary: CGFloat?
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
    /// The last page the strip was sent to: the target, or, while the target has nothing to show yet,
    /// the page before it.
    private var shownIndex = 0
    private var shownKey = ""
    /// The target page has neither a picture nor rows yet: the strip sets off when its rows are in.
    private var waitsForRows = false
    /// The page whose real rows are on screen and move with the strip; nil while the rows under the
    /// row that stays are masked out and only copies show.
    private var realKey: String?
    /// The picture in the strip was taken from the rows that are on screen now.
    private var realPictureIsCurrent = false
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
    private var slideTo: CGFloat = 0
    private var slideDuration: CFTimeInterval = 0
    private weak var menu: NSMenu?
    private weak var menuWindow: NSWindow?
    private var boundaryViews: ((NSMenu) -> BoundaryViews)?
    private var currentKey: (() -> String)?
    private var timers: [Timer] = []
    private var placeTimer: Timer?
    private var pictureTimer: Timer?
    private var cache: [String: Snapshot] = [:]
    private var archive: [String: Archived] = [:]
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
            self.archive.removeAll()
            self.cacheAppearance = appearance
        }
        self.cancelTimers()
        self.pictureTimer?.invalidate()
        self.pictureTimer = nil
        self.menu = menu
        self.menuWindow = window
        self.boundaryViews = boundaryViews
        self.currentKey = currentKey
        let wasIdle = self.phase != .active
        if !wasIdle {
            // The rows on screen are about to be replaced: their page needs a picture of them first.
            self.takePictureOfRealRows()
            self.freezeRealRows()
        } else {
            // The picture of the page at rest needs the window at its full height.
            self.finishHeight()
        }
        self.watchHeight(of: window)

        if self.phase != .active || self.kind != kind {
            // A fresh strip. If one was moving under another boundary, it restarts from the page it shows.
            let restartKey = self.phase == .active ? self.shownKey : from
            var start = self.phase == .active ? self.cached(restartKey, width: window.frame.width) : nil
            if start == nil {
                start = Self.snapshot(window, views: boundaryViews(menu), excluding: self.rootLayer)
            }
            guard let start else {
                self.abort()
                return
            }
            if self.phase != .active, !self.rowIsHighlighted {
                self.cache[from] = start
            }
            self.startStrip(with: start, key: restartKey, kind: kind, over: window, showCopy: !wasIdle)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let slot: Slot
        if let existing = self.slots.first(where: { $0.key == target }) {
            // Going back to a page that is still in the strip.
            slot = existing
            if !slot.hasImage {
                self.fill(slot, from: self.cached(target, width: self.width))
            }
        } else if let current = self.slot(at: self.targetIndex), !current.hasImage,
                  current.index != self.shownIndex
        {
            // The page the strip was waiting for never got its rows: its place goes to the new target.
            current.key = target
            self.fill(current, from: self.cached(target, width: self.width))
            slot = current
        } else {
            let index = self.targetIndex + (forward ? 1 : -1)
            self.removeSlot(at: index)
            slot = Slot(key: target, index: index)
            self.slots.append(slot)
            self.stripLayer.addSublayer(slot.layer)
            self.fill(slot, from: self.cached(target, width: self.width))
        }
        self.targetIndex = slot.index
        self.targetKey = target
        self.targetIsFresh = false
        self.stripHasArrived = false
        // A page with nothing to show is not slid to: an empty half would come in. The strip goes to
        // (or stays on) the last page that has something, and sets off when the new rows are in.
        self.waitsForRows = !slot.hasImage
        if slot.hasImage {
            self.shownIndex = slot.index
            self.shownKey = target
        }
        CATransaction.commit()
        let duration = self.duration
        self.slideStrip(toIndex: self.shownIndex, duration: duration)
        if wasIdle, let first = self.slot(at: 0) {
            // Until the menu rebuilds its rows, the page that leaves is the real rows themselves.
            self.revealRealRows(of: first, pictureIsCurrent: true)
        }
        self.phase = .active
        if !self.waitsForRows {
            self.scheduleArrival(after: duration)
        }
        self.schedule(after: duration + Self.rebuildTimeout) { [weak self] in
            self?.log("rebuild timeout")
            self?.abort()
        }
        self.log("begin \(from) -> \(target) index=\(self.targetIndex)\(self.waitsForRows ? ", waits for rows" : "")")
    }

    private func scheduleArrival(after delay: TimeInterval) {
        self.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.stripHasArrived = true
            self.settleIfReady()
        }
    }

    /// Hook at the start of `populateMenu`: the rows on screen are about to be replaced. Their picture
    /// takes over before the rebuild touches them: the rebuild puts its work on screen in steps (the old
    /// rows are gone a few frames before the new ones are in), and none of that may show.
    func menuWillPopulate(_ menu: NSMenu) {
        guard self.phase == .active, menu === self.menu, self.realKey != nil else { return }
        self.takePictureOfRealRows()
        self.freezeRealRows()
        CATransaction.flush()
    }

    /// Hook at the end of `populateMenu`: the real rows now show `currentKey()`.
    func menuDidPopulate(_ menu: NSMenu) {
        guard self.phase == .active, menu === self.menu, let key = self.currentKey?() else { return }
        self.log("populated \(key)")
        // The rows now belong to another page: the copy of the old one takes over, and the new rows
        // stay out of sight until they are placed.
        self.freezeRealRows()
        self.setRowsMasked(true)
        self.schedulePlacement(of: key, attempt: 0)
    }

    /// The menu is opening: pictures in the archive come back as bitmaps on a background queue, so a key
    /// press does not have to wait for one to be decoded.
    func menuWillOpen() {
        self.cachePurgeTimer?.invalidate()
        self.cachePurgeTimer = nil
        let packed = self.archive.filter { self.cache[$0.key] == nil }
        guard !packed.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let started = CACurrentMediaTime()
            var decoded: [String: Snapshot] = [:]
            for (key, item) in packed {
                guard let image = Self.image(png: item.png) else { continue }
                decoded[key] = Snapshot(
                    image: image,
                    size: item.size,
                    providerBoundary: item.providerBoundary,
                    modeBoundary: item.modeBoundary,
                    archived: true)
            }
            let pictures = decoded
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            // A run loop block: the main dispatch queue is not a sure thing while a menu tracks.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    let transition = LemelsonPageTransition.shared
                    var taken: [String] = []
                    for (key, picture) in pictures where transition.cache[key] == nil && transition.archive[key] != nil {
                        transition.cache[key] = picture
                        taken.append(key)
                    }
                    transition.log("archive: \(pictures.count) decoded off the main thread in \(ms) ms, "
                        + "taken \(taken.sorted().joined(separator: " "))")
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
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
                self?.archivePictures()
                self?.cachePurgeTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.cachePurgeTimer = timer
    }

    // MARK: - Steps

    /// NSMenu puts the new rows into its window on its own pass, right after the rebuild returns. A timer
    /// with no delay comes after that pass; if the rows are not in the window yet, it looks again.
    private func schedulePlacement(of key: String, attempt: Int) {
        self.placeTimer?.invalidate()
        let timer = Timer(timeInterval: attempt == 0 ? 0 : 1.0 / 120.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeRows(key: key, attempt: attempt) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.placeTimer = timer
    }

    /// The first row under the provider row is in the window. (Rows further down may never be: the menu
    /// only puts the rows it shows into its table.)
    private static func rowsArePlaced(_ menu: NSMenu, in window: NSWindow) -> Bool {
        guard let first = menu.items.dropFirst().first(where: { !$0.isHidden && $0.view != nil }) else { return true }
        return first.view?.window === window
    }

    /// The rows of `key` are in the window: when it is the target page they take their place in the
    /// strip at once, as the real rows (a picture of them would only cost time, and it draws the dimmed
    /// text brighter than the menu does). A strip that waited for them sets off now.
    private func placeRows(key: String, attempt: Int) {
        self.placeTimer = nil
        guard self.phase == .active, let menu = self.menu, let window = self.menuWindow,
              let content = window.contentView
        else { return }
        if attempt < 12, !Self.rowsArePlaced(menu, in: window) {
            self.schedulePlacement(of: key, attempt: attempt + 1)
            return
        }
        // The menu's table makes the layers of its rows when it lays out and draws; the rows cannot be
        // told to follow the strip before that.
        content.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.hideIdleScrollArrows(
            in: content,
            finalHeight: self.heightTimer == nil ? content.bounds.height : self.heightTo)
        self.layoutClip(height: content.bounds.height - self.boundary)
        if key == self.targetKey, let slot = self.slots.first(where: { $0.key == key }) {
            if self.waitsForRows {
                self.waitsForRows = false
                self.shownIndex = slot.index
                self.shownKey = key
                self.cancelTimers()
                let duration = self.duration
                self.slideStrip(toIndex: slot.index, duration: duration)
                self.scheduleArrival(after: duration)
            }
            self.revealRealRows(of: slot, pictureIsCurrent: false)
            self.targetIsFresh = true
        } else {
            self.setRowsMasked(true)
        }
        CATransaction.commit()
        CATransaction.flush()
        self.log("rows placed \(key) height=\(Int(self.heightTimer == nil ? content.bounds.height : self.heightTo))"
            + (attempt > 0 ? " after \(attempt) more looks" : ""))
        self.settleIfReady()
    }

    /// A picture of the window as it is, at the height it is going to. Only with the real rows showing.
    /// A row of the menu is highlighted (under the pointer, or the row whose detail panel is open).
    private var rowIsHighlighted: Bool {
        self.menu?.highlightedItem != nil
    }

    private func takePicture() -> Snapshot? {
        guard let menu = self.menu, let window = self.menuWindow else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // The window may be between two heights; the picture is taken at the final one. Nothing is
        // committed in between.
        let shown = self.shownHeight
        let resizing = self.heightTimer != nil
        if resizing { self.setWindowHeight(self.heightTo, display: false) }
        let picture = Self.snapshot(
            window,
            views: self.boundaryViews?(menu) ?? (nil, nil),
            excluding: self.rootLayer)
        if resizing { self.setWindowHeight(shown, display: false) }
        return picture
    }

    /// The page shown by the real rows gets its picture, for the moment the rows are taken away.
    private func takePictureOfRealRows() {
        guard let key = self.realKey, !self.realPictureIsCurrent, let picture = self.takePicture() else { return }
        // With a row highlighted the picture is right for the page as it leaves but wrong for the next
        // visit, which would slide in with that row lit: the cache keeps the page's picture at rest.
        if !self.rowIsHighlighted {
            self.cache[key] = picture
        }
        self.realPictureIsCurrent = true
        guard let slot = self.slots.first(where: { $0.key == key }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.fill(slot, from: picture)
        CATransaction.commit()
        self.log("picture \(key) before its rows go")
    }

    /// A page that came in as real rows has no picture of its own yet, or an old one. It is taken once
    /// the page has rested for a moment, so the next visit has it from the first frame.
    private func schedulePicture(of key: String) {
        self.pictureTimer?.invalidate()
        self.pictureTimer = nil
        if let picture = self.cache[key], CACurrentMediaTime() - picture.taken < Self.pictureFreshness { return }
        let timer = Timer(timeInterval: Self.pictureDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pictureTimer = nil
                guard self.phase == .idle, self.currentKey?() == key, self.menuWindow?.isVisible == true
                else { return }
                // A lit row would come back on the next visit: try again once the pointer has left it.
                if self.rowIsHighlighted {
                    self.schedulePicture(of: key)
                    return
                }
                guard let picture = self.takePicture() else { return }
                self.cache[key] = picture
                self.log("picture \(key) at rest")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.pictureTimer = timer
    }

    /// The strip is at rest on the target page and the real rows show the same page: swap them.
    private func settleIfReady() {
        guard self.phase == .active, self.stripHasArrived, self.targetIsFresh else { return }
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
        self.schedulePicture(of: self.targetKey)
    }

    private func abort() {
        self.finishHeight()
        self.cancelTimers()
        self.placeTimer?.invalidate()
        self.placeTimer = nil
        self.pictureTimer?.invalidate()
        self.pictureTimer = nil
        self.waitsForRows = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.setRowsMasked(false)
        for layer in self.lowerRowLayers() {
            layer.removeAnimation(forKey: Self.followKey)
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
        self.fill(slot, from: snapshot)
        // From rest the page is still the real rows; its copy waits, unseen, for the rebuild.
        slot.layer.isHidden = !showCopy
        self.targetIndex = 0
        self.shownIndex = 0
        self.shownKey = key
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

    private func fill(_ slot: Slot, from snapshot: Snapshot?) {
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
        slot.hasImage = true
    }

    private static let followKey = "lemelsonFollow"
    /// Visible on the first frame, halfway in about 55 ms, then a soft landing.
    private static var slideTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.3, 0.4, 0.15, 1)
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
    private func revealRealRows(of slot: Slot, pictureIsCurrent: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slot.layer.isHidden = true
        self.setRowsMasked(false)
        let rest = self.width / 2 - CGFloat(slot.index) * self.width
        let moving = CACurrentMediaTime() < self.slideStart + self.slideDuration
        for layer in self.lowerRowLayers() {
            layer.removeAnimation(forKey: Self.followKey)
            if moving || abs(self.slideTo - rest) > 0.5 {
                let follow = CABasicAnimation(keyPath: "position.x")
                follow.isAdditive = true
                follow.fromValue = self.slideFrom - rest
                follow.toValue = self.slideTo - rest
                follow.duration = self.slideDuration
                follow.timingFunction = Self.slideTiming
                follow.beginTime = layer.convertTime(self.slideStart, from: nil)
                // A page that leaves stays out until its rows are replaced.
                follow.fillMode = .forwards
                follow.isRemovedOnCompletion = abs(self.slideTo - rest) <= 0.5
                layer.add(follow, forKey: Self.followKey)
            }
        }
        CATransaction.commit()
        self.realKey = slot.key
        self.realPictureIsCurrent = pictureIsCurrent
        self.log("real rows \(slot.key) \(moving ? "slide in" : "in place")")
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
        }
        CATransaction.commit()
        self.realKey = nil
    }

    /// Moves the strip to the page at `index` from wherever it is now.
    private func slideStrip(toIndex index: Int, duration: CFTimeInterval) {
        let target = self.width / 2 - CGFloat(index) * self.width
        let current = self.stripLayer.presentation()?.position.x ?? self.stripLayer.position.x
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = current
        slide.toValue = target
        slide.duration = duration
        slide.timingFunction = Self.slideTiming
        self.slideStart = CACurrentMediaTime()
        self.slideFrom = current
        self.slideTo = target
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
        let started = CACurrentMediaTime()
        if self.cache[key] == nil, let packed = self.archive[key], abs(packed.size.width - width) < 0.5,
           let image = Self.image(png: packed.png)
        {
            // Asked for before the background decoding of `menuWillOpen` got to it.
            self.log("archive: \(key) decoded on the main thread in \(Int((CACurrentMediaTime() - started) * 1000)) ms")
            self.cache[key] = Snapshot(
                image: image,
                size: packed.size,
                providerBoundary: packed.providerBoundary,
                modeBoundary: packed.modeBoundary,
                archived: true)
        }
        guard let snapshot = self.cache[key], abs(snapshot.size.width - width) < 0.5 else { return nil }
        return snapshot
    }

    /// Ten minutes after the menu closed the pictures stop being bitmaps (a few megabytes each) and stay
    /// as PNG data, so a page that was seen once has a picture for as long as the app runs.
    private func archivePictures() {
        let fresh = self.cache.filter { !$0.value.archived }
        self.cache.removeAll()
        guard !fresh.isEmpty else { return }
        let appearance = self.cacheAppearance
        DispatchQueue.global(qos: .utility).async {
            var packed: [String: Archived] = [:]
            for (key, picture) in fresh {
                guard let png = Self.png(picture.image) else { continue }
                packed[key] = Archived(
                    png: png,
                    size: picture.size,
                    providerBoundary: picture.providerBoundary,
                    modeBoundary: picture.modeBoundary)
            }
            let result = packed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let transition = LemelsonPageTransition.shared
                    guard transition.cacheAppearance == appearance else { return }
                    transition.archive.merge(result) { _, new in new }
                    #if DEBUG
                    let bytes = transition.archive.values.reduce(0) { $0 + $1.png.count }
                    StatusItemController.lemelsonLog.notice("transition: archive: \(result.count) pictures compressed, \(transition.archive.count) kept, \(bytes / 1024) KB")
                    #endif
                }
            }
        }
    }

    private nonisolated static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private nonisolated static func image(png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
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
            // The page at rest changed height by itself: stock rows below a page (Claude Spend's Cost) add their cost section a
            // moment after the page is shown (657 -> 1077 pt). Its picture has the old height and the next
            // visit would slide it in and then jump, so it is taken again once the page rests. Taking a
            // picture draws into a bitmap only: nothing changes on screen.
            if abs(final - self.shownHeight) > 0.5, let key = self.currentKey?(), let picture = self.cache[key],
               abs(picture.size.height - (window.contentView?.bounds.height ?? final)) > 0.5
            {
                self.cache[key]?.taken = 0
                self.log("height \(Int(self.shownHeight)) -> \(Int(final)) at rest, picture \(key) again")
                self.schedulePicture(of: key)
            }
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
            self.hideIdleScrollArrows(in: content, finalHeight: self.heightTo)
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
        if let content = window.contentView {
            self.hideIdleScrollArrows(in: content, finalHeight: self.scrollHeight == nil ? height : self.heightTo)
        }
        self.applyingHeight = false
        self.shownHeight = height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.layoutClip(height: height - self.boundary)
        CATransaction.commit()
    }

    /// NSMenu decides about its scroll arrows after its own resize, when this transition has already put
    /// the window back to the old height: a page that grows to a height it fits in would keep the
    /// "more below" arrow over its last row for good. While the rows fit the height the window is going
    /// to, the arrows stay hidden; NSMenu shows them again itself on a page that really scrolls.
    /// NSMenu adds the arrow views anew in the middle of each rebuild, after its resize: until the rebuild
    /// returns (the first step of the height timer) nothing here can reach them.
    private func hideIdleScrollArrows(in content: NSView, finalHeight: CGFloat) {
        guard let scroll = content.subviews.lazy.compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView, document.frame.height <= finalHeight + 0.5
        else { return }
        for view in content.subviews where type(of: view) == NSImageView.self && !view.isHidden {
            view.isHidden = true
        }
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
            modeBoundary: distance(views.modeRow),
            taken: CACurrentMediaTime())
    }
}

extension MenuRowContainerView {
    /// The deepest visible, enabled AppKit control under `point` (in the row's coordinates; `root` is its
    /// hosting view),
    /// searched through the hosting view's subviews: SwiftUI places a representable's view there but does not
    /// return it from its hit test.
    static func lemelsonControl(at point: NSPoint, in root: NSView) -> NSControl? {
        guard let row = root.superview else { return nil }
        func search(_ view: NSView) -> NSControl? {
            for sub in view.subviews.reversed() where !sub.isHidden && sub.alphaValue > 0 {
                guard sub.convert(sub.bounds, to: row).contains(point) else { continue }
                if let deeper = search(sub) { return deeper }
                if let control = sub as? NSControl, control.isEnabled { return control }
            }
            return nil
        }
        return search(root)
    }
}
