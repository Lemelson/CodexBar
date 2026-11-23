import AppKit
import QuartzCore
import SwiftUI

// The look of the detail panel that follows the pointer over menu rows: how it moves and its outline.
// The panel itself (content, placement, mouse routing) is `UsageHoverPanelController`.

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
    /// How far the panel reaches under the menu to cover the menu's own hairline border.
    static let overlap: CGFloat = 2
    /// Distance from the panel's right edge to the middle of the menu's hairline border. The concave
    /// corners end there, so their line runs into the menu's border instead of past it.
    static let joinInset: CGFloat = 1.5

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
        let join = w - self.joinInset
        if topFillet {
            if rightEdge {
                path.move(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: join, y: h))
            } else {
                path.move(to: CGPoint(x: join, y: h))
            }
            path.addArc(
                center: CGPoint(x: join - f, y: h), radius: f, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
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
            path.addLine(to: CGPoint(x: join - f, y: bottom))
            path.addArc(
                center: CGPoint(x: join - f, y: 0), radius: f, startAngle: .pi / 2, endAngle: 0, clockwise: true)
            if rightEdge {
                path.addLine(to: CGPoint(x: w, y: 0))
            }
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
