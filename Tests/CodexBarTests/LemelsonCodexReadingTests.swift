import CodexBarCore
import Foundation
import LemelsonUsageKit
import Testing
@testable import CodexBar

// lemelson: a Codex snapshot of the store as a line of `codex-quota.jsonl` (usage/CODEX-STATE.md, "Live
// readings file"): "5h" = the session window, "7d" = the weekly window, plan as the Codex card shows it.
@MainActor
struct LemelsonCodexReadingTests {
    static let updated = Date(timeIntervalSince1970: 1_795_600_000)

    static func snapshot(
        primary: RateWindow?,
        secondary: RateWindow?,
        plan: String? = "plus") -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            updatedAt: self.updated,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "someone@example.com",
                accountOrganization: nil,
                loginMethod: plan))
    }

    static func window(_ pct: Double, minutes: Int?, resetIn: TimeInterval) -> RateWindow {
        RateWindow(
            usedPercent: pct,
            windowMinutes: minutes,
            resetsAt: self.updated.addingTimeInterval(resetIn),
            resetDescription: nil)
    }

    @Test
    func `session and weekly window become the 5h and 7d lanes with the plan name`() throws {
        let snapshot = Self.snapshot(
            primary: Self.window(89, minutes: 300, resetIn: 3600),
            secondary: Self.window(27.199999999999996, minutes: 10080, resetIn: 86400))
        let reading = try #require(StatusItemController.lemelsonCodexReading(snapshot))
        #expect(reading.ts == 1_795_600_000)
        #expect(reading.fiveHour == .init(pct: 89, resetsAt: 1_795_603_600))
        #expect(reading.week == .init(pct: 27.2, resetsAt: 1_795_686_400))
        #expect(reading.plan == "Plus")
        // The line never carries the account's e-mail; the account is the history key the app passes.
        #expect(!reading.jsonLine.contains("@"))
        #expect(reading.account == nil)
        let keyed = try #require(StatusItemController.lemelsonCodexReading(snapshot, account: "codex:v1:provider-account:x"))
        #expect(keyed.account == "codex:v1:provider-account:x")
        #expect(keyed.jsonLine.contains("\"account\": \"codex:v1:provider-account:x\""))
    }

    @Test
    func `the window length decides the lane, a placeholder is no reading`() throws {
        // Only a weekly window, reported as the primary one.
        let weekly = Self.snapshot(primary: Self.window(40, minutes: 10080, resetIn: 86400), secondary: nil)
        let reading = try #require(StatusItemController.lemelsonCodexReading(weekly))
        #expect(reading.fiveHour == nil)
        #expect(reading.week?.pct == 40)
        // No lengths: primary is the session, secondary the week.
        let bare = Self.snapshot(
            primary: Self.window(5, minutes: nil, resetIn: 60),
            secondary: Self.window(6, minutes: nil, resetIn: 60),
            plan: nil)
        let both = try #require(StatusItemController.lemelsonCodexReading(bare))
        #expect(both.fiveHour?.pct == 5)
        #expect(both.week?.pct == 6)
        #expect(both.plan == nil)
        // A synthesized window and an unknown length are left out; nothing left is no reading.
        let placeholder = RateWindow(
            usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil, isSyntheticPlaceholder: true)
        let none = Self.snapshot(primary: placeholder, secondary: Self.window(3, minutes: 43200, resetIn: 60))
        #expect(StatusItemController.lemelsonCodexReading(none) == nil)
    }
}
