import AppKit
@testable import CodexBarCore
import Foundation
import LemelsonUsageKit
import SwiftUI
import Testing

struct LemelsonClaudeLimitOrderTests {
    @Test(arguments: [
        ("Lemelson", ["Lemelson", "Magomed", "Misha"]),
        ("Magomed", ["Magomed", "Lemelson", "Misha"]),
        ("Misha", ["Misha", "Lemelson", "Magomed"]),
        ("", ["Lemelson", "Magomed", "Misha"]),
    ])
    func `active account moves ahead of the fixed order`(active: String, expected: [String]) throws {
        let state = try Self.state(names: ["Misha", "Magomed", "Lemelson"], active: active)
        #expect(state.claudeLimitAccounts.map(\.displayName) == expected)
    }

    @Test
    func `unknown accounts keep their input order and can become active`() throws {
        let state = try Self.state(names: ["Extra B", "Misha", "Extra A", "Lemelson"], active: "Extra A")
        #expect(state.claudeLimitAccounts.map(\.displayName) == ["Extra A", "Lemelson", "Misha", "Extra B"])
    }

    @Test
    func `vpn pause moves into the top-right status instead of a subtitle line`() throws {
        let state = try Self.decodeState(accounts: [
            [
                "uuid": "paused",
                "name": "Lemelson",
                "short": "Lemelson",
                "active": false,
                "refresh": "background",
                "lastPoll": ["ts": 100, "status": "vpn_mismatch"],
            ],
            [
                "uuid": "paused-flag",
                "name": "Magomed",
                "short": "Magomed",
                "active": false,
                "refresh": "background",
                "pausedByVpn": true,
                "lastPoll": ["ts": 100, "status": "ok"],
            ],
            [
                "uuid": "warning",
                "name": "Misha",
                "short": "Misha",
                "active": false,
                "refresh": "background",
                "lastPoll": ["ts": 100, "status": "keychain_denied"],
            ],
        ])
        let paused = try #require(state.accounts.first { $0.uuid == "paused" })
        #expect(paused.isPausedByVPN)
        #expect(paused.limitCardStatus == "Paused · VPN")
        #expect(paused.limitCardNote == nil)

        let pausedFlag = try #require(state.accounts.first { $0.uuid == "paused-flag" })
        #expect(pausedFlag.isPausedByVPN)
        #expect(pausedFlag.limitCardStatus == "Paused · VPN")

        let warning = try #require(state.accounts.first { $0.uuid == "warning" })
        #expect(warning.limitCardStatus == nil)
        #expect(warning.limitCardNote?.isWarning == true)
    }

    @MainActor
    @Test
    func `paused header with status and age stays single-line at narrow width`() throws {
        let now = Date(timeIntervalSince1970: 1_795_700_000)
        let state = try Self.decodeState(accounts: [
            [
                "uuid": "paused-old",
                "name": "Lemelson",
                "short": "Lemelson",
                "active": false,
                "refresh": "background",
                "lastMeasuredAt": now.timeIntervalSince1970 - 3 * 3600,
                "lastPoll": ["ts": now.timeIntervalSince1970 - 60, "status": "vpn_mismatch"],
            ],
        ])
        let account = try #require(state.accounts.first)
        let style = UsageLimitCardStyle(account: account, in: state)
        let header = UsageLimitCardHeader(account: account, style: style, now: now, width: 280, hasLimits: true)
        let hosting = NSHostingView(rootView: header.frame(width: 280))
        hosting.layoutSubtreeIfNeeded()
        let plainHeader = UsageLimitCardHeader(
            name: account.displayName,
            style: style,
            status: nil,
            measuredAt: account.lastMeasuredAt,
            now: now,
            note: nil,
            width: 280,
            hasLimits: true)
        let plainHosting = NSHostingView(rootView: plainHeader.frame(width: 280))
        plainHosting.layoutSubtreeIfNeeded()
        #expect(abs(hosting.fittingSize.height - plainHosting.fittingSize.height) <= 1.0)
        #expect(account.limitCardAgeText(now: now) != nil)
    }

    @Test
    func `switcher fetch strategy reconciles active account with accounts json and never falls back`() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("switcher-strategy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let accountsURL = dir.appendingPathComponent("accounts.json")
        let accountsJSON = """
        {"activeId":"acc-b","accounts":[{"id":"acc-a","accountUuid":"uuid-a"},{"id":"acc-b","accountUuid":"uuid-b"}]}
        """
        try accountsJSON.write(to: accountsURL, atomically: true, encoding: .utf8)

        let stateJSON = """
        {"accounts":[
          {"uuid":"uuid-a","name":"Lemelson","short":"Lemelson","active":true},
          {"uuid":"uuid-b","name":"Misha","short":"Misha","active":false}
        ]}
        """
        let state = try JSONDecoder().decode(ClaudeSwitcherStateFetchStrategy.State.self, from: Data(stateJSON.utf8))
        let resolved = try ClaudeSwitcherStateFetchStrategy.resolveActiveAccount(in: state, accountsURL: accountsURL)
        #expect(resolved.uuid == "uuid-b")
        #expect(resolved.short == "Misha")

        let strategy = ClaudeSwitcherStateFetchStrategy()
        #expect(strategy.id == "claude.switcher-state")
    }

    private static func state(names: [String], active: String) throws -> UsagePanelState {
        let accounts: [[String: Any]] = names.map { name in
            ["uuid": name, "name": name, "short": name, "active": name == active]
        }
        return try Self.decodeState(accounts: accounts)
    }

    private static func decodeState(accounts: [[String: Any]]) throws -> UsagePanelState {
        let data = try JSONSerialization.data(withJSONObject: ["generatedAt": 0, "accounts": accounts])
        return try JSONDecoder().decode(UsagePanelState.self, from: data)
    }
}
