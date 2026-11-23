import AppKit
import QuartzCore
import SwiftUI

// The detail panel that follows the pointer over the limit rows.
//
// A native NSMenu submenu waits for the pointer to settle, closes the previous submenu and opens the
// next one from scratch. This panel is one window that stays up while the pointer moves between rows:
// it appears at once, slides to the hovered row and cross-fades its content. Every row's content is
// rendered ahead of time, so nothing is computed at hover time.
//
// The panel never takes mouse events: it only shows things. Rows that need controls inside their
// detail view keep using a native submenu.

/// How the panel moves between rows. Can be switched while the app runs:
/// `defaults write <bundle id> lemelsonHoverStyle instant|morph|spring`
public enum UsageHoverStyle: String, CaseIterable, Sendable {
    /// No animation: the panel jumps and the content is swapped.
    case instant
    /// Short ease-out slide with a cross-fade.
    case morph
    /// Slightly longer slide with a small overshoot.
    case spring

    public static let defaultsKey = "lemelsonHoverStyle"

    public static var current: UsageHoverStyle {
        UserDefaults.standard.string(forKey: self.defaultsKey).flatMap(UsageHoverStyle.init(rawValue:)) ?? .morph
    }

    var moveDuration: Double {
        switch self {
        case .instant: 0
        case .morph: 0.16
        case .spring: 0.42
        }
    }

    var fadeDuration: Double {
        switch self {
        case .instant: 0
        case .morph: 0.09
        case .spring: 0.12
        }
    }

    /// Progress of the move at `time` seconds, 0...1 (the spring goes slightly past 1).
    func progress(at time: Double) -> Double {
        switch self {
        case .instant:
            return 1
        case .morph:
            let t = min(1, max(0, time / self.moveDuration))
            return 1 - pow(1 - t, 3)
        case .spring:
            guard time < self.moveDuration else { return 1 }
            let omega = 2 * Double.pi / 0.30
            let zeta = 0.70
            let damped = omega * (1 - zeta * zeta).squareRoot()
            let envelope = exp(-zeta * omega * time)
            return 1 - envelope * (cos(damped * time) + (zeta * omega / damped) * sin(damped * time))
        }
    }
}

/// Outline of the panel: joined to the menu as one body, or a separate card next to it.
/// `defaults write <bundle id> lemelsonHoverShape fused|card`
public enum UsageHoverShape: String, CaseIterable, Sendable {
    case fused
    case card

    public static let defaultsKey = "lemelsonHoverShape"

    public static var current: UsageHoverShape {
        UserDefaults.standard.string(forKey: self.defaultsKey).flatMap(UsageHoverShape.init(rawValue:)) ?? .fused
    }
}

/// Geometry of the panel outline. The view that draws it is taller than the panel body by `fillet`
/// at the top and at the bottom: the concave corners that join the body to the menu live there.
enum UsageHoverOutline {
    static let radius: CGFloat = 13
    static let fillet: CGFloat = 11

    /// Closed outline in a `size` box with the origin at the bottom left.
    static func closed(size: CGSize, topFillet: Bool, bottomFillet: Bool) -> CGPath {
        let path = CGMutablePath()
        self.addOutline(to: path, size: size, topFillet: topFillet, bottomFillet: bottomFillet, rightEdge: true)
        path.closeSubpath()
        return path
    }

    /// The same outline without the edge shared with the menu, for the hairline border.
    static func border(size: CGSize, topFillet: Bool, bottomFillet: Bool, rightEdge: Bool) -> CGPath {
        let path = CGMutablePath()
        self.addOutline(
            to: path,
            size: size,
            topFillet: topFillet,
            bottomFillet: bottomFillet,
            rightEdge: rightEdge)
        return path
    }

    private static func addOutline(
        to path: CGMutablePath,
        size: CGSize,
        topFillet: Bool,
        bottomFillet: Bool,
        rightEdge: Bool)
    {
        let w = size.width
        let h = size.height
        let r = self.radius
        let f = self.fillet
        let top = h - f
        let bottom = f
        // Starts at the right end of the top edge and runs counter-clockwise, so the shared edge is last.
        if topFillet {
            path.move(to: CGPoint(x: w, y: h))
            path.addArc(
                center: CGPoint(x: w - f, y: h), radius: f, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        } else {
            path.move(to: CGPoint(x: w, y: top - r))
            path.addArc(
                center: CGPoint(x: w - r, y: top - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        }
        path.addLine(to: CGPoint(x: r, y: top))
        path.addArc(
            center: CGPoint(x: r, y: top - r), radius: r, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: bottom + r))
        path.addArc(
            center: CGPoint(x: r, y: bottom + r), radius: r, startAngle: .pi, endAngle: 1.5 * .pi, clockwise: false)
        if bottomFillet {
            path.addLine(to: CGPoint(x: w - f, y: bottom))
            path.addArc(
                center: CGPoint(x: w - f, y: 0), radius: f, startAngle: .pi / 2, endAngle: 0, clockwise: true)
        } else {
            path.addLine(to: CGPoint(x: w - r, y: bottom))
            path.addArc(
                center: CGPoint(x: w - r, y: bottom + r),
                radius: r,
                startAngle: -.pi / 2,
                endAngle: 0,
                clockwise: false)
        }
        if rightEdge {
            path.addLine(to: CGPoint(x: w, y: topFillet ? h : top - r))
        }
    }

    /// Stretchable mask for the blurred background: the corners keep their size at any panel size.
    static func mask(topFillet: Bool, bottomFillet: Bool) -> NSImage {
        let side = max(self.radius, self.fillet)
        let size = CGSize(width: self.radius + side + 2, height: 2 * (self.fillet + self.radius) + 2)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(self.closed(size: size, topFillet: topFillet, bottomFillet: bottomFillet))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: self.fillet + self.radius,
            left: self.radius,
            bottom: self.fillet + self.radius,
            right: side)
        image.resizingMode = .stretch
        return image
    }
}

@MainActor
public final class UsageHoverPanelController: NSObject {
    public static let shared = UsageHoverPanelController()

    public static let panelWidth: CGFloat = 340

    /// Seconds the panel stays after the pointer leaves the rows, so crossing an account header or
    /// moving onto the panel itself does not close it.
    private static let grace: TimeInterval = 0.22
    private static let screenMargin: CGFloat = 8
    private static let shadowMargin: CGFloat = 44

    private struct Placement: Equatable {
        var bottom: CGFloat
        var height: CGFloat
    }

    private var builders: [String: () -> AnyView] = [:]
    private var order: [String] = []
    private var hosts: [String: NSHostingView<AnyView>] = [:]
    private var heights: [String: CGFloat] = [:]
    private var stale: Set<String> = []
    private var warmTimer: Timer?
    private var menuOpen = false

    private var window: NSPanel?
    private let shadowView = NSView()
    private let effectView = NSVisualEffectView()
    private let borderView = NSView()
    private let borderLayer = CAShapeLayer()
    /// Brings the blurred background to the tone of the system menu, so the joint does not show.
    private let tintLayer = CAShapeLayer()
    private let clipView = NSView()
    private var displayLink: CADisplayLink?

    private var currentKey: String?
    private var anchorRow = NSRect.zero
    private var menuFrame = NSRect.zero
    private var cardX: CGFloat = 0
    private var topFillet = false
    private var bottomFillet = false
    private var shape = UsageHoverShape.fused
    private var maskSignature = ""

    private var from = Placement(bottom: 0, height: 0)
    private var to = Placement(bottom: 0, height: 0)
    private var shown = Placement(bottom: 0, height: 0)
    private var moveStarted: CFTimeInterval = 0
    private var moveStyle = UsageHoverStyle.morph
    private var moving = false

    private var alpha: CGFloat = 0
    private var alphaTarget: CGFloat = 0
    private var lastTick: CFTimeInterval = 0

    private var graceTimer: Timer?
    private var pointerLeftAt: Date?

    /// True while the panel is on screen (or fading in).
    public var isVisible: Bool {
        self.alphaTarget > 0
    }

    // MARK: - Content

    /// Replaces the set of detail views. Views that are already rendered are refreshed in place, so a
    /// panel that is on screen only changes its numbers.
    public func setEntries(_ entries: [(key: String, build: () -> AnyView)]) {
        self.builders = Dictionary(entries.map { ($0.key, $0.build) }, uniquingKeysWith: { _, last in last })
        self.order = entries.map(\.key)
        for key in Array(self.hosts.keys) where self.builders[key] == nil {
            self.hosts.removeValue(forKey: key)?.removeFromSuperview()
            self.heights.removeValue(forKey: key)
        }
        self.stale = Set(self.hosts.keys)
        if let key = self.currentKey, self.isVisible {
            if self.builders[key] == nil {
                self.hide(animated: false)
            } else {
                self.prepareHost(for: key)
                self.retarget(animated: true)
            }
        }
        self.scheduleWarmup()
    }

    public func menuDidOpen() {
        self.menuOpen = true
        self.scheduleWarmup()
    }

    public func menuDidClose() {
        self.menuOpen = false
        self.warmTimer?.invalidate()
        self.warmTimer = nil
        self.hide(animated: false)
    }

    /// Renders the detail views one by one while the menu is open, so hovering never waits for SwiftUI.
    private func scheduleWarmup() {
        guard self.menuOpen, self.warmTimer == nil else { return }
        guard self.order.contains(where: { self.hosts[$0] == nil || self.stale.contains($0) }) else { return }
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
              let key = self.order.first(where: { self.hosts[$0] == nil || self.stale.contains($0) })
        else {
            self.warmTimer?.invalidate()
            self.warmTimer = nil
            return
        }
        self.prepareHost(for: key)
    }

    @discardableResult
    private func prepareHost(for key: String) -> NSHostingView<AnyView>? {
        guard let build = self.builders[key] else { return nil }
        self.ensureWindow()
        let host: NSHostingView<AnyView>
        if let existing = self.hosts[key] {
            guard self.stale.contains(key) else { return existing }
            existing.rootView = build()
            host = existing
        } else {
            host = NSHostingView(rootView: build())
            host.wantsLayer = true
            host.layer?.opacity = 0
            self.clipView.addSubview(host)
            self.hosts[key] = host
        }
        self.stale.remove(key)
        let height = ceil(host.fittingSize.height)
        self.heights[key] = height
        host.frame = NSRect(
            x: 0,
            y: self.clipView.bounds.height - height,
            width: Self.panelWidth,
            height: height)
        // SwiftUI commits a fresh hosting view a frame late; laying it out now makes the first show complete.
        host.layoutSubtreeIfNeeded()
        return host
    }

    // MARK: - Showing

    /// The pointer is over the row `key`. `rowRect` and `menuFrame` are in screen coordinates.
    public func show(key: String, rowRect: NSRect, menuFrame: NSRect, screen: NSScreen?, appearance: NSAppearance?) {
        guard self.builders[key] != nil, let host = self.prepareHost(for: key) else {
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

        if menuFrame != self.menuFrame || shape != self.shape || !wasVisible {
            self.menuFrame = menuFrame
            self.shape = shape
            // Fused: cover the menu's own hairline border. Card: leave a gap.
            let overlap: CGFloat = shape == .fused ? 2 : -6
            let right = menuFrame.minX + overlap
            let frame = NSRect(
                x: right - Self.panelWidth - Self.shadowMargin,
                y: visible.minY,
                width: Self.panelWidth + Self.shadowMargin,
                height: visible.height)
            window.setFrame(frame, display: false)
            self.cardX = Self.shadowMargin
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
        self.updateFillets(visible: visible)

        for (other, view) in self.hosts where other != key {
            self.fade(view, to: 0, duration: wasVisible ? style.fadeDuration : 0)
        }
        self.fade(host, to: 1, duration: wasVisible ? style.fadeDuration : 0)

        self.alphaTarget = 1
        if !wasVisible {
            self.alpha = style == .instant ? 1 : 0
            window.alphaValue = self.alpha
            window.orderFront(nil)
        }
        self.applyLayout()
        self.startTicking()
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
        guard self.isVisible || self.alpha > 0 else { return }
        self.alphaTarget = 0
        if !animated || UsageHoverStyle.current == .instant {
            self.alpha = 0
            self.finishHide()
        } else {
            self.startTicking()
        }
    }

    private func checkPointer() {
        guard self.isVisible else {
            self.stopGrace()
            return
        }
        let pointer = NSEvent.mouseLocation
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
        self.window?.alphaValue = 0
        self.window?.orderOut(nil)
        self.currentKey = nil
        self.moving = false
        for view in self.hosts.values {
            view.layer?.removeAnimation(forKey: "fade")
            view.layer?.opacity = 0
        }
        self.stopTickingIfIdle()
    }

    // MARK: - Geometry

    private var cardScreenRect: NSRect {
        guard let window = self.window else { return .zero }
        return NSRect(
            x: window.frame.minX + self.cardX,
            y: window.frame.minY + self.shown.bottom,
            width: Self.panelWidth,
            height: self.shown.height)
    }

    /// Where the panel for `key` sits, in window coordinates: its top follows the hovered row and it
    /// stays inside the menu's height when it fits there, otherwise inside the screen.
    private func placement(for key: String, visible: NSRect) -> Placement {
        guard let window = self.window else { return self.shown }
        let height = min(self.heights[key] ?? 200, visible.height - 2 * Self.screenMargin)
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
        return Placement(bottom: top - height - window.frame.minY, height: height)
    }

    private func updateFillets(visible _: NSRect) {
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
        guard target != self.to else { return }
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
        self.updateFillets(visible: visible)
    }

    private func applyLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let fillet = UsageHoverOutline.fillet
        let body = NSRect(x: self.cardX, y: self.shown.bottom, width: Self.panelWidth, height: self.shown.height)
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

        for (key, host) in self.hosts {
            let height = self.heights[key] ?? host.frame.height
            host.frame = NSRect(x: 0, y: body.height - height, width: Self.panelWidth, height: height)
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
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth + Self.shadowMargin, height: 800),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.alphaValue = 0

        let root = NSView(frame: panel.contentLayoutRect)
        root.wantsLayer = true
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

        let link = root.displayLink(target: self, selector: #selector(self.tick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.displayLink = link
    }

    private func startTicking() {
        self.lastTick = CACurrentMediaTime()
        self.displayLink?.isPaused = false
    }

    private func stopTickingIfIdle() {
        if !self.moving, self.alpha == self.alphaTarget {
            self.displayLink?.isPaused = true
        }
    }

    @objc private func tick(_: CADisplayLink) {
        let now = CACurrentMediaTime()
        let delta = min(0.05, max(0, now - self.lastTick))
        self.lastTick = now

        if self.moving {
            let elapsed = now - self.moveStarted
            let progress = CGFloat(self.moveStyle.progress(at: elapsed))
            self.shown = Placement(
                bottom: self.from.bottom + (self.to.bottom - self.from.bottom) * progress,
                height: max(40, self.from.height + (self.to.height - self.from.height) * progress))
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
