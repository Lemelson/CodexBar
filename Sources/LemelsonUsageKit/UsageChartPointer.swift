import AppKit
import SwiftUI

// MARK: - Pointer on the per-day spend charts: hover, drag to zoom, double-click to zoom out

/// Routes the pointer over the per-day spend charts inside the menu.
///
/// While an `NSMenu` is open its tracking loop reads every event: a press would close the menu and a drag
/// never reaches a SwiftUI gesture. The app's event filter hands each event here first (`routeTrackedEvent`,
/// before `UsageHoverPanelController.routeTrackedEvent`, so a drag that crosses into the day panel stays a
/// drag). A press on a chart's plot starts a drag session and is kept from the menu; moving 4 pt or into the
/// next day turns it into a span (`UsageDayFocus.dragRange`), and the release zooms into it when it covers at
/// least two days. A plain click does nothing; a double click zooms out. Hovering shows the day panel left of
/// the menu (`UsageDayDetailPanelView`, registered with the hover panel under the chart's `panelKey`).
///
/// Charts register while they are the visible layer of their page (`UsageChartAnchor`); hidden layers never do.
/// Each anchor also has a tracking area, so hovering works even where no event filter feeds this router.
@MainActor
public final class UsageChartPointer {
    public static let shared = UsageChartPointer()

    /// What a registered chart answers.
    public struct Handlers {
        /// The day panel's hover-panel key (`UsageDayDetailCatalog.panelKey(for:)`).
        public var panelKey: String
        /// The plot area in the anchor view's coordinates (origin top left).
        public var plotBoundsInView: @MainActor () -> CGRect
        /// The day under an x position in the anchor view's coordinates; nil outside the plot's days.
        public var dayKey: @MainActor (_ localX: CGFloat) -> String?
        /// A drag over at least two days was released.
        public var onDragEnded: @MainActor (_ range: UsageSpendRange) -> Void
        public var onDoubleClick: @MainActor () -> Void

        public init(
            panelKey: String,
            plotBoundsInView: @escaping @MainActor () -> CGRect,
            dayKey: @escaping @MainActor (_ localX: CGFloat) -> String?,
            onDragEnded: @escaping @MainActor (_ range: UsageSpendRange) -> Void,
            onDoubleClick: @escaping @MainActor () -> Void)
        {
            self.panelKey = panelKey
            self.plotBoundsInView = plotBoundsInView
            self.dayKey = dayKey
            self.onDragEnded = onDragEnded
            self.onDoubleClick = onDoubleClick
        }
    }

    private final class Registration {
        let chartID: String
        weak var view: NSView?
        var handlers: Handlers

        init(chartID: String, view: NSView, handlers: Handlers) {
            self.chartID = chartID
            self.view = view
            self.handlers = handlers
        }
    }

    /// A registered chart where it is now.
    @MainActor
    private struct Placed {
        let registration: Registration
        let view: NSView
        let window: NSWindow
        /// The plot, in screen coordinates.
        let plot: NSRect

        /// From the menu's left edge to the plot's right edge, the plot's height: the pointer may cross it on
        /// its way to the day panel without the panel closing or the day changing.
        var band: NSRect {
            NSRect(
                x: self.window.frame.minX,
                y: self.plot.minY,
                width: max(0, self.plot.maxX - self.window.frame.minX),
                height: self.plot.height)
        }

        func local(_ screenPoint: NSPoint) -> NSPoint {
            self.view.convert(self.window.convertPoint(fromScreen: screenPoint), from: nil)
        }
    }

    private struct Drag {
        let chartID: String
        let view: ObjectIdentifier
        let anchorDay: String
        var currentDay: String
        let downX: CGFloat
        var thresholdCrossed: Bool
    }

    private struct Hovered {
        let chartID: String
        let band: NSRect
        let panelKey: String
    }

    /// Movement (in points) after which a press becomes a drag even inside one day.
    static let dragThreshold: CGFloat = 4

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var drag: Drag?
    private var hovered: Hovered?
    /// Swallows the release paired with a double-click press so NSMenu never treats it as a click.
    private var swallowNextMouseUp = false

    /// Self-test log hook.
    public var trace: ((String) -> Void)?

    public init() {}

    /// True while a press on a chart has turned into a drag.
    public var isDragging: Bool {
        self.drag?.thresholdCrossed == true
    }

    /// True between a press on a chart and its release (or cancel).
    public var hasActiveDrag: Bool {
        self.drag != nil
    }

    // MARK: Registration

    /// Registers `view` (or refreshes its handlers). Several views may share a chart id; the visible one answers.
    public func register(chartID: String, view: NSView, handlers: Handlers) {
        let id = ObjectIdentifier(view)
        if let existing = self.registrations[id], existing.chartID == chartID, existing.view === view {
            existing.handlers = handlers
            return
        }
        self.registrations[id] = Registration(chartID: chartID, view: view, handlers: handlers)
    }

    public func unregister(view: NSView) {
        let id = ObjectIdentifier(view)
        guard self.registrations.removeValue(forKey: id) != nil else { return }
        if self.drag?.view == id {
            self.cancelDrag()
        }
    }

    // MARK: Events

    /// Called by the app's event filter for every event the menu's tracking loop dequeues, before the hover
    /// panel's router. Returns true when the event was used and must not reach the menu.
    public func routeTrackedEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            self.swallowNextMouseUp = false
            if self.drag != nil {
                return true
            }
            let point = UsageHoverPanelController.screenLocation(of: event)
            guard let placed = self.placed(at: point) else { return false }
            let local = placed.local(point)
            if event.clickCount >= 2 {
                self.swallowNextMouseUp = true
                self.hovered = nil
                UsageDayFocus.shared.clear()
                if UsageHoverPanelController.shared.visibleKey == placed.registration.handlers.panelKey {
                    UsageHoverPanelController.shared.hide(animated: true)
                }
                self.trace?("chart \(placed.registration.chartID) double click")
                placed.registration.handlers.onDoubleClick()
                return true
            }
            guard let day = placed.registration.handlers.dayKey(local.x) else { return false }
            self.drag = Drag(
                chartID: placed.registration.chartID,
                view: ObjectIdentifier(placed.view),
                anchorDay: day,
                currentDay: day,
                downX: local.x,
                thresholdCrossed: false)
            self.trace?("chart \(placed.registration.chartID) press \(day)")
            UsageDayFocus.shared.hover(chartID: placed.registration.chartID, dayKey: day)
            self.showPanel(for: placed)
            return true
        case .leftMouseDragged, .mouseMoved:
            let point = UsageHoverPanelController.screenLocation(of: event)
            guard self.drag != nil else {
                if event.type == .mouseMoved {
                    self.pointerMoved(to: point)
                }
                return false
            }
            self.continueDrag(at: point)
            return true
        case .leftMouseUp:
            if self.swallowNextMouseUp {
                self.swallowNextMouseUp = false
                return true
            }
            guard self.drag != nil else { return false }
            self.endDrag(at: UsageHoverPanelController.screenLocation(of: event))
            return true
        case .rightMouseDown, .otherMouseDown:
            guard self.drag != nil else { return false }
            self.cancelDrag()
            return true
        case .keyDown:
            guard self.drag != nil else { return false }
            // Escape cancels; any other key is kept from the menu (an arrow would turn the page mid-drag).
            if event.keyCode == 53 {
                self.cancelDrag()
            }
            return true
        case .scrollWheel, .rightMouseUp, .otherMouseUp, .rightMouseDragged, .otherMouseDragged,
             .mouseEntered, .mouseExited:
            // Mid-drag a swipe must not page and the menu must not see the pointer leave its row.
            return self.drag != nil
        default:
            return false
        }
    }

    /// The pointer is at `screenPoint` with no button down: from the event filter or an anchor's tracking area.
    public func pointerMoved(to screenPoint: NSPoint) {
        guard self.drag == nil else { return }
        let focus = UsageDayFocus.shared
        if let placed = self.placed(at: screenPoint) {
            let day = placed.registration.handlers.dayKey(placed.local(screenPoint).x)
            focus.hover(chartID: placed.registration.chartID, dayKey: day)
            self.hovered = Hovered(
                chartID: placed.registration.chartID,
                band: placed.band,
                panelKey: placed.registration.handlers.panelKey)
            if day != nil {
                self.showPanel(for: placed)
            }
            return
        }
        guard let hovered = self.hovered else { return }
        let panel = UsageHoverPanelController.shared
        let onPanel = panel.visibleKey == hovered.panelKey
            && panel.cardScreenRect.insetBy(dx: -4, dy: -4).contains(screenPoint)
        // On the way to the day panel, or over it: the day stays, so it can be read.
        if onPanel || hovered.band.contains(screenPoint) {
            return
        }
        self.hovered = nil
        if focus.activeChartID == hovered.chartID {
            focus.clear()
        }
        if panel.visibleKey == hovered.panelKey {
            panel.pointerLeftRows()
        }
    }

    /// Cancels a drag and forgets the hovered day: on a page change and when the menu closes.
    public func cancelActiveInteraction() {
        self.drag = nil
        self.hovered = nil
        self.swallowNextMouseUp = false
        UsageDayFocus.shared.clear()
    }

    /// True when `screenPoint` is over a visible chart plot or over the corridor leading to its day panel.
    public func isPointerOverChartOrBand(at screenPoint: NSPoint) -> Bool {
        if self.placed(at: screenPoint) != nil {
            return true
        }
        if let hovered = self.hovered, hovered.band.contains(screenPoint) {
            return true
        }
        return false
    }

    // MARK: Self-test

    /// The plot of the visible registered chart, in screen coordinates.
    public func activeChartPlotScreenRect() -> NSRect? {
        self.visiblePlacements().first?.plot
    }

    /// The plot of the visible chart with this id, in screen coordinates.
    public func plotScreenRect(chartID: String) -> NSRect? {
        self.visiblePlacements().first { $0.registration.chartID == chartID }?.plot
    }

    /// Ids of the charts registered now (visible or not).
    public var registeredChartIDs: [String] {
        self.registrations.values.map(\.chartID).sorted()
    }

    // MARK: Drag

    private func continueDrag(at point: NSPoint) {
        guard var drag = self.drag else { return }
        guard let registration = self.registrations[drag.view], let placed = self.place(registration) else {
            self.cancelDrag()
            return
        }
        let local = placed.local(point)
        let plot = registration.handlers.plotBoundsInView()
        let x = min(max(local.x, plot.minX), max(plot.minX, plot.maxX - 0.5))
        let day = registration.handlers.dayKey(x) ?? drag.currentDay
        drag.currentDay = day
        if !drag.thresholdCrossed, abs(local.x - drag.downX) >= Self.dragThreshold || day != drag.anchorDay {
            drag.thresholdCrossed = true
            self.trace?("chart \(drag.chartID) drag from \(drag.anchorDay)")
        }
        self.drag = drag
        if drag.thresholdCrossed {
            UsageDayFocus.shared.drag(
                chartID: drag.chartID,
                dayKey: day,
                range: UsageSpendRange(startDay: drag.anchorDay, endDay: day))
        } else {
            UsageDayFocus.shared.hover(chartID: drag.chartID, dayKey: day)
        }
        self.hovered = Hovered(chartID: drag.chartID, band: placed.band, panelKey: registration.handlers.panelKey)
        self.showPanel(for: placed)
    }

    private func endDrag(at point: NSPoint) {
        self.continueDrag(at: point)
        guard let drag = self.drag else { return }
        self.drag = nil
        if drag.thresholdCrossed, let range = UsageSpendRange(startDay: drag.anchorDay, endDay: drag.currentDay),
           range.dayCount >= 2, let registration = self.registrations[drag.view]
        {
            self.trace?("chart \(drag.chartID) zoom \(range.startDay)...\(range.endDay)")
            registration.handlers.onDragEnded(range)
            // After zooming, the chart's domain changed and the old edge bar is no longer under the pointer.
            self.hovered = nil
            UsageDayFocus.shared.clear()
            if UsageHoverPanelController.shared.visibleKey == registration.handlers.panelKey {
                UsageHoverPanelController.shared.hide(animated: true)
            }
            return
        }
        UsageDayFocus.shared.hover(chartID: drag.chartID, dayKey: drag.currentDay)
    }

    private func cancelDrag() {
        guard let drag = self.drag else { return }
        self.drag = nil
        self.trace?("chart \(drag.chartID) drag cancelled")
        UsageDayFocus.shared.hover(chartID: drag.chartID, dayKey: drag.currentDay)
    }

    // MARK: Geometry

    private func place(_ registration: Registration) -> Placed? {
        guard let view = registration.view, let window = view.window, window.isVisible else { return nil }
        let plot = registration.handlers.plotBoundsInView()
        guard plot.width > 1, plot.height > 1 else { return nil }
        let screen = window.convertToScreen(view.convert(plot, to: nil))
        return Placed(registration: registration, view: view, window: window, plot: screen)
    }

    private func visiblePlacements() -> [Placed] {
        self.registrations = self.registrations.filter { $0.value.view != nil }
        return self.registrations.values.compactMap { self.place($0) }
    }

    private func placed(at point: NSPoint) -> Placed? {
        self.visiblePlacements().first { $0.plot.contains(point) }
    }

    private func showPanel(for placed: Placed) {
        let panel = UsageHoverPanelController.shared
        let key = placed.registration.handlers.panelKey
        guard panel.hasEntry(key) else { return }
        panel.showIfNeededOrKeep(
            key: key,
            rowRect: placed.band,
            menuFrame: placed.window.frame,
            screen: placed.window.screen,
            appearance: placed.window.effectiveAppearance)
    }
}

// MARK: - Anchor: a chart's plot as the router sees it

/// Laid over a chart while it is the visible layer of its page: registers the chart with
/// `UsageChartPointer` and reports hovering through a tracking area. Never takes a click.
struct UsageChartAnchor: NSViewRepresentable {
    let chartID: String
    let handlers: UsageChartPointer.Handlers

    func makeNSView(context _: Context) -> UsageChartAnchorView {
        let view = UsageChartAnchorView()
        view.chartID = self.chartID
        view.handlers = self.handlers
        view.syncRegistration()
        return view
    }

    func updateNSView(_ view: UsageChartAnchorView, context _: Context) {
        view.chartID = self.chartID
        view.handlers = self.handlers
        view.syncRegistration()
    }

    static func dismantleNSView(_ view: UsageChartAnchorView, coordinator _: ()) {
        view.handlers = nil
        UsageChartPointer.shared.unregister(view: view)
    }
}

final class UsageChartAnchorView: NSView {
    var chartID = ""
    var handlers: UsageChartPointer.Handlers?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool {
        true
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func syncRegistration() {
        if self.window != nil, let handlers = self.handlers, !self.chartID.isEmpty {
            UsageChartPointer.shared.register(chartID: self.chartID, view: self, handlers: handlers)
        } else {
            UsageChartPointer.shared.unregister(view: self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.window?.acceptsMouseMovedEvents = true
        self.syncRegistration()
        self.updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        // A menu window is never key, so tracking is always on.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        UsageChartPointer.shared.pointerMoved(to: UsageHoverPanelController.screenLocation(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        UsageChartPointer.shared.pointerMoved(to: UsageHoverPanelController.screenLocation(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        UsageChartPointer.shared.pointerMoved(to: UsageHoverPanelController.screenLocation(of: event))
    }
}
