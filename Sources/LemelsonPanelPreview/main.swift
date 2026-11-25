import AppKit
import LemelsonUsageKit
import SwiftUI

// Renders the accounts panel to a PNG without launching CodexBar, so the layout can be checked by eye.
//
//   swift run LemelsonPanelPreview out.png [--state state.json] [--dark] [--warm] [--now 1795401983]
//       [--only limits|spend|value|details|cache|antigravity|antigravity-details|antigravity-cache
//               |codex|codex-details|codex-cache|pages]
//       (limits, spend, value and details also as a comma list: --only limits,spend,value)
//       [--account 1] [--highlighted] [--hover-week 0] [--hover-day 2026-11-21] [--fixture full]
//       [--antigravity block.json] [--codex block.json] [--claude-cache real|full|plain|none]
//       [--period 30] [--breakdown models] [--fill-missing] [--manual-age 30]
//       [--drift month|week] [--hover-month 0] [--drift-fixture months] [--unit opus|mix|fable]
//       [--value-period month|week] [--broken-account 1] [--cache-error]
//
// --highlighted draws the limit rows as they look under the cursor (light ink on the selection color).
// --hover-week draws the Value page's limit chart as if a week were pointed at: 0 is the latest week.
// --drift month|week picks the Month / Week switch of the Value page's limit chart (default month, so renders
// do not depend on an earlier run); --hover-month draws it as if a month were pointed at: 0 is the latest month.
// --drift-fixture months replaces the limit weeks with made-up ones under made-up account names
// (ClaudeFixture.driftMonths): one account with several months, one with a single preliminary month.
// --unit picks the unit of that chart (default opus), --value-period the Month / Week switch of "What the plan
// is worth" (default month).
// --broken-account 1 turns the account at that position of the summary into the collector's error stub
// (repeat the flag for more); --cache-error nulls every cache and sets `cacheError`, as a failing cache step does.
// --hover-day draws the per-day spend charts as if that day were pointed at.
// --period 30|60|90|180 picks the spend period (default 30, so renders do not depend on an earlier run).
// --breakdown accounts|models picks the split of the per-day spend chart (default accounts).
// --fill-missing fills the summary fields of usage/README.md it does not have yet (week limit
// parts, refresh mode) from what it has. --manual-age 30 moves the last reading of manually read accounts
// 30 hours back, windows and all.
// --account picks whose detail panels are drawn: position in the Limits list, 0 is the active account.
// --warm applies a warm tint, as on a Night Shift screen: shows whether colors blend together.
//
// Prompt cache: --only cache draws the Claude Code cache row among stand-ins for the menu's own rows (Status
// Page, Add Account…) and its detail panel; --only antigravity-cache the same for Antigravity. The Claude
// numbers come from --claude-cache (CacheFixture: default "real" when the summary has a `cache`, else "full").
// The Antigravity page (--only antigravity) ends with the same footer stand-in, and antigravity-details adds
// the cache panel. Rows with a detail panel get the chevron the menu draws.
//
// Antigravity (only with --only antigravity or antigravity-details): the summary's own `antigravity` block
// when it has one, else the built-in fixture "full". --fixture picks a fixture (full, run-out, no-quota,
// no-spend, one-day, error, ...: see AntigravityFixture); --antigravity reads the block from a file (a whole summary or the block alone).
//
// Codex (--only codex, codex-details, codex-cache): the summary's own `codex` block when it has one, else the
// Antigravity fixture of the same name renamed to Codex (CodexFixture). --codex reads the block from a file
// (a whole summary: its `codex`, else its `antigravity` renamed; or the block alone). With --fixture the Codex
// card also shows two facts from made-up numbers (credits, limit reset credits), drawn by the app's own
// `UsageCodexFacts`; --no-extras leaves them out. The real summary gets none: the app takes them from
// CodexBar's live Codex snapshot, which the preview cannot read.
//
// --only pages draws Claude Limits, the Antigravity page and the Codex page side by side.

struct ModeChips: View {
    let selected: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(["Limits", "Spend", "Value", "Classic"], id: \.self) { title in
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(title == self.selected ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(title == self.selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            Image(systemName: self.selected == "Limits" ? "pin.fill" : "pin")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

/// A menu separator: a hairline with the menu's insets.
struct MenuSeparator: View {
    var body: some View {
        Divider().padding(.horizontal, 12).padding(.vertical, 4)
    }
}

/// The chevron `LemelsonHighlightBridge` draws on a row with a detail panel.
struct PreviewChevron: ViewModifier {
    let shown: Bool
    let lit: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .trailing) {
            if self.shown {
                Image(systemName: "chevron.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(self.lit ? Color.white.opacity(0.84) : Color.secondary)
                    .padding(.trailing, 10)
            }
        }
    }
}

/// Stand-in for one of the menu's own action rows ("Status Page"): no icon, the menu font, a 24 pt row.
struct MockMenuItem: View {
    let title: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(self.title)
                .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
            Spacer(minLength: 0)
        }
        .padding(.leading, UsageCacheRowView.textInset)
        .frame(width: self.width, height: UsageCacheRowView.rowHeight, alignment: .leading)
    }
}

/// The bottom of the menu: a separator, the cache row with its chevron, and two of the menu's own rows.
struct MockMenuFooter: View {
    let summary: UsageCacheSummary
    let width: CGFloat
    var highlighted = false

    var body: some View {
        MenuSeparator()
        UsageCacheRowView(summary: self.summary, width: self.width)
            .environment(\.usageRowHighlighted, self.highlighted)
            .frame(height: UsageCacheRowView.rowHeight)
        MockMenuItem(title: "Status Page", width: self.width)
        MockMenuItem(title: "Add Account…", width: self.width)
            .padding(.bottom, 5)
    }
}

struct PreviewRoot: View {
    let state: UsagePanelState?
    let now: Date
    let only: String?
    let warm: Bool
    var detailAccount = 0
    var highlighted = false
    var hoverWeek: Int?
    var hoverMonth: Int?
    var hoverDay: String?
    var antigravity: UsagePanelState?
    var codex: UsagePanelState?
    var codexExtras: [UsageProviderPage.Extra] = []

    private let menuWidth: CGFloat = 310
    private let panelWidth: CGFloat = 340

    private var panelBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            if let state = self.state {
                if self.shows("limits") {
                    self.card(width: self.menuWidth) { self.limits(state) }
                }
                if self.shows("spend") {
                    self.card(width: self.menuWidth) { self.spend(state) }
                }
                if self.shows("value") {
                    self.card(width: self.menuWidth) { self.value(state) }
                }
                if self.shows("details") {
                    self.details(state)
                }
            }
            if self.only == "cache", let state = self.state {
                if let summary = UsageCacheSummary.claude(state) {
                    self.cachePair(summary)
                } else {
                    self.card(width: self.menuWidth) {
                        Text("No Claude cache data in this summary.").font(.system(size: 11)).padding(20)
                    }
                }
            }
            if self.only == "pages" || self.only == "antigravity" {
                self.card(width: self.menuWidth) { self.providerPage(.antigravity, self.antigravity) }
            }
            if self.only == "pages" || self.only == "codex" {
                self.card(width: self.menuWidth) {
                    self.providerPage(.codex, self.codex, extras: self.codexExtras)
                }
            }
            if self.only == "antigravity-details" {
                self.providerDetails(.antigravity, self.antigravity)
            }
            if self.only == "codex-details" {
                self.providerDetails(.codex, self.codex, extras: self.codexExtras)
            }
            if self.only == "antigravity-cache" {
                self.providerCache(.antigravity, self.antigravity)
            }
            if self.only == "codex-cache" {
                self.providerCache(.codex, self.codex)
            }
        }
        .environment(\.usagePreviewHoveredDay, self.hoverDay)
        .padding(20)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if self.warm {
                Color(red: 1.0, green: 0.78, blue: 0.42).opacity(0.30).blendMode(.multiply)
            }
        }
    }

    /// `--only limits,spend,value` draws several of the Claude pages side by side; `pages` includes Limits.
    private func shows(_ name: String) -> Bool {
        guard let only = self.only else { return true }
        if only == "pages" {
            return name == "limits"
        }
        return only.split(separator: ",").contains { $0 == name }
    }

    /// The cache row as the bottom of the menu, and its detail panel next to it.
    private func cachePair(_ summary: UsageCacheSummary) -> some View {
        HStack(alignment: .top, spacing: 18) {
            self.card(width: self.menuWidth) {
                MockMenuFooter(summary: summary, width: self.menuWidth, highlighted: self.highlighted)
                    .padding(.top, 2)
            }
            self.card(width: self.panelWidth) {
                UsageCachePanelView(summary: summary, width: self.panelWidth)
            }
        }
    }

    /// A provider page as the menu would stack its rows, with a separator where a row asks for one.
    /// Card rows are drawn joined, the others with the menu's row padding left to the view itself.
    @ViewBuilder private func providerPage(
        _ spec: UsageProviderSpec,
        _ state: UsagePanelState?,
        extras: [UsageProviderPage.Extra] = []) -> some View
    {
        if let state,
           let page = UsageProviderPage(spec: spec, state: state, now: self.now, width: self.menuWidth, extras: extras)
        {
            if !page.rows.isEmpty {
                // The card's first row sits right under the tab row in the menu: the same gap as Claude Limits.
                Color.clear.frame(height: 4)
            }
            ForEach(Array(page.rows.enumerated()), id: \.element.id) { index, row in
                let lit = self.highlighted && row.detail != nil
                row.view
                    .environment(\.usageRowHighlighted, lit)
                    .modifier(PreviewChevron(shown: row.detail != nil && !row.inCard, lit: lit))
                    .background(lit && !row.inCard ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                if row.separatorAfter, index < page.rows.count - 1 {
                    MenuSeparator()
                }
            }
            if let summary = UsageCacheSummary.provider(page.block, spec: spec) {
                MockMenuFooter(summary: summary, width: self.menuWidth)
            }
        }
    }

    /// Every hover detail of a provider page, side by side.
    @ViewBuilder private func providerDetails(
        _ spec: UsageProviderSpec,
        _ state: UsagePanelState?,
        extras: [UsageProviderPage.Extra] = []) -> some View
    {
        if let state,
           let page = UsageProviderPage(
               spec: spec, state: state, now: self.now, width: self.menuWidth, detailWidth: self.panelWidth,
               extras: extras, clock: { [now = self.now] in now })
        {
            ForEach(page.rows.filter { $0.detail != nil } + [page.cacheRow].compactMap(\.self)) { row in
                if let detail = row.detail {
                    self.card(width: self.panelWidth) { detail() }
                }
            }
        }
    }

    @ViewBuilder private func providerCache(_ spec: UsageProviderSpec, _ state: UsagePanelState?) -> some View {
        if let block = state.flatMap(spec.block(in:)) {
            if let summary = UsageCacheSummary.provider(block, spec: spec) {
                self.cachePair(summary)
            } else {
                self.card(width: self.menuWidth) {
                    Text("No \(spec.name) cache data: the page has no cache row.")
                        .font(.system(size: 11)).padding(20)
                }
            }
        }
    }

    private func card(width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        // Card slices fill the height they are given (a menu row's); side by side, a shorter column must not
        // stretch them to the tallest one.
        VStack(spacing: 0) { content() }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width)
            .background(self.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func limits(_ state: UsagePanelState) -> some View {
        ModeChips(selected: "Limits")
        Divider()
        ForEach(state.claudeLimitAccounts) { account in
            let style = UsageLimitCardStyle(account: account, in: state)
            let windows = account.visibleWindows
            UsageLimitCardHeader(
                account: account, style: style, now: self.now, width: self.menuWidth, hasLimits: !windows.isEmpty)
            ForEach(Array(windows.enumerated()), id: \.offset) { index, entry in
                UsageLimitCardRow(
                    kind: entry.0,
                    window: entry.1,
                    style: style,
                    now: self.now,
                    width: self.menuWidth,
                    sessionsLeft: UsageSessionsLeft.make(for: entry.0, account: account, in: state, now: self.now),
                    last: index == windows.count - 1)
                    .environment(\.usageRowHighlighted, self.highlighted)
            }
        }
        if state.isStale(now: self.now) {
            UsageFooterView(state: state, now: self.now, width: self.menuWidth, refreshing: false, showsLegend: false)
        }
    }

    @ViewBuilder private func spend(_ state: UsagePanelState) -> some View {
        ModeChips(selected: "Spend")
        Divider()
        UsageSpendSummaryView(state: state, now: self.now, width: self.menuWidth)
        Divider().padding(.horizontal, 12)
        ForEach(Array(state.accounts.enumerated()), id: \.offset) { index, account in
            UsageSpendAccountRowView(account: account, colorIndex: index, width: self.menuWidth, now: self.now)
        }
        Divider().padding(.horizontal, 12)
        UsageFooterView(state: state, now: self.now, width: self.menuWidth, refreshing: false, showsLegend: false)
    }

    @ViewBuilder private func value(_ state: UsagePanelState) -> some View {
        ModeChips(selected: "Value")
        Divider()
        UsageValueCardView(state: state, width: self.menuWidth, now: self.now)
        Divider().padding(.horizontal, 12)
        UsageDriftCardView(
            state: state,
            width: self.menuWidth,
            initialHoverIndex: UsagePanelSelection.shared.driftPeriod == .month ? self.hoverMonth : self.hoverWeek)
    }

    @ViewBuilder private func details(_ state: UsagePanelState) -> some View {
        let accounts = state.orderedAccounts
        let active = accounts.indices.contains(self.detailAccount) ? accounts[self.detailAccount] : accounts.first
        VStack(spacing: 18) {
            if let active, let window = active.window(.fiveHour), active.has5h != false {
                self.card(width: self.panelWidth) {
                    UsageLimitDetailPanelView(
                        account: active, kind: .fiveHour, window: window, now: self.now, width: self.panelWidth)
                }
            }
            if let active {
                self.card(width: self.panelWidth) {
                    UsageSpendAccountPanelView(state: state, account: active, now: self.now, width: self.panelWidth)
                }
            }
        }
        if let active, let window = active.window(.week) {
            self.card(width: self.panelWidth) {
                UsageLimitDetailPanelView(
                    account: active,
                    kind: .week,
                    window: window,
                    now: self.now,
                    width: self.panelWidth,
                    sessionsLeft: UsageSessionsLeft.make(for: .week, account: active, in: state, now: self.now))
            }
        }
    }
}

func argument(after flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    let usage = "usage: LemelsonPanelPreview out.png [--state file] [--dark] [--warm] [--now t] "
        + "[--only part] [--account n] [--highlighted] [--hover-week n] [--hover-day yyyy-mm-dd] "
        + "[--fixture name] [--antigravity file] [--codex file] [--no-extras] [--claude-cache real|full|plain|none] [--period n] "
        + "[--breakdown accounts|models] [--fill-missing] [--manual-age hours] [--drift month|week] "
        + "[--hover-month n] [--drift-fixture months] [--unit opus|mix|fable] [--value-period month|week] "
        + "[--broken-account n] [--cache-error]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let only = argument(after: "--only")
var stateURL = argument(after: "--state").map { URL(fileURLWithPath: $0) } ?? UsagePanelStore.defaultURL
let brokenAccounts = arguments.indices.filter { arguments[$0] == "--broken-account" && $0 + 1 < arguments.count }
    .compactMap { Int(arguments[$0 + 1]) }
if !brokenAccounts.isEmpty || arguments.contains("--cache-error") {
    guard let copy = ClaudeFixture.writingFailures(
        from: stateURL, broken: brokenAccounts, cacheError: arguments.contains("--cache-error"))
    else {
        FileHandle.standardError.write(Data("cannot write the failure fixture from \(stateURL.path)\n".utf8))
        exit(1)
    }
    stateURL = copy
    FileHandle.standardError.write(Data("failures: accounts \(brokenAccounts), cache error \(arguments.contains("--cache-error"))\n".utf8))
}
var state = UsagePanelStore.load(from: stateURL)
if only == "cache" || argument(after: "--claude-cache") != nil {
    let name = argument(after: "--claude-cache") ?? (state?.cache == nil ? "full" : "real")
    guard CacheFixture.names.contains(name) else {
        FileHandle.standardError.write(Data("unknown cache fixture \(name): \(CacheFixture.names.joined(separator: ", "))\n".utf8))
        exit(2)
    }
    state = CacheFixture.load(from: stateURL, fixture: name)
    FileHandle.standardError.write(Data("claude cache: \(name)\n".utf8))
}
if arguments.contains("--fill-missing") {
    state = state.map(ClaudeFixture.fillingMissingFields)
}
if let hours = argument(after: "--manual-age").flatMap(Double.init) {
    state = state.map { ClaudeFixture.agingManualReadings($0, hours: hours) }
}
if let name = argument(after: "--drift-fixture") {
    guard name == "months" else {
        FileHandle.standardError.write(Data("unknown drift fixture \(name): months\n".utf8))
        exit(2)
    }
    state = state.map(ClaudeFixture.driftMonths)
}
let now = argument(after: "--now").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
let wantsAntigravity = only?.hasPrefix("antigravity") == true || only == "pages"
let wantsCodex = only?.hasPrefix("codex") == true || only == "pages"

if state == nil, !wantsAntigravity, !wantsCodex {
    FileHandle.standardError.write(Data("cannot read summary: \(stateURL.path)\n".utf8))
    exit(1)
}

var antigravity: UsagePanelState?
if wantsAntigravity {
    if let name = argument(after: "--fixture") {
        guard AntigravityFixture.names.contains(name) else {
            let list = AntigravityFixture.names.joined(separator: ", ")
            FileHandle.standardError.write(Data("unknown fixture \(name): \(list)\n".utf8))
            exit(2)
        }
        antigravity = AntigravityFixture.state(name, now: now)
        FileHandle.standardError.write(Data("antigravity: fixture \(name)\n".utf8))
    } else if let path = argument(after: "--antigravity") {
        antigravity = AntigravityFixture.merging(blockAt: URL(fileURLWithPath: path), into: state, now: now)
        FileHandle.standardError.write(Data("antigravity: block from \(path)\n".utf8))
    } else if state?.antigravity != nil {
        antigravity = state
        FileHandle.standardError.write(Data("antigravity: block from \(stateURL.path)\n".utf8))
    } else {
        antigravity = AntigravityFixture.state("full", now: now)
        FileHandle.standardError.write(Data("antigravity: no block in the summary, fixture full\n".utf8))
    }
    if antigravity?.antigravity == nil {
        FileHandle.standardError.write(Data("antigravity: no block to draw\n".utf8))
        exit(1)
    }
}

var codex: UsagePanelState?
if wantsCodex {
    if let name = argument(after: "--fixture") {
        guard CodexFixture.names.contains(name) else {
            FileHandle.standardError.write(Data("unknown fixture \(name): \(CodexFixture.names.joined(separator: ", "))\n".utf8))
            exit(2)
        }
        codex = CodexFixture.state(name, now: now)
        FileHandle.standardError.write(Data("codex: fixture \(name)\n".utf8))
    } else if let path = argument(after: "--codex") {
        codex = CodexFixture.merging(blockAt: URL(fileURLWithPath: path), into: state, now: now)
        FileHandle.standardError.write(Data("codex: block from \(path)\n".utf8))
    } else if state?.codex != nil {
        codex = state
        FileHandle.standardError.write(Data("codex: block from \(stateURL.path)\n".utf8))
    } else {
        codex = CodexFixture.state("full", now: now)
        FileHandle.standardError.write(Data("codex: no block in the summary, fixture full\n".utf8))
    }
    if codex?.codex == nil {
        FileHandle.standardError.write(Data("codex: no block to draw\n".utf8))
        exit(1)
    }
}

// The period is a menu-wide choice kept in the defaults (of this tool, here): always set it.
UsagePanelSelection.shared.spendPeriod = argument(after: "--period").flatMap(Int.init)
    .flatMap(UsageSpendPeriod.init(rawValue:)) ?? .d30
UsagePanelSelection.shared.spendBreakdown = argument(after: "--breakdown")
    .flatMap(UsageSpendBreakdown.init(rawValue:)) ?? .accounts
UsagePanelSelection.shared.driftPeriod = argument(after: "--drift")
    .flatMap(UsageDriftPeriod.init(rawValue:)) ?? .month
UsagePanelSelection.shared.driftUnit = argument(after: "--unit").flatMap(UsageDriftUnit.init(rawValue:)) ?? .opus
UsagePanelSelection.shared.valuePeriod = argument(after: "--value-period")
    .flatMap(UsageDriftPeriod.init(rawValue:)) ?? .month

let appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)

_ = NSApplication.shared
let hosting = NSHostingView(rootView: PreviewRoot(
    state: (wantsAntigravity || wantsCodex) && only != "pages" ? nil : state,
    now: now,
    only: only,
    warm: arguments.contains("--warm"),
    detailAccount: argument(after: "--account").flatMap(Int.init) ?? 0,
    highlighted: arguments.contains("--highlighted"),
    hoverWeek: argument(after: "--hover-week").flatMap(Int.init),
    hoverMonth: argument(after: "--hover-month").flatMap(Int.init),
    hoverDay: argument(after: "--hover-day"),
    antigravity: antigravity,
    codex: codex,
    codexExtras: argument(after: "--fixture") == nil || arguments.contains("--no-extras") ? [] : CodexFixture.extras(now: now)))
hosting.appearance = appearance
let size = hosting.fittingSize
hosting.frame = NSRect(origin: .zero, size: size)
let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = appearance
window.contentView = hosting
hosting.layoutSubtreeIfNeeded()
// Charts finish drawing on the next pass of the run loop.
RunLoop.main.run(until: Date().addingTimeInterval(0.6))

guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
    FileHandle.standardError.write(Data("could not create image\n".utf8))
    exit(1)
}

hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("could not encode PNG\n".utf8))
    exit(1)
}

do {
    try png.write(to: outputURL)
    print("\(outputURL.path) \(Int(size.width))x\(Int(size.height))")
} catch {
    FileHandle.standardError.write(Data("could not write file: \(error)\n".utf8))
    exit(1)
}
