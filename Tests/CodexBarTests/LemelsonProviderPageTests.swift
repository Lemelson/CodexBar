import Foundation
import LemelsonUsageKit
import Testing

// lemelson: the shared limit card (verdict and time mark, `UsageLimitCard.swift`) and the provider pages
// (`UsageProviderPage`, the `codex` block decoded like `antigravity`).
struct LemelsonLimitCardTests {
    static let now = Date(timeIntervalSince1970: 1_795_600_000)
    static let week = 7 * 86400.0

    /// A weekly window that resets in `resetIn` seconds, read `age` seconds ago at `pct` used.
    static func window(
        pct: Double,
        resetIn: Double,
        age: Double = 60,
        rolled: Bool = false,
        forecast: [String: Any]? = nil) throws -> UsagePanelState.Window
    {
        let stamp = self.now.timeIntervalSince1970
        var json: [String: Any] = [
            "pct": pct, "measuredAt": stamp - age, "resetsAt": stamp + resetIn, "rolled": rolled,
        ]
        if let forecast {
            json["forecast"] = forecast
        }
        return try JSONDecoder().decode(UsagePanelState.Window.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test
    func `time mark stands at even use by now`() throws {
        // Half the week left: even use is at 50 %.
        let window = try Self.window(pct: 30, resetIn: Self.week / 2)
        #expect(UsageLimitTimeMark.evenUse(window: window, kind: .week, now: Self.now) == 50)
        #expect(UsageLimitTimeMark.make(window: window, kind: .week, now: Self.now)
            == UsageLimitTimeMark(percent: 50, tone: .reserve))
    }

    @Test
    func `time mark is red above even use and grey for an old reading`() throws {
        let deficit = try Self.window(pct: 70, resetIn: Self.week / 2)
        #expect(UsageLimitTimeMark.make(window: deficit, kind: .week, now: Self.now)?.tone == .deficit)
        let old = try Self.window(pct: 70, resetIn: Self.week / 2, age: UsageLimitReading.freshness + 1)
        #expect(UsageLimitTimeMark.make(window: old, kind: .week, now: Self.now)?.tone == .stale)
    }

    @Test
    func `no time mark for a rolled window or a reset further away than the window`() throws {
        let rolled = try Self.window(pct: 0, resetIn: 3600, rolled: true)
        #expect(UsageLimitTimeMark.make(window: rolled, kind: .week, now: Self.now) == nil)
        let far = try Self.window(pct: 10, resetIn: 6 * 3600)
        #expect(UsageLimitTimeMark.make(window: far, kind: .fiveHour, now: Self.now) == nil)
        #expect(UsageLimitTimeMark.make(window: far, kind: .week, now: Self.now) != nil)
    }

    @Test
    func `verdict follows the forecast of a fresh reading`() throws {
        let stamp = Self.now.timeIntervalSince1970
        let lasts = try Self.window(pct: 30, resetIn: 86400, forecast: ["at": stamp - 60, "endPct": 60, "endHi": 80])
        #expect(UsageLimitVerdict(window: lasts, now: Self.now) == .enough)

        let tight = try Self.window(pct: 30, resetIn: 86400, forecast: ["at": stamp - 60, "endPct": 90, "endHi": 104])
        #expect(UsageLimitVerdict(window: tight, now: Self.now) == .mayRunOut)

        // Out in 2h, 22h before the reset.
        let out = try Self.window(
            pct: 80, resetIn: 86400, forecast: ["at": stamp - 60, "endPct": 130, "hitAt": stamp + 7200])
        let verdict = UsageLimitVerdict(window: out, now: Self.now)
        #expect(verdict == .outIn("2h", beforeReset: "22h"))
        #expect(verdict.text == "Out in ≈2h")
        #expect(verdict.runOutLine == "Runs out 22h before reset")
    }

    @Test
    func `verdict says nothing for an old reading or without a forecast`() throws {
        let stamp = Self.now.timeIntervalSince1970
        let old = try Self.window(
            pct: 30, resetIn: 86400, age: UsageLimitReading.freshness + 1,
            forecast: ["at": stamp - 60, "endPct": 60])
        #expect(UsageLimitVerdict(window: old, now: Self.now) == .unknown)
        let bare = try Self.window(pct: 30, resetIn: 86400)
        #expect(UsageLimitVerdict(window: bare, now: Self.now) == .unknown)
        #expect(UsageLimitVerdict(window: bare, now: Self.now).runOutLine == nil)
        let full = try Self.window(pct: 100, resetIn: 86400)
        #expect(UsageLimitVerdict(window: full, now: Self.now) == .outNow)
    }
}

struct LemelsonProviderBlockTests {
    static let now = LemelsonLimitCardTests.now

    /// A summary with one provider block under `key`, shaped like `usage/ANTIGRAVITY-STATE.md`.
    static func state(key: String, block: [String: Any]) throws -> UsagePanelState {
        let summary: [String: Any] = ["schema": 4, "generatedAt": now.timeIntervalSince1970, "accounts": [], key: block]
        return try JSONDecoder().decode(UsagePanelState.self, from: JSONSerialization.data(withJSONObject: summary))
    }

    static func codexBlock(name: String? = "Codex") -> [String: Any] {
        let stamp = self.now.timeIntervalSince1970
        var block: [String: Any] = [
            "uuid": "codex", "short": "Codex", "beta": true, "planName": "ChatGPT Plus", "planPriceUsd": 20,
            "has5h": true, "lastMeasuredAt": stamp - 60, "kFable": 1.0,
            "windows": [
                "5h": ["pct": 11.0, "measuredAt": stamp - 60, "resetsAt": stamp + 3 * 3600, "source": "live",
                       "rolled": false, "usd": ["opus": 0, "fable": 0, "other": 4.2]],
                "7d": ["pct": 27.0, "measuredAt": stamp - 60, "resetsAt": stamp + 2 * 86400, "source": "live",
                       "rolled": false, "usd": ["opus": 0, "fable": 0, "other": 40.0],
                       "sessions": ["perWeek": 6.0, "pairs": 4]],
            ],
            "daily": [["day": UsageDayKey.string(now), "opus": 0, "fable": 0, "other": 17.96, "tokens": 103_000_000,
                       "m": ["gpt-6.1-sol": [17.0, 100_000_000], "gpt-6.1-sol-mini": [0.96, 3_000_000]]]],
            "trackedSince": stamp - 86400,
            "models": ["gpt-6.1-sol": ["calls": 10, "usd": 17.0, "missPct": 5.0],
                       "gpt-6.1-sol-mini": ["calls": 4, "usd": 0.96, "missPct": 12.0]],
            "cache": ["7d": ["readPct": 95.0, "missPct": 5.0, "calls": 14]],
            "value": ["confident": false, "reason": "Measured 1 of 4 times so far.", "byModel": []],
        ]
        block["name"] = name
        return block
    }

    @Test
    func `codex block decodes with the antigravity decoder`() throws {
        let state = try Self.state(key: "codex", block: Self.codexBlock())
        let block = try #require(state.codex)
        #expect(state.antigravity == nil)
        #expect(UsageProviderSpec.codex.block(in: state) == block)
        #expect(block.account.displayName == "Codex")
        #expect(block.limitWindows.map(\.0) == [.fiveHour, .week])
        #expect(block.models.keys.sorted() == ["gpt-6.1-sol", "gpt-6.1-sol-mini"])
        #expect(block.worth?.confident == false)
        #expect(block.sessionsLeft(for: .week, now: Self.now) != nil)
    }

    @Test
    func `a block without a name is named after the key it is filed under`() throws {
        let codex = try Self.state(key: "codex", block: Self.codexBlock(name: nil))
        #expect(codex.codex?.account.name == "Codex")
        var bare = Self.codexBlock(name: nil)
        bare["uuid"] = nil
        let antigravity = try Self.state(key: "antigravity", block: bare)
        #expect(antigravity.antigravity?.account.name == "Antigravity")
        #expect(antigravity.antigravity?.account.uuid == "antigravity")
    }

    @Test
    func `a malformed codex block leaves the rest of the summary alone`() throws {
        let state = try Self.state(key: "codex", block: ["uuid": "codex", "error": "codex.py: no sessions"])
        #expect(state.codex?.error == "codex.py: no sessions")
        #expect(state.codex?.limitWindows.isEmpty == true)
    }

    @Test
    func `openai and gemini model ids read as short names`() {
        let openai = UsageModelNaming.openai.labels(for: ["gpt-6.1-sol", "gpt-6.1-sol-mini", "gpt-5", "codex-mini-latest"])
        #expect(openai == ["gpt-6.1-sol": "Sol", "gpt-6.1-sol-mini": "Sol Mini", "gpt-5": "GPT-5",
                           "codex-mini-latest": "Codex Mini"])
        let clash = UsageModelNaming.openai.labels(for: ["gpt-6.1-sol", "gpt-6-sol"])
        #expect(clash == ["gpt-6.1-sol": "Sol 6.1", "gpt-6-sol": "Sol 6"])
        let gemini = UsageModelNaming.gemini.labels(for: ["gemini-4-neon", "gemini-3.7-flash", "gemini-3.6-flash"])
        #expect(gemini == ["gemini-4-neon": "Neon", "gemini-3.7-flash": "Flash 3.7", "gemini-3.6-flash": "Flash 3.6"])
    }

    @Test
    func `plan names lose the vendor words in the card header`() {
        #expect(UsageProviderSpec.antigravity.shortPlan("Google AI Ultra 5x") == "Ultra 5x")
        #expect(UsageProviderSpec.codex.shortPlan("ChatGPT Plus") == "Plus")
        #expect(UsageProviderSpec.codex.shortPlan("Plus") == "Plus")
        #expect(UsageProviderSpec.codex.shortPlan("  ") == nil)
        #expect(UsageProviderSpec.codex.shortPlan(nil) == nil)
    }

    @Test @MainActor
    func `codex page is the shared card, spend, value and footer`() throws {
        let state = try Self.state(key: "codex", block: Self.codexBlock())
        let extras = [UsageProviderPage.Extra(fact: UsageLimitCardFact(
            id: "credits", symbol: "creditcard", title: "Credits", value: "58,169 left"))]
        let page = try #require(UsageProviderPage(spec: .codex, state: state, now: Self.now, width: 310, extras: extras))
        #expect(page.rows.map(\.part) == [
            .header, .limit(.fiveHour), .limit(.week), .fact("credits"), .spend, .value, .footer,
        ])
        #expect(page.rows.map(\.id) == [
            "lemelsonCodex-header", "lemelsonLimit-codex-5h", "lemelsonLimit-codex-7d", "lemelsonCodex-fact-credits",
            "lemelsonCodex-spend", "lemelsonCodex-value", "lemelsonCodex-footer",
        ])
        #expect(page.rows.prefix(4).filter(\.inCard).count == 4)
        #expect(page.rows.filter { $0.detail != nil }.map(\.id) == ["lemelsonLimit-codex-5h", "lemelsonLimit-codex-7d"])
        // The card ends with one separator, after its last slice (the fact).
        #expect(page.rows.filter(\.separatorAfter).first?.id == "lemelsonCodex-fact-credits")
        #expect(page.cacheRow?.id == "lemelsonCodex-cache")
        // The same summary has no Antigravity block, so no Antigravity page.
        #expect(UsageProviderPage(spec: .antigravity, state: state, now: Self.now, width: 310) == nil)
    }

    @Test @MainActor
    func `a failed collector step shows one notice inside the card`() throws {
        let state = try Self.state(key: "antigravity", block: ["uuid": "antigravity", "error": "boom"])
        let page = try #require(UsageProviderPage(spec: .antigravity, state: state, now: Self.now, width: 310))
        #expect(page.rows.map(\.part) == [.header, .notice, .footer])
        #expect(page.cacheRow == nil)
    }
}
