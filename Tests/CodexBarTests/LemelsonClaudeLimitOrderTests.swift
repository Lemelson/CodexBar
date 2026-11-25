import Foundation
import LemelsonUsageKit
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

    private static func state(names: [String], active: String) throws -> UsagePanelState {
        let accounts: [[String: Any]] = names.map { name in
            ["uuid": name, "name": name, "short": name, "active": name == active]
        }
        let data = try JSONSerialization.data(withJSONObject: ["generatedAt": 0, "accounts": accounts])
        return try JSONDecoder().decode(UsagePanelState.self, from: data)
    }
}
