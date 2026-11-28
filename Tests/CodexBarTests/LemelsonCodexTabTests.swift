import AppKit
import CodexBarCore
import Foundation
@testable import CodexBar
@testable import LemelsonUsageKit
import Testing

// lemelson: the Codex tab in the Claude tab's three modes (`UsageCodexPage`), the modes without Classic, the
// accounts list of the `codex` block (usage/CODEX-STATE.md, "Accounts list"), the shared tints, the line of
// pages and the live lines of every Codex account.
// Synthetic accounts only: made-up ids, names and e-mails (no real account data in git).
@MainActor
@Suite(.serialized)
struct LemelsonCodexTabTests {
    static let now = Date(timeIntervalSince1970: 1_795_600_000)
    static let firstID = "11111111-1111-4111-8111-111111111111"
    static let secondID = "22222222-2222-4222-8222-222222222222"

    static func windows(five: Double?, week: Double, at stamp: Double) -> [String: Any] {
        var windows: [String: Any] = [
            "7d": ["pct": week, "measuredAt": stamp, "resetsAt": stamp + 2 * 86400, "source": "live", "rolled": false],
        ]
        if let five {
            windows["5h"] = ["pct": five, "measuredAt": stamp, "resetsAt": stamp + 3 * 3600, "source": "live",
                             "rolled": false]
        }
        return windows
    }

    static func day(_ usd: Double, tokens: Int) -> [String: Any] {
        ["day": UsageDayKey.string(Self.now), "opus": 0, "fable": 0, "other": usd, "tokens": tokens,
         "m": ["gpt-6.2-sol": [usd, tokens]]]
    }

    /// The shape of a real two-account summary: Alpha active (Plus, both windows, credits), Beta managed
    /// (Pro 5x, no readings, no credits), older calls in `unattributed`.
    static func codexBlock(accounts: Bool = true) -> [String: Any] {
        let stamp = Self.now.timeIntervalSince1970 - 60
        var block: [String: Any] = [
            "uuid": "codex", "name": "Codex", "short": "Codex", "beta": true, "planName": "Plus", "has5h": true,
            "lastMeasuredAt": stamp, "windows": Self.windows(five: 38, week: 6, at: stamp),
            "daily": [Self.day(25, tokens: 100_000_000)],
            "cache": ["7d": ["readPct": 97.0, "missPct": 3.0, "calls": 14]],
        ]
        guard accounts else { return block }
        block["accounts"] = [
            [
                "uuid": Self.firstID, "name": "alpha@example.com", "short": "Alpha", "active": true,
                "beta": true, "planName": "Plus", "has5h": true, "lastMeasuredAt": stamp,
                "managed": false, "codexbarCurrent": true, "snapshotAt": stamp,
                "windows": Self.windows(five: 38, week: 6, at: stamp),
                "daily": [Self.day(20, tokens: 80_000_000)],
                "credits": ["remaining": 57469.46, "note": NSNull(),
                            "resetCredits": [stamp + 2 * 86400, stamp - 10], "updatedAt": stamp],
            ],
            [
                "uuid": Self.secondID, "name": "beta@example.com", "short": "Beta", "active": false, "beta": true,
                "planName": "Pro 5x", "managed": true, "codexbarCurrent": false, "windows": [:], "daily": [],
                "credits": NSNull(),
            ],
        ]
        block["unattributed"] = ["usd7d": 5.0, "usd30d": 5.0, "usd180d": 18016.11, "tokens180d": 9_000_000_000,
                                 "calls": 40000, "lastAt": 1_791_766_800.0, "firstAt": 1_780_000_000.0]
        return block
    }

    static func state(_ block: [String: Any]) throws -> UsagePanelState {
        let summary: [String: Any] = [
            "schema": 4, "generatedAt": Self.now.timeIntervalSince1970, "accounts": [], "codex": block,
        ]
        return try JSONDecoder().decode(UsagePanelState.self, from: JSONSerialization.data(withJSONObject: summary))
    }

    static func defaults() -> UserDefaults {
        let name = "lemelson-codex-tab-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Modes

    @Test
    func `the modes are limits, spend and value; a stored classic reads as limits and is cleared`() {
        #expect(LemelsonPanelMode.allCases == [.limits, .spend, .value])
        #expect(LemelsonPanelMode(rawValue: "classic") == nil)
        let defaults = Self.defaults()
        defaults.set("classic", forKey: "lemelsonCodexLastMode")
        defaults.set("classic", forKey: "lemelsonCodexDefaultMode")
        let store = LemelsonModeStore(
            tab: .codex, lastModeKey: "lemelsonCodexLastMode", pinnedModeKey: "lemelsonCodexDefaultMode",
            defaults: defaults)
        #expect(store.mode == .limits)
        #expect(store.pinnedMode == nil)
        #expect(defaults.string(forKey: "lemelsonCodexLastMode") == nil)
        #expect(defaults.string(forKey: "lemelsonCodexDefaultMode") == nil)
    }

    @Test
    func `each tab keeps its own last mode and pin`() {
        let defaults = Self.defaults()
        let codex = LemelsonModeStore(
            tab: .codex, lastModeKey: "lemelsonCodexLastMode", pinnedModeKey: "lemelsonCodexDefaultMode",
            defaults: defaults)
        let claude = LemelsonModeStore(
            tab: .claude, lastModeKey: "lemelsonPanelLastMode", pinnedModeKey: "lemelsonPanelDefaultMode",
            defaults: defaults)
        codex.mode = .spend
        codex.togglePin()
        claude.mode = .value
        #expect(defaults.string(forKey: "lemelsonCodexLastMode") == "spend")
        #expect(defaults.string(forKey: "lemelsonCodexDefaultMode") == "spend")
        #expect(defaults.string(forKey: "lemelsonPanelLastMode") == "value")
        #expect(claude.pinnedMode == nil)
        // Pinned: the next menu opens in Spend whatever was shown last; unpinned: in the mode shown last.
        codex.mode = .value
        #expect(codex.startMode == .spend)
        codex.mode = .spend
        codex.togglePin()
        #expect(codex.pinnedMode == nil)
        codex.mode = .limits
        #expect(codex.startMode == .limits)
        // The app's two stores use these keys.
        #expect(LemelsonModeStore.codex.lastModeKey == "lemelsonCodexLastMode")
        #expect(LemelsonModeStore.codex.pinnedModeKey == "lemelsonCodexDefaultMode")
        #expect(LemelsonModeStore.claude.lastModeKey == "lemelsonPanelLastMode")
        #expect(LemelsonModeStore.store(for: .codex) === LemelsonModeStore.codex)
    }

    @Test
    func `the line of pages runs through the codex modes, then the claude modes`() {
        let keys = [LemelsonModeTab.codex, .claude].flatMap { tab in
            LemelsonPanelMode.allCases.map { StatusItemController.lemelsonPageKey(tab: tab, mode: $0) }
        }
        #expect(keys == [
            "codex:limits", "codex:spend", "codex:value", "claude:limits", "claude:spend", "claude:value",
        ])
        // From the left a tab opens in its first mode, from the right in its last.
        #expect(StatusItemController.lemelsonLandingMode(.next) == .limits)
        #expect(StatusItemController.lemelsonLandingMode(.previous) == .value)
        // Overview and Antigravity have no modes.
        #expect(StatusItemController.lemelsonPageKey(selection: .overview) == "overview")
        #expect(StatusItemController.lemelsonPageKey(selection: .provider(UsageProvider.antigravity.instanceID))
            == "antigravity")
        // Both pages of one tab are that tab's.
        let codexPage = LemelsonProviderPageState.codex
        #expect(codexPage.isShown(onPage: "codex:spend"))
        #expect(codexPage.isShown(onPage: "codex"))
        #expect(!codexPage.isShown(onPage: "claude:spend"))
        #expect(codexPage.pageKey(mode: .value) == "codex:value")
        #expect(LemelsonProviderPageState.antigravity.pageKey(mode: .spend) == "antigravity")
        #expect(LemelsonProviderPageState.state(forPageKey: "codex:limits") === codexPage)
    }

    // MARK: Accounts list

    @Test
    func `the codex block decodes its accounts, credits and unattributed calls`() throws {
        let state = try Self.state(Self.codexBlock())
        let block = try #require(state.codex)
        #expect(block.accounts.map(\.account.displayName) == ["Alpha", "Beta"])
        let alpha = block.accounts[0]
        #expect(alpha.account.isActive)
        #expect(alpha.managed == false)
        #expect(alpha.codexbarCurrent == true)
        #expect(alpha.credits?.remaining == 57469.46)
        #expect(alpha.credits?.resetCredits.count == 2)
        #expect(alpha.limitWindows.map(\.0) == [.fiveHour, .week])
        let beta = block.accounts[1]
        #expect(!beta.account.isActive)
        #expect(beta.managed == true)
        #expect(beta.credits == nil)
        #expect(beta.limitWindows.isEmpty)
        #expect(block.unattributed?.usd180d == 18016.11)
        #expect(block.unattributed?.lastAt == 1_791_766_800)
        // An older summary without the list, or a broken entry, still decodes.
        #expect(try Self.state(Self.codexBlock(accounts: false)).codex?.accounts.isEmpty == true)
        var broken = Self.codexBlock()
        broken["accounts"] = [
            ["uuid": Self.secondID, "name": "x", "short": "Beta", "active": false, "beta": true, "error": "boom"], 42,
        ]
        #expect(try Self.state(broken).codex?.accounts.map(\.error) == ["boom"])
    }

    @Test
    func `the active account comes first and the tints are the claude ones`() throws {
        // Two of the people the tints know, by the short names Claude Switcher gives them (read from the enum,
        // so no name is spelled out here).
        let known = UsageAccountTint.allCases
        try #require(known.count >= 2)
        var block = Self.codexBlock()
        var accounts = try #require(block["accounts"] as? [[String: Any]])
        accounts[0]["short"] = known[0].rawValue.capitalized
        accounts[1]["short"] = known[1].rawValue.capitalized
        accounts[0]["active"] = false
        accounts[1]["active"] = true
        block["accounts"] = accounts
        let parsedState = try Self.state(block)
        let parsed = try #require(parsedState.codex)
        let entries = UsageCodexPage.entries(of: parsed)
        #expect(entries.map(\.account.uuid) == [Self.secondID, Self.firstID])
        let second = UsageCodexPage.style(of: entries[0], position: 0, in: parsed)
        let first = UsageCodexPage.style(of: entries[1], position: 1, in: parsed)
        #expect(second.initials == known[1].initials && second.active)
        #expect(first.initials == known[0].initials && !first.active)
        // Each known person has a tint and badge of their own.
        #expect(Set(known.map(\.initials)).count == known.count)
        #expect(Set(known.map { "\($0.hex.light)-\($0.hex.dark)" }).count == known.count)
        // Someone else: the chart color of their place in the summary, their first two letters.
        var other = parsed.accounts[0]
        other.account.short = "Olga"
        #expect(UsageCodexPage.style(of: other, position: 0, in: parsed).initials == "Ol")
        // An older summary: the block itself keeps the Codex tint.
        let singleState = try Self.state(Self.codexBlock(accounts: false))
        let single = try #require(singleState.codex)
        #expect(UsageCodexPage.style(of: single, position: 0, in: single).initials
            == UsageProviderSpec.codex.cardStyle.initials)
    }

    // MARK: Layout

    @Test
    func `limits is one card per account, credits as facts, a notice without readings, then the footer`() throws {
        let state = try Self.state(Self.codexBlock())
        let page = try #require(UsageCodexPage(state: state, now: Self.now, width: 310, mode: .limits))
        let alpha = Self.firstID
        let beta = Self.secondID
        #expect(page.rows.map(\.id) == [
            "lemelsonCodex-limits-header-\(alpha)", "lemelsonLimit-codex-\(alpha)-5h",
            "lemelsonLimit-codex-\(alpha)-7d", "lemelsonCodex-limits-fact-\(alpha)-credits",
            "lemelsonCodex-limits-fact-\(alpha)-reset-credits",
            "lemelsonCodex-limits-header-\(beta)", "lemelsonCodex-limits-notice-\(beta)",
            "lemelsonCodex-limits-footer",
        ])
        #expect(page.rows.filter(\.inCard).count == 7)
        // Each card ends with one separator, after its last slice; the footer has its own.
        #expect(page.rows.filter(\.separatorAfter).map(\.id) == [
            "lemelsonCodex-limits-fact-\(alpha)-reset-credits", "lemelsonCodex-limits-notice-\(beta)",
            "lemelsonCodex-limits-footer",
        ])
        #expect(page.lineRows.map(\.id) == ["lemelsonCodex-cache"])
        // Every row id belongs to the Codex page (the menu recycles and warms its rows by these prefixes).
        let spec = UsageProviderSpec.codex
        #expect(page.rows.allSatisfy { $0.id.hasPrefix(spec.idPrefix) || $0.id.hasPrefix(spec.limitRowPrefix) })
        // CodexBar's settings hide the credits facts.
        let hidden = try #require(UsageCodexPage(
            state: state, now: Self.now, width: 310, mode: .limits, showsCredits: false, showsResetCredits: false))
        #expect(!hidden.rows.contains { $0.id.contains("-fact-") })
        // Refreshing: the account without readings says so.
        let refreshing = try #require(UsageCodexPage(
            state: state, now: Self.now, width: 310, mode: .limits, refreshing: true))
        #expect(refreshing.rows.contains { $0.id == "lemelsonCodex-limits-notice-\(beta)" })
    }

    @Test
    func `limits without the accounts list is the block's own card`() throws {
        let state = try Self.state(Self.codexBlock(accounts: false))
        let page = try #require(UsageCodexPage(state: state, now: Self.now, width: 310, mode: .limits))
        #expect(page.rows.map(\.id) == [
            "lemelsonCodex-limits-header-codex", "lemelsonLimit-codex-codex-5h", "lemelsonLimit-codex-codex-7d",
            "lemelsonCodex-limits-footer",
        ])
    }

    @Test
    func `spend has the summary with the chart, one row per account, the unattributed note and the footer`() throws {
        let state = try Self.state(Self.codexBlock())
        let page = try #require(UsageCodexPage(state: state, now: Self.now, width: 310, mode: .spend))
        #expect(page.rows.map(\.id) == [
            "lemelsonCodex-spend-summary", "lemelsonCodex-spend-account-\(Self.firstID)",
            "lemelsonCodex-spend-account-\(Self.secondID)", "lemelsonCodex-spend-unattributed",
            "lemelsonCodex-spend-footer",
        ])
        #expect(page.rows[0].hasControls)
        #expect(page.chartDayDetail != nil)
        // Hovering an account row shows its weeks and models.
        #expect(page.rows.filter { $0.detail != nil }.count == 2)
        let block = try #require(state.codex)
        // Per day, split by account: the two people and the calls no account owns.
        let series = UsageCodexPage.accountSeries(UsageCodexPage.entries(of: block), in: block)
        let spend = UsageProviderSpend(block: block, spec: .codex, now: Self.now, accounts: series)
        let note = try #require(UsageCodexUnattributedRow.text(block.unattributed, spend: spend))
        #expect(note.contains("$18,016"))
        #expect(note.contains("Oct 12"))
        // Without the accounts split there is nothing to reconcile.
        #expect(UsageCodexUnattributedRow.text(
            block.unattributed, spend: UsageProviderSpend(block: block, spec: .codex, now: Self.now)) == nil)
        #expect(spend.hasAccounts)
        #expect(spend.accountLegend.map(\.name) == ["Alpha", "Beta", UsageProviderSpend.unattributedName])
    }

    @Test
    func `value is one card with the account switcher and the limit chart`() throws {
        let state = try Self.state(Self.codexBlock())
        let page = try #require(UsageCodexPage(state: state, now: Self.now, width: 310, mode: .value))
        #expect(page.rows.map(\.id) == ["lemelsonCodex-value-card", "lemelsonCodex-value-footer"])
        #expect(page.rows[0].hasControls)
        #expect(page.chartDayDetail == nil)
    }

    // MARK: CodexBar's newer readings

    @Test
    func `a newer live reading replaces the summary's limits and credits until the collector has it`() throws {
        let state = try Self.state(Self.codexBlock())
        let stamp = Self.now.timeIntervalSince1970
        let live = UsageCodexLive(
            measuredAt: stamp,
            fiveHour: nil,
            week: .init(pct: 40, resetsAt: Int(stamp + 2 * 86400)),
            plan: "Pro 5x",
            creditsLeft: 12.5,
            resetCredits: [],
            creditsAt: stamp)
        let block = try #require(state.codex)
        let entries = UsageCodexPage.entries(of: block, live: [Self.secondID: live])
        let beta = try #require(entries.first { $0.account.uuid == Self.secondID })
        #expect(beta.limitWindows.map(\.0) == [.week])
        #expect(beta.account.window(.week)?.pct == 40)
        #expect(beta.account.has5h == false)
        #expect(beta.credits?.remaining == 12.5)
        // An older reading changes nothing.
        let old = UsageCodexLive(measuredAt: stamp - 3600, fiveHour: UsageQuotaLiveReading.Window(pct: 99, resetsAt: nil as Int?), week: nil)
        let kept = UsageCodexPage.entries(of: block, live: [Self.firstID: old])
        #expect(kept.first?.account.window(.fiveHour)?.pct == 38)
    }

    @Test
    func `codexbar's read of every account becomes live numbers and one live line per account`() throws {
        func account(_ id: String, email: String, active: Bool) -> CodexVisibleAccount {
            CodexVisibleAccount(
                id: "visible-\(email)", email: email, workspaceAccountID: id.uppercased(), storedAccountID: nil,
                selectionSource: .liveSystem, isActive: active, isLive: active, canReauthenticate: false,
                canRemove: false)
        }
        let updated = Self.now
        func snapshot(_ week: Double) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: updated.addingTimeInterval(3600),
                                    resetDescription: nil),
                secondary: RateWindow(usedPercent: week, windowMinutes: 10080,
                                      resetsAt: updated.addingTimeInterval(86400), resetDescription: nil),
                updatedAt: updated,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex, accountEmail: nil, accountOrganization: nil, loginMethod: "plus"))
        }
        let records = [
            CodexAccountUsageSnapshot(
                account: account(Self.firstID, email: "a@example.com", active: true),
                snapshot: snapshot(6), error: nil, sourceLabel: nil),
            CodexAccountUsageSnapshot(
                account: account(Self.secondID, email: "b@example.com", active: false),
                snapshot: snapshot(22), error: nil, sourceLabel: nil),
            CodexAccountUsageSnapshot(
                account: account("ignored", email: "c@example.com", active: false),
                snapshot: nil, error: "no auth", sourceLabel: nil),
        ]
        let live = StatusItemController.lemelsonCodexLive(records, now: Self.now)
        #expect(live.readings.map(\.account) == [
            "codex:v1:provider-account:\(Self.firstID)", "codex:v1:provider-account:\(Self.secondID)",
        ])
        #expect(live.readings.map { $0.week?.pct } == [6, 22])
        #expect(live.byAccount[Self.secondID]?.week?.pct == 22)
        #expect(live.byAccount["b@example.com"]?.week?.pct == 22)
        #expect(live.byAccount[Self.firstID]?.plan == "Plus")
        #expect(live.byAccount["c@example.com"] == nil)
    }

    @Test
    func `the live writer keeps each account's last line apart`() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lemelson-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("codex-quota.jsonl")
        let week = UsageQuotaLiveReading.Window(pct: 6, resetsAt: 1_795_800_000)
        func reading(_ ts: Int, _ account: String) -> UsageQuotaLiveReading {
            UsageQuotaLiveReading(ts: ts, fiveHour: nil, week: week, account: account)
        }
        let writer = UsageQuotaLiveWriter(url: url)
        #expect(await writer.record(reading(1000, "codex:v1:provider-account:a")) == .written)
        #expect(await writer.record(reading(1001, "codex:v1:provider-account:b")) == .written)
        // Readings of the two accounts taken in turn: the same values again are not a new line.
        #expect(await writer.record(reading(1002, "codex:v1:provider-account:a")) == .unchanged)
        #expect(await writer.record(reading(1003, "codex:v1:provider-account:b")) == .unchanged)
        // An account's older reading after another account's newer one is still stale for its own account.
        #expect(await writer.record(reading(999, "codex:v1:provider-account:a")) == .stale)
        // After a restart the tail gives the last line of each account.
        let again = UsageQuotaLiveWriter(url: url)
        #expect(await again.record(reading(1100, "codex:v1:provider-account:a")) == .unchanged)
        #expect(await again.lastByAccount.keys.sorted() == [
            "codex:v1:provider-account:a", "codex:v1:provider-account:b",
        ])
        #expect(UsageQuotaLiveWriter.lastLine(of: url)?.account == "codex:v1:provider-account:b")
    }

    // MARK: Review round: 5-hour recovery, reset credits, private names

    @Test
    func `a 5-hour reading after weekly-only readings shows the 5-hour window again`() throws {
        var block = Self.codexBlock()
        var accounts = try #require(block["accounts"] as? [[String: Any]])
        // Weekly-only so far: no 5-hour window, has5h false.
        accounts[1]["has5h"] = false
        accounts[1]["windows"] = Self.windows(five: nil, week: 12, at: Self.now.timeIntervalSince1970 - 600)
        block["accounts"] = accounts
        let parsed = try #require(try Self.state(block).codex)
        let stamp = Self.now.timeIntervalSince1970
        let live = UsageCodexLive(
            measuredAt: stamp,
            fiveHour: .init(pct: 21, resetsAt: Int(stamp + 3 * 3600)),
            week: .init(pct: 14, resetsAt: Int(stamp + 2 * 86400)))
        let entry = try #require(UsageCodexPage.entries(of: parsed, live: [Self.secondID: live])
            .first { $0.account.uuid == Self.secondID })
        #expect(entry.account.has5h == true)
        #expect(entry.limitWindows.map(\.0) == [.fiveHour, .week])
        #expect(entry.account.window(.fiveHour)?.pct == 21)
        // A weekly-only reading again drops it.
        let weekly = UsageCodexLive(measuredAt: stamp + 60, fiveHour: nil, week: .init(pct: 15, resetsAt: nil as Int?))
        let again = try #require(UsageCodexPage.entries(of: parsed, live: [Self.secondID: weekly])
            .first { $0.account.uuid == Self.secondID })
        #expect(again.account.has5h == false)
        #expect(again.limitWindows.map(\.0) == [.week])
    }

    @Test
    func `reset credits read without a balance show their own fact, undated ones kept`() throws {
        let state = try Self.state(Self.codexBlock())
        let parsed = try #require(state.codex)
        let stamp = Self.now.timeIntervalSince1970
        // The managed account has no credits balance (creditsAt nil) but three reset credits, one undated.
        let live = UsageCodexLive(
            measuredAt: stamp,
            fiveHour: nil,
            week: .init(pct: 3, resetsAt: Int(stamp + 2 * 86400)),
            resetCredits: [Self.now.addingTimeInterval(86400), nil, Self.now.addingTimeInterval(3 * 86400)])
        let entry = try #require(UsageCodexPage.entries(of: parsed, live: [Self.secondID: live])
            .first { $0.account.uuid == Self.secondID })
        let credits = try #require(entry.credits)
        #expect(credits.remaining == nil)
        #expect(credits.resetCredits.count == 3)
        #expect(credits.resetCredits.filter { $0 == nil }.count == 1)
        #expect(credits.resetCreditsAt == stamp)
        let facts = UsageCodexPage.facts(
            of: entry, live: live, showsCredits: true, showsResetCredits: true, now: Self.now, detailWidth: 300)
        #expect(facts.map(\.fact.id) == ["reset-credits"])
        #expect(facts.first?.fact.value == "3 available")
        // The card carries the fact.
        let page = try #require(UsageCodexPage(
            state: state, now: Self.now, width: 310, mode: .limits, live: [Self.secondID: live]))
        #expect(page.rows.contains { $0.id == "lemelsonCodex-limits-fact-\(Self.secondID)-reset-credits" })
        #expect(!page.rows.contains { $0.id == "lemelsonCodex-limits-fact-\(Self.secondID)-credits" })
        // An older reset reading than the summary's changes nothing; the balance keeps its own time.
        let older = UsageCodexLive(
            measuredAt: stamp - 7200, fiveHour: nil, week: nil, resetCredits: [], resetCreditsAt: stamp - 7200)
        let kept = try #require(UsageCodexPage.entries(of: parsed, live: [Self.firstID: older]).first)
        #expect(kept.credits?.resetCredits.count == 2)
        #expect(kept.credits?.remaining == 57469.46)
    }

    @Test
    func `the summary's reset credits without an expiry date decode and stay in the count`() throws {
        var block = Self.codexBlock()
        var accounts = try #require(block["accounts"] as? [[String: Any]])
        let stamp = Self.now.timeIntervalSince1970
        accounts[0]["credits"] = ["remaining": NSNull(), "note": NSNull(),
                                  "resetCredits": [stamp + 86400, NSNull(), "junk", stamp - 10],
                                  "updatedAt": stamp]
        block["accounts"] = accounts
        let state = try Self.state(block)
        let entry = try #require(state.codex?.accounts.first)
        // The malformed element is dropped, `null` stays as an undated credit.
        #expect(entry.credits?.resetCredits == [stamp + 86400, nil, stamp - 10])
        let facts = UsageCodexPage.facts(
            of: entry, live: nil, showsCredits: true, showsResetCredits: true, now: Self.now, detailWidth: 300)
        // The expired one is gone; the dated one and the undated one count.
        #expect(facts.map(\.fact.id) == ["reset-credits"])
        #expect(facts.first?.fact.value == "2 available")
        #expect(facts.first?.fact.caption?.hasPrefix("Next one expires in") == true)
        // Only undated credits: no expiry to name.
        let undated = UsageProviderBlock.Credits(remaining: nil, resetCredits: [nil], updatedAt: stamp)
        var only = entry
        only.credits = undated
        let onlyFacts = UsageCodexPage.facts(
            of: only, live: nil, showsCredits: true, showsResetCredits: true, now: Self.now, detailWidth: 300)
        #expect(onlyFacts.first?.fact.value == "1 available")
        #expect(onlyFacts.first?.fact.caption == "No expiry date")
    }

    @Test
    func `hide personal info shows codexbar's account labels and number badges, tints kept`() throws {
        let known = UsageAccountTint.allCases[0]
        var block = Self.codexBlock()
        var accounts = try #require(block["accounts"] as? [[String: Any]])
        accounts[0]["short"] = known.rawValue.capitalized
        block["accounts"] = accounts
        let state = try Self.state(block)
        let plain = try #require(UsageCodexPage(state: state, now: Self.now, width: 310, mode: .limits))
        let hidden = try #require(UsageCodexPage(
            state: state, now: Self.now, width: 310, mode: .limits, privateNames: [Self.firstID: "Account 1"]))
        // CodexBar's label for the account it knows, "Account <n>" for the other one.
        #expect(hidden.entries.map(\.account.displayName) == ["Account 1", "Account 2"])
        #expect(hidden.block.accounts.map(\.account.displayName) == ["Account 1", "Account 2"])
        #expect(!hidden.entries.contains { $0.account.name.contains("@") || $0.account.short.contains("@") })
        #expect(plain.entries.map(\.account.displayName) == [known.rawValue.capitalized, "Beta"])
        // The rows are the same; only the names differ.
        #expect(hidden.rows.map(\.id) == plain.rows.map(\.id))
        // The badge shows the number, not the person's initials.
        #expect(UsageCodexPage.privateBadge("Account 1", position: 0) == "1")
        #expect(UsageCodexPage.privateBadge("Account 12 · Team", position: 0) == "12")
        #expect(UsageCodexPage.privateBadge("Hidden", position: 2) == "3")
        // CodexBar's number taken already: the next free one.
        let names = UsageCodexPage.privateNames(of: try #require(state.codex), given: [Self.firstID: "Account 2"])
        #expect(names == [Self.firstID: "Account 2", Self.secondID: "Account 3"])
        // Spend and Value carry the hidden names as well.
        let spend = try #require(UsageCodexPage(
            state: state, now: Self.now, width: 310, mode: .spend, privateNames: [:]))
        #expect(spend.entries.map(\.account.displayName) == ["Account 1", "Account 2"])
        // The app's labels come from CodexBar's own redaction, by every key the account has in the summary.
        func visible(_ id: String, email: String, stored: UUID) -> CodexVisibleAccount {
            CodexVisibleAccount(
                id: "visible-\(email)", email: email, workspaceAccountID: id.uppercased(), storedAccountID: stored,
                selectionSource: .managedAccount(id: stored), isActive: false, isLive: false,
                canReauthenticate: false, canRemove: false)
        }
        let labels = StatusItemController.lemelsonCodexPrivateNames([
            visible(Self.firstID, email: "alpha@example.com", stored: UUID(uuidString: Self.firstID)!),
            visible(Self.secondID, email: "beta@example.com", stored: UUID(uuidString: Self.secondID)!),
        ])
        #expect(labels[Self.firstID] == "Account 1")
        #expect(labels["alpha@example.com"] == "Account 1")
        #expect(labels[Self.secondID] == "Account 2")
        #expect(!labels.values.contains { $0.contains("@") })
    }

    // MARK: Review round: switch, readiness, read-only reads

    @Test
    func `a switch marks the new account at once, drops the warm rows, and lasts until a newer summary`() throws {
        let page = LemelsonProviderPageState.codex
        let saved = (page.warmRows, page.switchOverride, page.lastSystemAccountID)
        defer {
            page.warmRows = saved.0
            page.switchOverride = saved.1
            page.lastSystemAccountID = saved.2
        }
        page.warmRows = [.limits: ["lemelsonCodex-limits-header-x": NSView()], .spend: [:]]
        let switchedAt = Self.now
        page.noteSystemAccountSwitch(active: Self.secondID, system: "beta@example.com", at: switchedAt)
        #expect(page.warmRows.isEmpty)
        #expect(page.lastSystemAccountID == "beta@example.com")
        // A summary from before the switch still has the old account active: the switch's account wins.
        #expect(page.switchOverrideID(forSummaryAt: switchedAt.timeIntervalSince1970 - 30) == Self.secondID)
        let state = try Self.state(Self.codexBlock())
        let marked = StatusItemController.lemelsonCodexState(state, active: Self.secondID)
        let entries = UsageCodexPage.entries(of: try #require(marked.codex))
        #expect(entries.map(\.account.uuid) == [Self.secondID, Self.firstID])
        #expect(entries.map(\.account.isActive) == [true, false])
        // An account the summary does not have changes nothing.
        #expect(StatusItemController.lemelsonCodexState(state, active: "someone-else").codex == state.codex)
        // The collector's summary after the switch has it itself: the mark is forgotten.
        #expect(page.switchOverrideID(forSummaryAt: switchedAt.timeIntervalSince1970 + 1) == nil)
        #expect(page.switchOverride == nil)
        #expect(page.switchOverrideID(forSummaryAt: switchedAt.timeIntervalSince1970 - 30) == nil)
    }

    @Test
    func `the codex page, the stock switcher and the all-accounts read share one readiness check`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lemelson-ready-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.json")
        func write(_ object: Any, at date: Date) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let account: [String: Any] = ["uuid": "claude-a", "name": "a@example.com", "short": "A", "active": true]
        // No file: not ready (never fails open).
        #expect(!LemelsonCodexPageReadiness.summaryHasCodexBlock(at: url))
        // A summary without a `codex` block: the stock switcher stays.
        try write(["schema": 4, "generatedAt": 1, "accounts": [account]], at: Self.now)
        #expect(!LemelsonCodexPageReadiness.summaryHasCodexBlock(at: url))
        // A corrupt file: not ready either.
        try Data("{\"schema\": 4, \"accou".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Self.now.addingTimeInterval(1)], ofItemAtPath: url.path)
        #expect(!LemelsonCodexPageReadiness.summaryHasCodexBlock(at: url))
        // With the block: ready, and decided once per version of the file.
        try write(["schema": 4, "generatedAt": 1, "accounts": [account], "codex": Self.codexBlock()],
                  at: Self.now.addingTimeInterval(2))
        #expect(LemelsonCodexPageReadiness.summaryHasCodexBlock(at: url))
        LemelsonCodexPageReadiness.note(nil, at: url)
        #expect(!LemelsonCodexPageReadiness.summaryHasCodexBlock(at: url))
        // Under tests the page is the stock tab, so the stock switcher and its single-account read stay.
        #expect(!StatusItemController.lemelsonCodexPageShowsAllAccounts)
    }

    @Test
    func `the page asks for a read while a visible account has no fresh read of its own`() {
        func account(_ id: String) -> CodexVisibleAccount {
            CodexVisibleAccount(
                id: id, email: "\(id)@example.com", workspaceAccountID: nil, storedAccountID: nil,
                selectionSource: .liveSystem, isActive: false, isLive: false, canReauthenticate: false,
                canRemove: false)
        }
        func record(_ id: String, age: TimeInterval) -> CodexAccountUsageSnapshot {
            CodexAccountUsageSnapshot(
                account: account(id),
                snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Self.now.addingTimeInterval(-age)),
                error: nil, sourceLabel: nil)
        }
        let visible = [account("a"), account("b")]
        #expect(!StatusItemController.lemelsonCodexAccountMissingFreshRead(
            visible: visible, records: [record("a", age: 10), record("b", age: 90)], now: Self.now))
        #expect(StatusItemController.lemelsonCodexAccountMissingFreshRead(
            visible: visible, records: [record("a", age: 10), record("b", age: 600)], now: Self.now))
        #expect(StatusItemController.lemelsonCodexAccountMissingFreshRead(
            visible: visible, records: [record("a", age: 10)], now: Self.now))
    }

    @Test
    func `background account reads are read-only; the followed account keeps codexbar's sources`() {
        func account(_ id: String) -> CodexVisibleAccount {
            CodexVisibleAccount(
                id: id, email: "\(id)@example.com", workspaceAccountID: nil, storedAccountID: nil,
                selectionSource: .liveSystem, isActive: false, isLive: false, canReauthenticate: false,
                canRemove: false)
        }
        #expect(UsageStore.codexAccountReadIsReadOnly(
            account("b"), activeVisibleAccountID: "a", pageShowsAllAccounts: true))
        #expect(!UsageStore.codexAccountReadIsReadOnly(
            account("a"), activeVisibleAccountID: "a", pageShowsAllAccounts: true))
        #expect(!UsageStore.codexAccountReadIsReadOnly(
            account("b"), activeVisibleAccountID: "a", pageShowsAllAccounts: false))
        #expect(CodexProviderDescriptor.readOnlyOAuthStrategyIDs == ["codex.oauth"])
    }

    @Test(CodexCredentialFixtures())
    func `a read-only read of an expired token never runs the codex cli or touches auth json`() async throws {
        let root = CodexCredentialFixtures.root
        let home = root.appendingPathComponent("codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // A token past its refresh time: OAuth may not use it, and only the CLI could redeem it.
        let stale = CodexOAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            idToken: nil,
            accountId: "account-id",
            lastRefresh: Date().addingTimeInterval(-30 * 86400))
        let env = ["CODEX_HOME": home.path]
        try CodexOAuthCredentialsStore.save(stale, env: env)
        let authURL = home.appendingPathComponent("auth.json")
        let before = try Data(contentsOf: authURL)
        // A Codex CLI that leaves a mark if it is ever started.
        let marker = root.appendingPathComponent("cli-ran-\(UUID().uuidString)")
        let cli = root.appendingPathComponent("codex-\(UUID().uuidString)")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        var cliEnv = env
        cliEnv["CODEX_CLI_PATH"] = cli.path
        for mode in [ProviderSourceMode.oauth, .auto] {
            let browserDetection = BrowserDetection(cacheTTL: 0)
            let context = ProviderFetchContext(
                runtime: .app,
                sourceMode: mode,
                includeCredits: true,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: cliEnv,
                settings: nil,
                fetcher: UsageFetcher(environment: cliEnv),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
                browserDetection: browserDetection)
            let outcome = await CodexProviderDescriptor.readOnlyOAuthFetchOutcome(context: context)
            #expect(outcome.attempts.map(\.strategyID) == CodexProviderDescriptor.readOnlyOAuthStrategyIDs)
            if case .success = outcome.result {
                Issue.record("an expired token must not give a reading")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: authURL) == before)
    }
}
