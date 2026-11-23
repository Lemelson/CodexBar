import SwiftUI

/// How old the limit reading of an account that is read only by hand is (`refresh == "manual"`: the VPN-only
/// account, read while it is the active one). Its bars keep showing the last reading, so an old one is marked:
/// under 12 hours it looks normal, up to a day it is orange, and older than a day, or from a window that has
/// reset since, it is red.
public struct UsageReadingAge: Equatable, Sendable {
    public enum Level: Sendable {
        case fresh, old, stale
    }

    public let level: Level
    public let measuredAt: Double
    public let now: Date
    /// Seconds from the reading to the window's reset; nil when the reset time is unknown.
    public let beforeReset: Double?
    /// The window has reset since the reading: the bar is the previous window's.
    public let resetSince: Bool

    static let oldAfter: Double = 12 * 3600
    static let staleAfter: Double = 24 * 3600

    /// Nil for accounts the collector reads in the background, and when there is no reading.
    /// With a window (and its kind) it describes that window's reading; without, the account's latest.
    public static func make(
        account: UsagePanelState.Account,
        kind: UsagePanelState.WindowKind? = nil,
        window: UsagePanelState.Window? = nil,
        now: Date) -> UsageReadingAge?
    {
        guard !account.refreshesInBackground,
              let measuredAt = window?.measuredAt ?? account.measuredAt
        else { return nil }
        let stamp = now.timeIntervalSince1970
        let age = max(0, stamp - measuredAt)
        let windows = window.map { [$0] } ?? account.visibleWindows.map(\.1)
        let resets = windows.compactMap(\.resetsAt)
        // A reading older than the window itself is from an earlier window even when the reset time is unknown.
        let resetSince = windows.contains { $0.rolled == true } || resets.contains { $0 <= stamp }
            || kind.map { age >= $0.span } == true
        let level: Level = if resetSince || age >= Self.staleAfter {
            .stale
        } else if age >= Self.oldAfter {
            .old
        } else {
            .fresh
        }
        let beforeReset = window?.resetsAt.map { max(0, $0 - measuredAt) }
        return UsageReadingAge(
            level: level, measuredAt: measuredAt, now: now, beforeReset: beforeReset, resetSince: resetSince)
    }

    public var isFresh: Bool {
        self.level == .fresh
    }

    public var color: Color {
        switch self.level {
        case .fresh: .secondary
        case .old: UsagePalette.warning
        case .stale: UsagePalette.paceBad
        }
    }

    /// "reading from 3d ago": the age in the account header.
    public var ageText: String {
        "reading from \(UsageFormat.age(self.measuredAt, now: self.now))"
    }

    /// Under a limit row: "Reading from 14h ago, 2d 3h before reset" or
    /// "Reading from 3d ago, before the window reset".
    public var rowText: String {
        let from = "Reading from \(UsageFormat.age(self.measuredAt, now: self.now))"
        if self.resetSince {
            return "\(from), before the window reset"
        }
        guard let beforeReset else { return from }
        return "\(from), \(UsageFormat.duration(beforeReset)) before reset"
    }
}

/// "Reading from 3d ago, before the window reset": under a limit row of a manually read account.
struct UsageReadingAgeLine: View {
    let reading: UsageReadingAge
    @Environment(\.usageRowHighlighted) private var highlighted

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.system(size: 9.5))
            Text(self.reading.rowText)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(self.highlighted ? .white : self.reading.color)
    }
}
