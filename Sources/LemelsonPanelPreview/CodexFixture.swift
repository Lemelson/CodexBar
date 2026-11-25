import Foundation
import LemelsonUsageKit

/// Codex blocks for the preview until the collector writes `state.codex` (`usage/CODEX-STATE.md`): the same
/// fixtures as Antigravity (`AntigravityFixture`, same names), renamed to Codex, with OpenAI model ids and a
/// ChatGPT plan. They go through the same JSON decoding as the real summary.
enum CodexFixture {
    static let names = AntigravityFixture.names

    /// Gemini model ids and labels of the Antigravity fixture, and what they become here.
    private static let renames: [(String, String)] = [
        ("gemini-4-neon", "gpt-6.1-sol"),
        ("gemini-4-carbon", "gpt-6.1-sol-mini"),
        ("gemini-4-hydrogen", "gpt-6-codex"),
        ("gemini-3.8-flash", "gpt-5.5"),
        ("Neon", "Sol"),
        ("Carbon", "Sol Mini"),
        ("Hydrogen", "Codex"),
        ("AI Ultra", "ChatGPT Pro"),
        ("Gemini", "Codex"),
        ("Antigravity", "Codex"),
        ("antigravity", "codex"),
    ]

    /// The plan price the fixture uses (ChatGPT Pro), so × and "You pay" read like a real Codex plan.
    private static let price = 200.0

    static func state(_ name: String, now: Date) -> UsagePanelState? {
        var block = self.renamed(AntigravityFixture.block(name, now: now)) as? [String: Any] ?? [:]
        self.reprice(&block)
        return self.decode(block: block, generatedAt: now.timeIntervalSince1970 - 60)
    }

    /// A block read from a file: a whole summary (its `codex`, else its `antigravity` renamed) or the block alone.
    static func merging(blockAt url: URL, into state: UsagePanelState?, now: Date) -> UsagePanelState? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let block: Any = object["codex"] ?? object["antigravity"].map(self.renamed) ?? object
        let generatedAt = (object["generatedAt"] as? Double) ?? state?.generatedAt ?? now.timeIntervalSince1970
        guard let decoded = self.decode(block: block, generatedAt: generatedAt) else { return nil }
        var result = state ?? decoded
        result.codex = decoded.codex
        return result
    }

    /// Made-up inputs for the facts the app adds to the Codex card (credits, limit reset credits), drawn by
    /// the same `UsageCodexFacts` the app uses. Only with `--fixture`: the preview cannot read CodexBar's live
    /// Codex snapshot, so a picture of the real summary has no facts.
    @MainActor static func extras(now: Date) -> [UsageProviderPage.Extra] {
        UsageCodexFacts.extras(
            creditsLeft: 58169.35,
            resetCredits: [5.4, 6.5, 17.5].map { now.addingTimeInterval($0 * 86400) },
            now: now)
    }

    private static func decode(block: Any, generatedAt: Double) -> UsagePanelState? {
        let summary: [String: Any] = ["schema": 4, "generatedAt": generatedAt, "accounts": [], "codex": block]
        guard let data = try? JSONSerialization.data(withJSONObject: summary) else { return nil }
        do {
            return try JSONDecoder().decode(UsagePanelState.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("codex fixture does not decode: \(error)\n".utf8))
            return nil
        }
    }

    /// Every string (keys and values) with the Gemini names replaced, all the way down.
    private static func renamed(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return self.rename(string)
        case let dictionary as [String: Any]:
            var result: [String: Any] = [:]
            for (key, inner) in dictionary {
                result[self.rename(key)] = self.renamed(inner)
            }
            return result
        case let array as [Any]:
            return array.map(self.renamed)
        default:
            return value
        }
    }

    private static func rename(_ string: String) -> String {
        self.renames.reduce(string) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// The Antigravity fixture prices its plan at $250; the multiples are recomputed for the Codex price.
    private static func reprice(_ block: inout [String: Any]) {
        guard var value = block["value"] as? [String: Any], value["planPriceUsd"] is Double else { return }
        func times(_ usd: Any?) -> Any {
            (usd as? Double).map { ($0 / self.price * 10).rounded() / 10 } ?? NSNull()
        }
        value["planPriceUsd"] = self.price
        value["timesPrice"] = times(value["monthUsd"])
        if let models = value["byModel"] as? [[String: Any]] {
            value["byModel"] = models.map { model in
                var model = model
                model["timesPrice"] = times(model["monthUsd"])
                return model
            }
        }
        block["value"] = value
        if block["planPriceUsd"] is Double {
            block["planPriceUsd"] = self.price
        }
    }
}
