import AppKit
import LemelsonUsageKit
import SwiftUI

// Renders the accounts panel to a PNG without launching CodexBar, so the layout can be checked by eye.
//
//   swift run LemelsonPanelPreview out.png [--state state.json] [--dark] [--warm] [--now 1795401983]
//       [--only limits|spend|value|details|antigravity|antigravity-details] [--account 1] [--highlighted]
//       [--hover-week 0] [--hover-day 2026-11-21] [--fixture full] [--antigravity block.json]
//
// --highlighted draws the limit rows as they look under the cursor (light ink on the selection color).
// --hover-week draws the Value page's limit chart as if a week were pointed at: 0 is the latest week.
// --hover-day draws the per-day spend charts as if that day were pointed at.
// --period 30|60|90|180 picks the spend period (default 30, so renders do not depend on an earlier run).
// --account picks whose detail panels are drawn: position in the Limits list, 0 is the active account.
// --warm applies a warm tint, as on a Night Shift screen: shows whether colors blend together.
//
// Antigravity (only with --only antigravity or antigravity-details): the summary's own `antigravity` block
// when it has one, else the built-in fixture "full". --fixture picks a fixture (full, run-out, no-quota,
// no-spend, one-day, error); --antigravity reads the block from a file (a whole summary or the block alone).

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

struct PreviewRoot: View {
    let state: UsagePanelState?
    let now: Date
    let only: String?
    let warm: Bool
    var detailAccount = 0
    var highlighted = false
    var hoverWeek: Int?
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
            if self.only == "antigravity" {
                self.card(width: self.menuWidth) { self.antigravityPage }
            }
            if self.only == "antigravity-details" {
                self.antigravityDetails
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

    /// The page as the menu would stack its rows, with a separator where a row asks for one.
    @ViewBuilder private var antigravityPage: some View {
        if let state = self.antigravity,
           let page = UsageAntigravityPage(state: state, now: self.now, width: self.menuWidth)
        {
            ForEach(Array(page.rows.enumerated()), id: \.element.id) { index, row in
                let lit = self.highlighted && row.detail != nil
                row.view
                    .environment(\.usageRowHighlighted, lit)
                    .background(lit ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                if row.separatorAfter, index < page.rows.count - 1 {
                    MenuSeparator()
                }
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
            ForEach(page.rows.filter { $0.detail != nil }) { row in
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
                            for: kind, account: account, in: state, now: self.now))
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
        UsageDriftCardView(state: state, width: self.menuWidth, initialHoverIndex: self.hoverWeek)
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
        + "[--fixture name] [--antigravity file]\n"
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let stateURL = argument(after: "--state").map { URL(fileURLWithPath: $0) } ?? UsagePanelStore.defaultURL
let state = UsagePanelStore.load(from: stateURL)
let now = argument(after: "--now").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
let only = argument(after: "--only")
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
