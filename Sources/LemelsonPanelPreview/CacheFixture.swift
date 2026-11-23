import Foundation
import LemelsonUsageKit

/// Claude prompt cache numbers for the preview, in the shape of `usage/README.md` (cache keys),
/// written into the summary's JSON before it is decoded, so they go through the real decoding.
///
///   real   the summary as it is (no cache row when it has no `cache`)
///   full   today, 7 days and 30 days with dollars, for every account and all together
///   plain  percentages only (no dollars), 7 days and 30 days
///   none   every `cache` removed
enum CacheFixture {
    static let names = ["real", "full", "plain", "none"]

    static func load(from url: URL, fixture name: String) -> UsagePanelState? {
        guard name != "real" else { return UsagePanelStore.load(from: url) }
        guard let data = try? Data(contentsOf: url),
              var summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var accounts = summary["accounts"] as? [[String: Any]]
        else { return nil }
        // Reused share and dollars saved over 7 days, by position in the list.
        let shapes: [(Double, Double, Double)] = [(96.2, 4120, 162), (93.4, 1480, 104), (90.8, 860, 88)]
        for index in accounts.indices {
            let shape = shapes[index % shapes.count]
            accounts[index]["cache"] = name == "none" ? NSNull() : self.cache(shape, money: name == "full")
        }
        summary["accounts"] = accounts
        summary["cache"] = name == "none" ? NSNull() : self.cache((94.6, 6460, 354), money: name == "full")
        guard let merged = try? JSONSerialization.data(withJSONObject: summary) else { return nil }
        return try? JSONDecoder().decode(UsagePanelState.self, from: merged)
    }

    private static func cache(_ shape: (read: Double, saved: Double, miss: Double), money: Bool) -> [String: Any] {
        func span(_ read: Double, _ scale: Double) -> [String: Any] {
            var span: [String: Any] = ["readPct": read, "missPct": 100 - read, "calls": (812 * scale).rounded()]
            if money {
                span["savedUsd"] = shape.saved * scale
                span["missUsd"] = shape.miss * scale
                span["readTokens"] = shape.saved * scale / 13.5 * 1_000_000
                span["missTokens"] = shape.miss * scale / 13.5 * 1_000_000
                span["writeTokens"] = 0
            }
            return span
        }
        var result: [String: Any] = ["7d": span(shape.read, 1), "30d": span(shape.read - 0.8, 4.1)]
        if money {
            result["today"] = span(min(99, shape.read + 1.1), 0.16)
        }
        return result
    }
}
