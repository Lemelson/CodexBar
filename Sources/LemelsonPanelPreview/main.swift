import AppKit
import LemelsonUsageKit
import SwiftUI

// Renders the accounts panel to a PNG without launching CodexBar, so the layout can be checked by eye.
//
//   swift run LemelsonPanelPreview out.png [--state state.json] [--dark] [--warm] [--now 1795401983]
//       [--only limits|spend|value|details|cache|antigravity|antigravity-details|antigravity-cache]
//       [--account 1] [--highlighted] [--hover-week 0] [--hover-day 2026-11-21] [--fixture full]
//       [--antigravity block.json] [--claude-cache real|full|plain|none]
//       [--period 30] [--breakdown models] [--fill-missing] [--manual-age 30]
//       [--drift month|week] [--hover-month 0] [--drift-fixture months]
//
// --highlighted draws the limit rows as they look under the cursor (light ink on the selection color).
// --hover-week draws the Value page's limit chart as if a week were pointed at: 0 is the latest week.
// --drift month|week picks the Month / Week switch of the Value page's limit chart (default month, so renders
// do not depend on an earlier run); --hover-month draws it as if a month were pointed at: 0 is the latest month.
// --drift-fixture months replaces the limit weeks with made-up ones under made-up account names
// (ClaudeFixture.driftMonths): one account with several months, one with a single preliminary month.
// --hover-day draws the per-day spend charts as if that day were pointed at.
// --period 30|60|90|180 picks the spend period (default 30, so renders do not depend on an earlier run).
// --breakdown accounts|models picks the split of the per-day spend chart (default accounts).
// --fill-missing fills the summary fields of usage/STATE-ADDITIONS-24.md it does not have yet (week limit
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
            if self.only == "antigravity" {
                self.card(width: self.menuWidth) { self.antigravityPage }
            }
            if self.only == "antigravity-details" {
                self.antigravityDetails
            }
            if self.only == "antigravity-cache", let block = self.antigravity?.antigravity {
                if let summary = UsageCacheSummary.antigravity(block) {
                    self.cachePair(summary)
                } else {
                    self.card(width: self.menuWidth) {
                        Text("No Antigravity cache data: the page has no cache row.")
                            .font(.system(size: 11)).padding(20)
                    }
                }
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

    private func shows(_ name: String) -> Bool {
        self.only == nil || self.only == name
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

    /// The page as the menu would stack its rows, with a separator where a row asks for one.
    @ViewBuilder private var antigravityPage: some View {
        if let state = self.antigravity,
           let page = UsageAntigravityPage(state: state, now: self.now, width: self.menuWidth)
        {
            ForEach(Array(page.rows.enumerated()), id: \.element.id) { index, row in
                let lit = self.highlighted && row.detail != nil
                row.view
                    .environment(\.usageRowHighlighted, lit)
                    .modifier(PreviewChevron(shown: row.detail != nil, lit: lit))
                    .background(lit ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                if row.separatorAfter, index < page.rows.count - 1 {
                    MenuSeparator()
                }
            }
            if let summary = UsageCacheSummary.antigravity(page.block) {
                MockMenuFooter(summary: summary, width: self.menuWidth)
            }
        }
    }

    /// Every hover detail of the page, side by side.
    @ViewBuilder private var antigravityDetails: some View {
        if let state = self.antigravity,
           let page = UsageAntigravityPage(
               state: state, now: self.now, width: self.menuWidth, detailWidth: self.panelWidth,
               clock: { [now = self.now] in now })
        {
            ForEach(page.rows.filter { $0.detail != nil } + [page.cacheRow].compactMap(\.self)) { row in
                if let detail = row.detail {
                    self.card(width: self.panelWidth) { detail() }
                }
            }
        }
    }

    private func card(width: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .frame(width: width)
            .background(self.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func limits(_ state: UsagePanelState) -> some View {
        ModeChips(selected: "Limits")
        Divider()
        ForEach(state.orderedAccounts) { account in
            UsageAccountHeaderView(account: account, now: self.now, width: self.menuWidth)
            ForEach(UsagePanelState.WindowKind.allCases, id: \.self) { kind in
                if let window = account.window(kind), window.pct != nil, !(kind == .fiveHour && account.has5h == false) {
                    UsageLimitRowView(
                        kind: kind,
                        window: window,
                        now: self.now,
                        width: self.menuWidth,
                        sessionsLeft: UsageSessionsLeft.make(
                            for: kind, account: account, in: state, now: self.now),
                        reading: UsageReadingAge.make(account: account, kind: kind, window: window, now: self.now))
                        .environment(\.usageRowHighlighted, self.highlighted)
                        .background(self.highlighted ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                }
            }
            Divider().padding(.horizontal, 12).padding(.top, 4)
        }
        UsageFooterView(state: state, now: self.now, width: self.menuWidth, refreshing: false, showsLegend: true)
    }

    @ViewBuilder private func spend(_ state: UsagePanelState) -> some View {
        ModeChips(selected: "Spend")
        Divider()
        UsageSpendSummaryView(state: state, now: self.now, width: self.menuWidth)
        Divider().padding(.horizontal, 12)
        ForEach(Array(state.accounts.enumerated()), id: \.offset) { index, account in
            UsageSpendAccountRowView(account: account, colorIndex: index, width: self.menuWidth)
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
        + "[--fixture name] [--antigravity file] [--claude-cache real|full|plain|none] [--period n] "
        + "[--breakdown accounts|models] [--fill-missing] [--manual-age hours] [--drift month|week] "
        + "[--hover-month n] [--drift-fixture months]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let only = argument(after: "--only")
let stateURL = argument(after: "--state").map { URL(fileURLWithPath: $0) } ?? UsagePanelStore.defaultURL
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
let wantsAntigravity = only?.hasPrefix("antigravity") == true

if state == nil, !wantsAntigravity {
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

// The period is a menu-wide choice kept in the defaults (of this tool, here): always set it.
UsagePanelSelection.shared.spendPeriod = argument(after: "--period").flatMap(Int.init)
    .flatMap(UsageSpendPeriod.init(rawValue:)) ?? .d30
UsagePanelSelection.shared.spendBreakdown = argument(after: "--breakdown")
    .flatMap(UsageSpendBreakdown.init(rawValue:)) ?? .accounts
UsagePanelSelection.shared.driftPeriod = argument(after: "--drift")
    .flatMap(UsageDriftPeriod.init(rawValue:)) ?? .month

let appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)

_ = NSApplication.shared
let hosting = NSHostingView(rootView: PreviewRoot(
    state: wantsAntigravity ? nil : state,
    now: now,
    only: only,
    warm: arguments.contains("--warm"),
    detailAccount: argument(after: "--account").flatMap(Int.init) ?? 0,
    highlighted: arguments.contains("--highlighted"),
    hoverWeek: argument(after: "--hover-week").flatMap(Int.init),
    hoverMonth: argument(after: "--hover-month").flatMap(Int.init),
    hoverDay: argument(after: "--hover-day"),
    antigravity: antigravity))
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
