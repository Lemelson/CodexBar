import AppKit
import CodexBarCore
import LemelsonUsageKit
import SwiftUI

// Per-account Claude usage panel (a fork addition; upstream CodexBar does not have it).
//
// The data comes from the summary written by the Claude Switcher collector
// (`~/Library/Application Support/ClaudeSwitcher/usage/state.json`). All layout lives in the
// `LemelsonUsageKit` module; this file only inserts it into the menu. Entry points from CodexBar code:
//   • `addLemelsonUsagePanel`: at the start of `addMenuCards`;
//   • `lemelsonRootMenuWillOpen` / `lemelsonAllMenusDidClose`: in `menuWillOpen` / `menuDidClose`;
//   • `LemelsonPanelSession.shared.stockExtrasVisible`: in `addPrimaryMenuContent`.
// Keyboard and swipe paging and the page slide: `StatusItemController+LemelsonPaging.swift`.

/// Modes of the Claude and the Codex tab, switched by the row of buttons at the top of the menu. The stock
/// CodexBar card has no mode of its own: `defaults write com.steipete.codexbar lemelsonCodexPage stock` (or
/// `lemelsonAntigravityPage stock`) still brings back a stock tab.
enum LemelsonPanelMode: String, CaseIterable {
    /// Limits of every account (Claude: split into mine / not mine), with a pace mark.
    case limits
    /// Spend on this Mac.
    case spend
    /// What the plan is worth at API prices and whether the limit changes.
    case value

    var title: String {
        switch self {
        case .limits: "Limits"
        case .spend: "Spend"
        case .value: "Value"
        }
    }

    func help(for tab: LemelsonModeTab) -> String {
        switch (self, tab) {
        case (.limits, .claude): "Limits of every account: your share, others, pace"
        case (.limits, .codex): "Limits and credits of every Codex account"
        case (.limits, .overview): "Weekly limits of every account, you against others"
        case (.spend, .claude): "Your Claude Code spend on this Mac"
        case (.spend, .codex): "Your Codex spend on this Mac, by account and model"
        case (.spend, .overview): "What every subscription costs at API prices"
        case (.value, _): "What the plan is worth at API prices"
        }
    }

    /// The same mode of Overview in the layout module; Overview has no Value.
    var overviewMode: UsageOverviewMode {
        self == .spend ? .spend : .limits
    }

    /// The same mode in the layout module.
    var codexMode: UsageCodexMode {
        switch self {
        case .limits: .limits
        case .spend: .spend
        case .value: .value
        }
    }
}

/// The tabs with modes: each keeps its own mode shown last and its own pin.
enum LemelsonModeTab: String {
    case claude
    case codex
    /// Overview: Limits and Spend. `defaults write com.steipete.codexbar lemelsonOverviewLimits off` brings
    /// back the Spend-only Overview without a mode row.
    case overview

    /// The provider whose tab this is; nil for Overview, which is no provider's.
    var provider: UsageProvider? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .overview: nil
        }
    }

    /// The tab's modes in page order.
    var modes: [LemelsonPanelMode] {
        self == .overview ? [.limits, .spend] : LemelsonPanelMode.allCases
    }
}

/// The mode a tab shows, the one shown last (kept across app restarts) and the pinned one. A stored mode
/// that no longer exists (the removed "classic") reads as Limits and is cleared.
@MainActor
final class LemelsonModeStore {
    let tab: LemelsonModeTab
    let lastModeKey: String
    let pinnedModeKey: String
    private let defaults: UserDefaults

    /// The mode shown now. A menu opens in the pinned mode, or without a pin in the mode shown last.
    var mode: LemelsonPanelMode {
        didSet {
            guard self.mode != oldValue else { return }
            self.defaults.set(self.mode.rawValue, forKey: self.lastModeKey)
        }
    }

    init(tab: LemelsonModeTab, lastModeKey: String, pinnedModeKey: String, defaults: UserDefaults = .standard) {
        self.tab = tab
        self.lastModeKey = lastModeKey
        self.pinnedModeKey = pinnedModeKey
        self.defaults = defaults
        self.mode = .limits
        Self.clearUnknown(lastModeKey, in: defaults)
        Self.clearUnknown(pinnedModeKey, in: defaults)
        self.mode = self.startMode
    }

    /// A value no mode has any more (Classic) is removed, so the next start reads the default.
    private static func clearUnknown(_ key: String, in defaults: UserDefaults) {
        guard let raw = defaults.string(forKey: key), LemelsonPanelMode(rawValue: raw) == nil else { return }
        defaults.removeObject(forKey: key)
    }

    /// A stored mode, when the tab has it (Overview has no Value).
    private func stored(_ key: String) -> LemelsonPanelMode? {
        self.defaults.string(forKey: key).flatMap(LemelsonPanelMode.init(rawValue:))
            .flatMap { self.tab.modes.contains($0) ? $0 : nil }
    }

    /// The pinned mode: every menu opens in it. Nil: the menu opens in the mode shown last.
    var pinnedMode: LemelsonPanelMode? {
        get {
            self.stored(self.pinnedModeKey)
        }
        set {
            if let newValue {
                self.defaults.set(newValue.rawValue, forKey: self.pinnedModeKey)
            } else {
                self.defaults.removeObject(forKey: self.pinnedModeKey)
            }
        }
    }

    /// The mode a menu opens in.
    var startMode: LemelsonPanelMode {
        self.pinnedMode ?? self.stored(self.lastModeKey) ?? .limits
    }

    /// Pins the mode shown, or unpins it when it is the pinned one.
    func togglePin() {
        self.pinnedMode = self.pinnedMode == self.mode ? nil : self.mode
    }

    static let claude = LemelsonModeStore(
        tab: .claude, lastModeKey: "lemelsonPanelLastMode", pinnedModeKey: "lemelsonPanelDefaultMode")
    static let codex = LemelsonModeStore(
        tab: .codex, lastModeKey: "lemelsonCodexLastMode", pinnedModeKey: "lemelsonCodexDefaultMode")
    static let overview = LemelsonModeStore(
        tab: .overview, lastModeKey: UsageOverviewMode.defaultsKey, pinnedModeKey: "lemelsonOverviewDefaultMode")

    static func store(for tab: LemelsonModeTab) -> LemelsonModeStore {
        switch tab {
        case .claude: self.claude
        case .codex: self.codex
        case .overview: self.overview
        }
    }
}

/// A one-line row of a page ("Prompt cache", "Plan worth"): a low row of its own above the menu's action rows,
/// with a detail panel.
struct LemelsonLineRow {
    let id: String
    let view: AnyView
    let detail: @MainActor () -> AnyView
    let heightCacheScope: String
    let heightFingerprint: String
}

@MainActor
final class LemelsonPanelSession {
    static let shared = LemelsonPanelSession()
    /// The Claude tab's modes (last shown, pin). The Codex tab has its own: `LemelsonModeStore.codex`.
    let modes = LemelsonModeStore.claude

    /// The Claude mode shown now. A menu opens in the pinned mode, or without a pin in the mode shown last.
    var mode: LemelsonPanelMode {
        get { self.modes.mode }
        set { self.modes.mode = newValue }
    }

    /// Set while a page is built (`addLemelsonUsagePanel`), added by `addLemelsonPendingRows` at the end of the
    /// page's content, below the stock rows a mode keeps: the Claude modes' prompt cache row, a provider
    /// page's "Plan worth" and "Prompt cache".
    var pendingLineRows: [LemelsonLineRow] = []
    /// The Codex page keeps the stock "Buy Credits…" action: it goes right under the line rows, at the top of
    /// the action rows (`addLemelsonPendingRows`, the stock `makeBuyCreditsItem`).
    var pendingBuyCredits = false
    /// Width of the menu's last build, for rendering pages ahead before they were ever shown.
    var menuWidth: CGFloat = 0
    var isRefreshing = false
    var lastRefreshStarted: Date?
    /// Version of the summary the menu was built from: a newer file rebuilds the menu on open.
    var renderedStateDate: Date?
    var openSubpanels = 0
    var rebuildPending = false
    var storeRefreshPending = false
    /// A collector pass was asked for while one was running: run once more when it ends (fresh Antigravity or Codex
    /// readings arrived after the running pass had read the live file).
    var refreshAgain = false
    /// Whether the stock CodexBar rows (Cost, Usage history, Plan Usage) stay under the panel.
    var stockExtrasVisible = true
    /// With the stock rows off: the OpenAI web chart rows a page still keeps under it (the Codex page keeps
    /// Usage breakdown and Credits history, which it has no counterpart for). Nil: none.
    var keptOpenAIWebItems: StatusItemController.OpenAIWebContext?
    /// The mode whose rows are in the menu now, and rendered rows of the other modes kept for an
    /// instant switch (a fresh hosting view paints a frame late, which reads as a blink).
    var renderedMode: LemelsonPanelMode?
    var warmRows: [LemelsonPanelMode: [String: NSView]] = [:]
    var warmWidth: CGFloat = 0
    var isWarming = false
    var modeWarmTimer: Timer?
    var activeSwitchToken: String?
    var switchObservers: [NSObjectProtocol] = []
    /// In-process observers: a switch made in CodexBar's own "System Account" menu.
    var localSwitchObservers: [NSObjectProtocol] = []
    var stateWatcher: DispatchSourceFileSystemObject?
    var lastObservedStateDate: Date?

    /// The pinned Claude mode: every menu opens in it. Nil: the menu opens in the mode shown last.
    var pinnedMode: LemelsonPanelMode? {
        get { self.modes.pinnedMode }
        set { self.modes.pinnedMode = newValue }
    }

    /// The Claude mode a menu opens in.
    var startMode: LemelsonPanelMode {
        self.modes.startMode
    }

    private init() {}
}

/// Runs the usage collector: it queries the limits (following the VPN rule) and rewrites the summary.
private enum LemelsonCollectorRunner {
    /// `Process` is not `Sendable`; it is only started here and terminated from the timeout below.
    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    /// Returns when the collector exits, or after 45 seconds at most. No thread waits in the meantime.
    static func run(python: String, tick: String, switchRefresh: Bool = false) async {
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: python)
        box.process.arguments = [tick, switchRefresh ? "--switch" : "--refresh"]
        box.process.standardOutput = FileHandle.nullDevice
        box.process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.process.terminationHandler = { _ in continuation.resume() }
            do {
                try box.process.run()
            } catch {
                box.process.terminationHandler = nil
                continuation.resume()
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45) {
                if box.process.isRunning {
                    box.process.terminate()
                }
            }
        }
    }
}

/// Passes the menu row highlight on to the layout module.
struct LemelsonHighlightBridge<Content: View>: View {
    let content: Content
    /// Draws the chevron of a row whose detail panel is not a native submenu.
    var showsChevron = false
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        self.content
            .environment(\.usageRowHighlighted, self.isHighlighted)
            .overlay(alignment: .trailing) {
                if self.showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .padding(.trailing, 10)
                }
            }
    }
}

/// The submenu panel is built only when it opens, so its charts are not drawn on every menu rebuild.
private final class LemelsonSubpanelMenu: NSMenu, NSMenuDelegate {
    private var build: (() -> NSView)?
    var onClose: (() -> Void)?

    init(build: @escaping () -> NSView) {
        self.build = build
        super.init(title: "")
        self.autoenablesItems = false
        self.delegate = self
        let placeholder = NSMenuItem()
        placeholder.isEnabled = true
        self.addItem(placeholder)
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func menuNeedsUpdate(_: NSMenu) {
        guard let build = self.build, let item = self.items.first else { return }
        self.build = nil
        item.view = build()
    }

    func menuWillOpen(_ menu: NSMenu) {
        StatusMenuAppearance.pin(menu)
        LemelsonPanelSession.shared.openSubpanels += 1
        LemelsonPagingState.shared.openSubpanelMenu = menu
    }

    func menuDidClose(_: NSMenu) {
        let session = LemelsonPanelSession.shared
        session.openSubpanels = max(0, session.openSubpanels - 1)
        if LemelsonPagingState.shared.openSubpanelMenu === self {
            LemelsonPagingState.shared.openSubpanelMenu = nil
        }
        self.onClose?()
    }
}

/// The row of mode buttons and the pin: pinned, the menu always opens in that mode; unpinned, in the mode
/// shown last. The Claude, the Codex and the Overview tab each have one, with their own modes and pin.
final class LemelsonModeSwitcherView: NSView {
    private let modes: [LemelsonPanelMode]
    private var buttons: [NSButton] = []
    private let pinButton: NSButton
    private let onSelect: (LemelsonPanelMode) -> Void
    private let onPin: () -> Void
    private let preferredSize: NSSize
    private var pressed: NSButton?
    /// Whose modes these are.
    let tab: LemelsonModeTab

    init(
        tab: LemelsonModeTab = .claude,
        selected: LemelsonPanelMode,
        pinnedMode: LemelsonPanelMode?,
        width: CGFloat,
        onSelect: @escaping (LemelsonPanelMode) -> Void,
        onPin: @escaping () -> Void)
    {
        self.tab = tab
        self.modes = tab.modes
        self.onSelect = onSelect
        self.onPin = onPin
        self.preferredSize = NSSize(width: width, height: 28)
        let isPinned = selected == pinnedMode
        let pinImage = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin",
            accessibilityDescription: "Pin this mode") ?? NSImage()
        self.pinButton = NSButton(image: pinImage, target: nil, action: nil)
        super.init(frame: NSRect(origin: .zero, size: self.preferredSize))

        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        for (index, mode) in self.modes.enumerated() {
            let button = PaddedToggleButton(title: mode.title, target: nil, action: nil)
            button.tag = index
            button.toolTip = mode.help(for: tab)
            button.isBordered = false
            button.setButtonType(.toggle)
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            let isSelected = mode == selected
            button.state = isSelected ? .on : .off
            button.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
            button.contentTintColor = isSelected ? .white : .secondaryLabelColor
            row.addArrangedSubview(button)
            self.buttons.append(button)
        }

        self.pinButton.isBordered = false
        self.pinButton.imageScaling = .scaleProportionallyDown
        self.pinButton.contentTintColor = isPinned ? .controlAccentColor : .tertiaryLabelColor
        self.pinButton.toolTip = isPinned
            ? "CodexBar always opens in this mode. Click to unpin"
            : "Always open CodexBar in this mode"
        self.pinButton.translatesAutoresizingMaskIntoConstraints = false

        self.addSubview(row)
        self.addSubview(self.pinButton)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: self.pinButton.leadingAnchor, constant: -2),
            row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 26),
            self.pinButton.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -6),
            self.pinButton.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.pinButton.widthAnchor.constraint(equalToConstant: 24),
            self.pinButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize {
        self.preferredSize
    }

    override var fittingSize: NSSize {
        self.preferredSize
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    // Clicks are handled here rather than by the buttons: inside NSMenu that is more reliable (as in the account row).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let descendant = super.hitTest(point)
        if descendant != nil, descendant !== self {
            self.toolTip = (descendant as? NSButton)?.toolTip
            return self
        }
        self.toolTip = nil
        return descendant
    }

    override func mouseDown(with event: NSEvent) {
        self.pressed = self.button(at: self.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { self.pressed = nil }
        guard let pressed = self.pressed,
              self.button(at: self.convert(event.locationInWindow, from: nil)) === pressed
        else { return }
        if pressed === self.pinButton {
            self.onPin()
        } else if self.modes.indices.contains(pressed.tag) {
            self.onSelect(self.modes[pressed.tag])
        }
    }

    private func button(at point: NSPoint) -> NSButton? {
        (self.buttons + [self.pinButton]).first { self.convert($0.bounds, from: $0).contains(point) }
    }
}

extension StatusItemController {
    private static let lemelsonSubpanelWidth: CGFloat = UsageHoverPanelController.panelWidth
    static let lemelsonLimitRowPrefix = "lemelsonLimit-"
    static let lemelsonSpendAccountPrefix = "lemelsonSpendAccount-"
    private static let lemelsonWarmableModes: [LemelsonPanelMode] = [.limits, .spend, .value]

    // MARK: - Menu insertion

    /// Draws the Claude tab in the selected mode (and hands the Antigravity and Codex tabs to their pages).
    /// Returns `false` when there is no summary: the menu is then built from the stock CodexBar cards.
    func addLemelsonUsagePanel(to menu: NSMenu, context: MenuCardContext, captureMenu: NSMenu) -> Bool {
        let session = LemelsonPanelSession.shared
        session.stockExtrasVisible = true
        session.pendingLineRows = []
        session.pendingBuyCredits = false
        session.keptOpenAIWebItems = nil
        if context.menuWidth > 0 {
            session.menuWidth = context.menuWidth
        }
        // Overview rows that just left the menu are kept for the next visit.
        self.lemelsonKeepOverviewRowsLeaving(isOverview: false)
        // The Antigravity and Codex tabs are one page each (`+LemelsonProviderPages.swift`); the rows of the
        // provider page that is left are kept for the next visit.
        let providerPage = LemelsonProviderPageState.state(for: context.currentProvider)
        self.lemelsonKeepProviderRowsLeaving(except: providerPage?.provider)
        if providerPage != nil {
            return self.addLemelsonProviderPage(to: menu, context: context, captureMenu: captureMenu)
        }
        guard context.currentProvider == .claude,
              self.menuCardRenderingEnabledForController,
              let state = UsagePanelStore.load()
        else { return false }
        session.renderedStateDate = UsagePanelStore.modificationDate()

        let width = context.menuWidth
        // Every mode ends with the prompt cache row above the action rows.
        session.pendingLineRows = [Self.lemelsonClaudeCacheRow(state, width: width)].compactMap(\.self)
        self.lemelsonExchangeWarmRows(width: width)
        let switcher = NSMenuItem()
        switcher.view = LemelsonModeSwitcherView(
            tab: .claude,
            selected: session.mode,
            pinnedMode: session.pinnedMode,
            width: width,
            onSelect: { [weak self, weak captureMenu] mode in
                self?.handleLemelsonModeSelection(mode, menu: captureMenu)
            },
            onPin: { [weak self, weak captureMenu] in
                self?.handleLemelsonModePin(menu: captureMenu)
            })
        switcher.isEnabled = false
        menu.addItem(switcher)
        menu.addItem(.separator())

        let now = Date()
        switch session.mode {
        case .limits:
            self.addLemelsonLimits(state, to: menu, width: width, now: now)
        case .spend:
            self.addLemelsonSpend(state, to: menu, width: width, now: now)
        case .value:
            self.addLemelsonValue(state, to: menu, width: width, now: now)
        }
        // Spend keeps the stock "Cost" and "Usage history" rows below it: they break spend down by project and model.
        session.stockExtrasVisible = session.mode == .spend
        self.lemelsonScheduleModeWarmup()
        return true
    }

    private func addLemelsonLimits(_ state: UsagePanelState, to menu: NSMenu, width: CGFloat, now: Date) {
        let stamp = Int(state.generatedAt)
        // Captions with the age of a reading change length, so heights are re-measured every ten minutes.
        let ageBucket = Int(now.timeIntervalSince1970 / 600)
        let panelWidth = Self.lemelsonSubpanelWidth
        for (index, account) in state.claudeLimitAccounts.enumerated() {
            let style = UsageLimitCardStyle(account: account, in: state)
            let windows = account.visibleWindows
            menu.addItem(self.makeMenuCardItem(
                UsageLimitCardHeader(account: account, style: style, now: now, width: width, hasLimits: !windows.isEmpty),
                id: "lemelsonHeader-\(index)",
                width: width,
                heightCacheScope: "lemelson-claude-card-header-\(account.uuid)",
                heightCacheFingerprint: "\(stamp):\(ageBucket)",
                layout: .joined))
            for (windowIndex, (kind, window)) in windows.enumerated() {
                let id = "\(Self.lemelsonLimitRowPrefix)\(index)-\(kind.rawValue)"
                self.lemelsonRegisterDetail(.swiftUI(key: id, width: panelWidth) {
                    AnyView(UsageLimitDetailPanelView(
                        account: account,
                        kind: kind,
                        window: window,
                        now: Date(),
                        width: panelWidth,
                        sessionsLeft: UsageSessionsLeft.make(for: kind, account: account, in: state, now: Date())))
                })
                menu.addItem(self.makeMenuCardItem(
                    LemelsonHighlightBridge(content: UsageLimitCardRow(
                        kind: kind,
                        window: window,
                        style: style,
                        now: now,
                        width: width,
                        sessionsLeft: UsageSessionsLeft.make(for: kind, account: account, in: state, now: now),
                        last: windowIndex == windows.count - 1,
                        afterHeader: windowIndex == 0)),
                    id: id,
                    width: width,
                    heightCacheScope: "lemelson-claude-card-limit-\(account.uuid)-\(kind.rawValue)",
                    heightCacheFingerprint: "\(stamp):\(ageBucket)",
                    layout: .joined,
                    onClick: {}))
            }
        }
        // Always the one quiet line, as on the provider pages: refreshing or not, the page keeps its height.
        self.addLemelsonFooter(state, to: menu, width: width, now: now, showsLegend: false)
    }

    private func addLemelsonSpend(_ state: UsagePanelState, to menu: NSMenu, width: CGFloat, now: Date) {
        let stamp = Int(state.generatedAt)
        let panelWidth = Self.lemelsonSubpanelWidth
        // All Spend numbers for every period, computed once: the period switch and hovering only read them.
        let spend = UsageSpendDigest(state: state, now: now)
        // The chart's day panel, keyed by the spend row's id so warm-up and cached tab swaps keep it.
        let catalog = spend.dayDetailCatalog(now: now)
        self.lemelsonRegisterChartDayDetail(
            forRowID: UsageSpendDigest.defaultChartID,
            .swiftUI(key: catalog.panelKey, width: panelWidth) {
                AnyView(UsageDayDetailPanelView(catalog: catalog, width: panelWidth))
            })
        menu.addItem(self.makeMenuCardItem(
            UsageSpendSummaryView(state: state, now: now, width: width, spend: spend),
            id: "lemelsonSpendSummary",
            width: width,
            heightCacheScope: "lemelson-spend-summary",
            heightCacheFingerprint: "\(stamp)",
            containsInteractiveControls: true))
        menu.addItem(.separator())
        let usesPanel = !LemelsonDetailPanel.usesNativeSubmenus
        for (index, account) in state.accounts.enumerated() {
            let id = "\(Self.lemelsonSpendAccountPrefix)\(index)"
            let row = UsageSpendAccountRowView(
                account: account,
                colorIndex: index,
                width: width,
                now: now,
                totals: spend.totals(for: account))
            guard usesPanel else {
                let submenu = self.makeLemelsonSubpanel {
                    AnyView(UsageSpendAccountPanelView(
                        state: state, account: account, now: now, width: panelWidth, spend: spend))
                }
                menu.addItem(self.makeMenuCardItem(
                    LemelsonHighlightBridge(content: row),
                    id: id,
                    width: width,
                    heightCacheScope: "lemelson-spend-account",
                    heightCacheFingerprint: "row",
                    submenu: submenu,
                    submenuIndicatorAlignment: .trailing,
                    submenuIndicatorTopPadding: 0))
                continue
            }
            // The account switcher, the weeks and the models are shown by the detail panel, joined to the
            // menu like the limit rows. The empty click handler keeps the row highlightable.
            self.lemelsonRegisterDetail(.swiftUI(key: id, width: panelWidth) {
                AnyView(UsageSpendAccountPanelView(
                    state: state, account: account, now: now, width: panelWidth, spend: spend))
            })
            menu.addItem(self.makeMenuCardItem(
                LemelsonHighlightBridge(content: row, showsChevron: true),
                id: id,
                width: width,
                heightCacheScope: "lemelson-spend-account",
                heightCacheFingerprint: "row",
                onClick: {}))
        }
        menu.addItem(.separator())
        self.addLemelsonFooter(state, to: menu, width: width, now: now, showsLegend: false)
    }

    private func addLemelsonValue(_ state: UsagePanelState, to menu: NSMenu, width: CGFloat, now: Date) {
        let stamp = Int(state.generatedAt)
        menu.addItem(self.makeMenuCardItem(
            UsageValueCardView(state: state, width: width, now: now),
            id: "lemelsonValue",
            width: width,
            heightCacheScope: "lemelson-value",
            heightCacheFingerprint: "\(stamp)",
            containsInteractiveControls: true))
        menu.addItem(.separator())
        menu.addItem(self.makeMenuCardItem(
            UsageDriftCardView(state: state, width: width),
            id: "lemelsonDrift",
            width: width,
            heightCacheScope: "lemelson-drift",
            heightCacheFingerprint: "\(stamp)",
            containsInteractiveControls: true))
        menu.addItem(.separator())
        self.addLemelsonFooter(state, to: menu, width: width, now: now, showsLegend: false)
    }

    private func addLemelsonFooter(
        _ state: UsagePanelState,
        to menu: NSMenu,
        width: CGFloat,
        now: Date,
        showsLegend: Bool)
    {
        // One line on every mode, the provider pages' footer: "updated 19:14", "refreshing…", or how long the
        // collector has not run, in the warning colour.
        let refreshing = LemelsonPanelSession.shared.isRefreshing
        menu.addItem(self.makeMenuCardItem(
            UsageFooterView(
                state: state, now: now, width: width, refreshing: refreshing, showsLegend: showsLegend,
                compact: !showsLegend),
            id: "lemelsonFooter",
            width: width,
            heightCacheScope: "lemelson-footer-\(showsLegend)",
            heightCacheFingerprint: "\(Int(state.generatedAt)):\(refreshing)"))
        menu.addItem(.separator())
    }

    // MARK: - Prompt cache row

    static func lemelsonClaudeCacheRow(_ state: UsagePanelState, width: CGFloat) -> LemelsonLineRow? {
        guard let summary = UsageCacheSummary.claude(state) else { return nil }
        let panelWidth = Self.lemelsonSubpanelWidth
        return LemelsonLineRow(
            id: summary.rowID,
            view: AnyView(UsageCacheRowView(summary: summary, width: width)),
            detail: { AnyView(UsageCachePanelView(summary: summary, width: panelWidth)) },
            heightCacheScope: "lemelson-cache-claude",
            heightFingerprint: "\(Int(state.generatedAt))")
    }

    /// Hook at the end of `addPrimaryMenuContent`: the line rows of the page just built go under everything
    /// the page shows (the stock rows Spend keeps included), right above the action rows. Returns
    /// whether "Buy Credits…" goes right under them (the caller makes it with the stock item).
    func addLemelsonPendingRows(to menu: NSMenu, width: CGFloat) -> Bool {
        let session = LemelsonPanelSession.shared
        let rows = session.pendingLineRows
        let buyCredits = session.pendingBuyCredits
        session.pendingLineRows = []
        session.pendingBuyCredits = false
        self.addLemelsonLineRows(rows, to: menu, width: width)
        if buyCredits, let last = menu.items.last, !last.isSeparatorItem {
            menu.addItem(.separator())
        }
        return buyCredits
    }

    /// Low rows of their own, together between two separators, like "Status Page" below them. Hovering opens
    /// a row's detail in the panel, as a limit row does; the empty click handler keeps the row highlightable.
    func addLemelsonLineRows(_ rows: [LemelsonLineRow], to menu: NSMenu, width: CGFloat) {
        guard !rows.isEmpty else { return }
        // The page's status line, when it comes right before them, heads the group: no separator between the
        // two (on every Claude mode but Spend, whose stock rows come in between, and on the provider pages).
        let count = menu.items.count
        if count >= 2, menu.items[count - 1].isSeparatorItem, Self.lemelsonIsFooter(menu.items[count - 2]) {
            menu.removeItem(at: count - 1)
        } else if let last = menu.items.last, !last.isSeparatorItem {
            menu.addItem(.separator())
        }
        for row in rows {
            self.lemelsonRegisterDetail(.swiftUI(key: row.id, width: Self.lemelsonSubpanelWidth) { row.detail() })
            menu.addItem(self.makeMenuCardItem(
                // The row draws its own chevron, the native submenu one (larger than the limit rows').
                LemelsonHighlightBridge(content: row.view),
                id: row.id,
                width: width,
                heightCacheScope: row.heightCacheScope,
                heightCacheFingerprint: row.heightFingerprint,
                onClick: {}))
        }
        menu.addItem(.separator())
    }

    /// The one-line status row of a Claude mode ("lemelsonFooter") or of a provider page ("…-footer").
    static func lemelsonIsFooter(_ item: NSMenuItem) -> Bool {
        (item.representedObject as? String)?.lowercased().hasSuffix("footer") == true
    }

    private func makeLemelsonSubpanel(_ panel: @escaping () -> AnyView) -> NSMenu {
        let panelWidth = Self.lemelsonSubpanelWidth
        let submenu = LemelsonSubpanelMenu { [weak self] in
            let hosting = MenuHostingView(rootView: panel())
            let height = self?.hostedSubviewFittingHeight(for: hosting, width: panelWidth)
                ?? hosting.fittingSize.height
            hosting.applyMeasuredHeight(width: panelWidth, height: height)
            return hosting
        }
        submenu.minimumWidth = panelWidth
        submenu.onClose = { [weak self] in
            guard let self, LemelsonPanelSession.shared.rebuildPending,
                  LemelsonPanelSession.shared.openSubpanels == 0
            else { return }
            self.lemelsonRebuildOpenMenus()
        }
        return submenu
    }

    // MARK: - Instant mode switch

    /// Runs inside a populate pass, after the outgoing rows were harvested for recycling: keeps the
    /// rendered rows of the mode being left and hands back the rendered rows of the mode being shown.
    private func lemelsonExchangeWarmRows(width: CGFloat) {
        let session = LemelsonPanelSession.shared
        guard !session.isWarming else { return }
        if abs(session.warmWidth - width) > 0.5 {
            session.warmRows.removeAll()
            session.warmWidth = width
        }
        if let leaving = session.renderedMode, leaving != session.mode {
            var stash: [String: NSView] = [:]
            // The Antigravity and Codex pages' rows belong to another tab, not to a Claude mode.
            for (id, view) in self.menuCardViewRecyclePool
                where id.hasPrefix("lemelson") && !Self.lemelsonIsProviderPageRow(id)
                && !Self.lemelsonIsOverviewPageRow(id)
            {
                stash[id] = view
            }
            for id in stash.keys {
                self.menuCardViewRecyclePool.removeValue(forKey: id)
            }
            if !stash.isEmpty {
                session.warmRows[leaving] = stash
            }
        }
        if let warm = session.warmRows.removeValue(forKey: session.mode) {
            for (id, view) in warm where self.menuCardViewRecyclePool[id] == nil {
                self.menuCardViewRecyclePool[id] = view
            }
        }
        session.renderedMode = session.mode
    }

    /// Shortly after the menu opens, renders the rows of the modes that were not shown yet.
    /// A common-modes timer: main-actor tasks do not run while the menu tracks the pointer.
    private func lemelsonScheduleModeWarmup() {
        let session = LemelsonPanelSession.shared
        guard !session.isWarming, session.warmWidth > 0 else { return }
        guard Self.lemelsonWarmableModes.contains(where: { $0 != session.mode && session.warmRows[$0] == nil })
        else { return }
        session.modeWarmTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                LemelsonPanelSession.shared.modeWarmTimer = nil
                guard let self else { return }
                guard !self.lemelsonPostponesWarmup() else {
                    self.lemelsonScheduleModeWarmup()
                    return
                }
                self.lemelsonWarmOtherModes()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        session.modeWarmTimer = timer
    }

    private func lemelsonWarmOtherModes() {
        let session = LemelsonPanelSession.shared
        guard !self.openMenus.isEmpty, self.menuCardRenderingEnabledForController,
              let state = UsagePanelStore.load()
        else { return }
        let width = session.warmWidth
        let now = Date()
        let started = CACurrentMediaTime()
        session.isWarming = true
        defer {
            session.isWarming = false
            if UserDefaults.standard.bool(forKey: "lemelsonSelfTest") {
                let ms = Int((CACurrentMediaTime() - started) * 1000)
                Self.lemelsonLog.notice("claude modes rendered ahead in \(ms) ms")
            }
        }
        for mode in Self.lemelsonWarmableModes where mode != session.mode && session.warmRows[mode] == nil {
            let scratch = NSMenu()
            scratch.autoenablesItems = false
            switch mode {
            case .limits: self.addLemelsonLimits(state, to: scratch, width: width, now: now)
            case .spend: self.addLemelsonSpend(state, to: scratch, width: width, now: now)
            case .value: self.addLemelsonValue(state, to: scratch, width: width, now: now)
            }
            self.addLemelsonLineRows(
                [Self.lemelsonClaudeCacheRow(state, width: width)].compactMap(\.self), to: scratch, width: width)
            var rows: [String: NSView] = [:]
            for item in scratch.items {
                guard let id = item.representedObject as? String, id.hasPrefix("lemelson"),
                      let view = item.view
                else { continue }
                // Laying out now makes the first attach draw in the same frame as the switch.
                view.layoutSubtreeIfNeeded()
                item.view = nil
                rows[id] = view
            }
            scratch.removeAllItems()
            session.warmRows[mode] = rows
        }
    }

    // MARK: - Modes

    func handleLemelsonModeSelection(_ mode: LemelsonPanelMode, tab: LemelsonModeTab = .claude, menu: NSMenu?) {
        self.lemelsonSelectMode(mode, tab: tab, menu: menu)
    }

    func lemelsonModeRowItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.view is LemelsonModeSwitcherView }
    }

    /// The tab whose mode row the menu shows now, if any.
    func lemelsonModeTab(in menu: NSMenu) -> LemelsonModeTab? {
        (self.lemelsonModeRowItem(in: menu)?.view as? LemelsonModeSwitcherView)?.tab
    }

    /// Pins the mode shown, or unpins it when it is the pinned one.
    func handleLemelsonModePin(tab: LemelsonModeTab = .claude, menu: NSMenu?) {
        LemelsonModeStore.store(for: tab).togglePin()
        self.lemelsonRebuildAfterModeChange(menu: menu, tab: tab)
    }

    func lemelsonRebuildAfterModeChange(menu: NSMenu?, tab: LemelsonModeTab = .claude) {
        self.advanceMenuInteraction(for: menu)
        // Only the tab whose mode changed depends on it, so the rendered rows of the other tabs are kept.
        // Dropping them made the sibling warm-up render every tab again after each mode switch:
        // 0.2–0.3 s of main-thread work that delayed the end of the slide and the next key press.
        self.preservingMergedSwitcherContentCachesDuringInvalidation {
            self.invalidateMenus()
        }
        if let provider = tab.provider {
            self.lemelsonDropCachedContent(of: provider)
        } else {
            self.lemelsonDropCachedOverviewContent()
        }
        if let menu {
            // Overview is no provider's page: the provider the menu resolves to stands for it.
            self.deferSwitcherMenuRebuildIfStillVisible(
                menu, provider: tab.provider ?? self.resolvedMenuProvider() ?? .claude)
        }
    }

    /// Drops the merged menu's cached Overview rows (they were rendered in its other mode).
    func lemelsonDropCachedOverviewContent() {
        for key in Array(self.mergedSwitcherContentCaches.keys) {
            self.mergedSwitcherContentCaches[key]?.removeValue(forKey: .overview)
        }
    }

    /// Drops the merged menu's cached rows of one tab (they were rendered in another mode or for another account).
    func lemelsonDropCachedContent(of provider: UsageProvider) {
        for key in Array(self.mergedSwitcherContentCaches.keys) {
            let stale = self.mergedSwitcherContentCaches[key]?.keys.filter { selection in
                if case let .provider(id) = selection { return id.firstPartyProvider == provider }
                return false
            } ?? []
            for selection in stale {
                self.mergedSwitcherContentCaches[key]?.removeValue(forKey: selection)
            }
        }
    }

    // MARK: - Menu open and limits refresh

    /// The menu opens: return to the start mode (the pinned one, else the one shown last), pick up a fresh
    /// summary and request the limits. The provider tab is the author's: it stays where it was left.
    func lemelsonRootMenuWillOpen(_ menu: NSMenu) {
        // Left/right and sideways swipes page through the tabs and modes, with or without the panel.
        self.lemelsonInstallMenuEventFilter()
        LemelsonPageTransition.shared.menuWillOpen()
        LemelsonPagingState.shared.swipe.reset()
        LemelsonPagingState.shared.smoothScroll = UserDefaults.standard.bool(forKey: "lemelsonSmoothScroll")
        // The detail panel serves every tab, with or without the Claude summary.
        self.lemelsonDetailRootMenuWillOpen(menu)
        guard FileManager.default.fileExists(atPath: UsagePanelStore.defaultURL.path) else { return }
        let session = LemelsonPanelSession.shared
        // A self-test opens on its own start page, wherever the menu was left.
        let selfTest = self.lemelsonRunSelfTestIfRequested(menu: menu)
        var changed = selfTest
        if !selfTest, self.openMenus.isEmpty {
            if session.mode != session.startMode {
                session.mode = session.startMode
                changed = true
            }
            // The Codex tab and Overview return to their own start modes the same way.
            for store in [LemelsonModeStore.codex, .overview] where store.mode != store.startMode {
                store.mode = store.startMode
                changed = true
            }
        }
        let stateDate = UsagePanelStore.modificationDate()
        if stateDate != session.renderedStateDate {
            changed = true
        }
        for page in LemelsonProviderPageState.all {
            if let rendered = page.renderedStateDate, rendered != stateDate {
                changed = true
            }
        }
        if let rendered = LemelsonOverviewPageState.shared.renderedStateDate, rendered != stateDate {
            changed = true
        }
        if self.lemelsonStartRefreshIfDue() {
            changed = true
        }
        if changed {
            self.invalidateMenus()
        }
        self.lemelsonScheduleModeWarmup()
        self.lemelsonScheduleOverviewWarmup()
        self.lemelsonProviderPageMayBeShown(in: menu)
    }

    func lemelsonAllMenusDidClose() {
        let session = LemelsonPanelSession.shared
        LemelsonPageTransition.shared.menuDidClose()
        self.lemelsonDetailAllMenusDidClose()
        session.modeWarmTimer?.invalidate()
        session.modeWarmTimer = nil
        self.lemelsonCancelProviderWarmups()
        self.lemelsonCancelOverviewWarmup()
        session.openSubpanels = 0
        session.rebuildPending = false
        // The menu bar's 24-hour figure waits for the menu to close: no status item redraw while it tracks.
        self.lemelsonMenuBarSpendDidChange()
        guard session.storeRefreshPending else { return }
        session.storeRefreshPending = false
        self.lemelsonRefreshStore()
    }

    /// Starts the collector unless it ran in the last 20 seconds. The collector itself queries an account
    /// at most once every 45 seconds and follows the VPN rule. `force` (fresh Antigravity or Codex readings) skips
    /// the 20 seconds and, while a pass is running, asks for one more after it.
    @discardableResult
    func lemelsonStartRefreshIfDue(force: Bool = false, switchRefresh: Bool = false) -> Bool {
        let session = LemelsonPanelSession.shared
        guard !session.isRefreshing else {
            if force { session.refreshAgain = true }
            return false
        }
        if !force, let last = session.lastRefreshStarted, Date().timeIntervalSince(last) < 20 {
            return false
        }
        guard let collector = UsagePanelStore.load()?.collector,
              collector.tick.hasSuffix("/usage/tick.py"),
              FileManager.default.fileExists(atPath: collector.tick),
              FileManager.default.isExecutableFile(atPath: collector.python)
        else { return false }
        session.isRefreshing = true
        session.lastRefreshStarted = Date()
        let python = collector.python
        let tick = collector.tick
        Task.detached(priority: .userInitiated) { [weak self] in
            await LemelsonCollectorRunner.run(python: python, tick: tick, switchRefresh: switchRefresh)
            await self?.lemelsonRefreshDidFinish()
        }
        return true
    }

    // MARK: - Immediate refresh on Claude Switcher account switch

    private static let switcherAccountDidSwitchNotification =
        Notification.Name("com.lemelson.claudeswitcher.accountDidSwitch")
    private static let switcherUsageRefreshDidFinishNotification =
        Notification.Name("com.lemelson.claudeswitcher.usageRefreshDidFinish")

    /// Subscribes once at startup to Claude Switcher's distributed notifications and watches the usage
    /// directory for atomic `state.json` replacements so the menu bar icon, Overview, and open menu
    /// update immediately whenever an account switch completes.
    func lemelsonObserveAccountSwitches() {
        let session = LemelsonPanelSession.shared
        guard session.switchObservers.isEmpty else { return }
        let dnc = DistributedNotificationCenter.default()
        let startObs = dnc.addObserver(
            forName: Self.switcherAccountDidSwitchNotification,
            object: nil,
            queue: .main)
        { [weak self] note in
            let token = note.userInfo?["token"] as? String
            let collectorStarted = (note.userInfo?["collectorStarted"] as? Bool) ?? true
            let provider = note.userInfo?["provider"] as? String
            let uuid = note.userInfo?["uuid"] as? String
            Task { @MainActor [weak self] in
                self?.lemelsonHandleAccountDidSwitch(
                    token: token, collectorStarted: collectorStarted, provider: provider, uuid: uuid)
            }
        }
        let finishObs = dnc.addObserver(
            forName: Self.switcherUsageRefreshDidFinishNotification,
            object: nil,
            queue: .main)
        { [weak self] note in
            let token = note.userInfo?["token"] as? String
            let provider = note.userInfo?["provider"] as? String
            Task { @MainActor [weak self] in
                self?.lemelsonHandleUsageRefreshDidFinish(token: token, provider: provider)
            }
        }
        // A switch made in CodexBar's own "System Account" menu (`CodexAccountPromotionService`).
        let promoteObs = NotificationCenter.default.addObserver(
            forName: .lemelsonCodexSystemAccountDidChange,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lemelsonCodexSystemAccountDidSwitch(source: "CodexBar System Account")
            }
        }
        session.switchObservers = [startObs, finishObs]
        session.localSwitchObservers = [promoteObs]
        self.lemelsonStartStateWatcher()
        // The menu bar shows the 24-hour figure from launch, not from the first collector tick.
        self.lemelsonMenuBarSpendDidChange()
    }

    func lemelsonStopAccountSwitchObservers() {
        let session = LemelsonPanelSession.shared
        let dnc = DistributedNotificationCenter.default()
        for obs in session.switchObservers {
            dnc.removeObserver(obs)
        }
        session.switchObservers.removeAll()
        for obs in session.localSwitchObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        session.localSwitchObservers.removeAll()
        session.stateWatcher?.cancel()
        session.stateWatcher = nil
    }

    private func lemelsonStartStateWatcher() {
        let session = LemelsonPanelSession.shared
        guard session.stateWatcher == nil else { return }
        let usageDir = UsagePanelStore.defaultURL.deletingLastPathComponent()
        let fd = open(usageDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        session.lastObservedStateDate = UsagePanelStore.modificationDate()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .attrib],
            queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.lemelsonStateFileDidChange()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        session.stateWatcher = source
    }

    private func lemelsonStateFileDidChange() {
        let session = LemelsonPanelSession.shared
        guard let modDate = UsagePanelStore.modificationDate(),
              modDate != session.lastObservedStateDate
        else { return }
        session.lastObservedStateDate = modDate
        self.invalidateMenus()
        if !self.openMenus.isEmpty {
            self.lemelsonRebuildOpenMenus()
        } else {
            // A collector tick or an account switch: the menu bar's 24-hour figure follows at once
            // (while the menu is open it follows when the menu closes).
            self.lemelsonMenuBarSpendDidChange()
        }
        self.lemelsonRefreshStore()
    }

    private func lemelsonHandleAccountDidSwitch(
        token: String?,
        collectorStarted: Bool,
        provider: String? = nil,
        uuid: String? = nil)
    {
        let session = LemelsonPanelSession.shared
        if provider == "codex" {
            // The Codex page follows at once: CodexBar reads auth.json again, the new account is marked active
            // until the collector's next summary, and its read-only Codex read starts. The rebuild comes below.
            let id = uuid?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self.lemelsonCodexSystemAccountDidSwitch(
                to: id?.isEmpty == false ? id : nil, source: "Claude Switcher", rebuild: false)
        }
        session.activeSwitchToken = token
        session.renderedStateDate = nil
        session.warmRows.removeAll()
        if collectorStarted {
            session.isRefreshing = true
            session.lastRefreshStarted = Date()
        } else {
            self.lemelsonStartRefreshIfDue(force: true, switchRefresh: true)
        }
        self.invalidateMenus()
        if !self.openMenus.isEmpty {
            self.lemelsonRebuildOpenMenus()
        } else {
            self.lemelsonMenuBarSpendDidChange()
        }
        self.lemelsonRefreshStore()
    }

    private func lemelsonHandleUsageRefreshDidFinish(token: String?, provider: String? = nil) {
        let session = LemelsonPanelSession.shared
        if let active = session.activeSwitchToken, let token, active != token {
            return
        }
        if provider == "codex" {
            // The collector's pass after a Codex switch: the next build reads auth.json and the summary anew.
            self.settings.invalidateCodexAccountReconciliationSnapshotCache()
            LemelsonProviderPageState.codex.warmRows.removeAll()
            self.lemelsonDropCachedContent(of: .codex)
        }
        session.activeSwitchToken = nil
        session.isRefreshing = false
        session.lastObservedStateDate = UsagePanelStore.modificationDate()
        self.invalidateMenus()
        if !self.openMenus.isEmpty {
            self.lemelsonRebuildOpenMenus()
        } else {
            self.lemelsonMenuBarSpendDidChange()
        }
        self.lemelsonRefreshStore()
    }

    private func lemelsonRefreshDidFinish() {
        let session = LemelsonPanelSession.shared
        session.isRefreshing = false
        if session.refreshAgain {
            session.refreshAgain = false
            self.lemelsonStartRefreshIfDue(force: true)
        }
        if self.openMenus.isEmpty {
            self.invalidateMenus()
            self.lemelsonMenuBarSpendDidChange()
            self.lemelsonRefreshStore()
        } else {
            // The menu bar icon updates after the menu closes: otherwise CodexBar's data refresh would
            // rebuild the open menu once more and close the panel under the pointer.
            session.storeRefreshPending = true
            self.lemelsonRebuildOpenMenus()
        }
    }

    private func lemelsonRefreshStore() {
        Task { [weak self] in
            guard let self else { return }
            await self.store.refreshClaudeSwapAccounts()
            await self.store.refreshProvider(.claude, coalesceIfRefreshing: true)
        }
    }

    func lemelsonRebuildOpenMenus() {
        let session = LemelsonPanelSession.shared
        self.invalidateMenus()
        if session.openSubpanels > 0 {
            session.rebuildPending = true
            return
        }
        session.rebuildPending = false
        // The rebuild only goes ahead while the menu still shows the tab it is for.
        let pageKey = self.lemelsonCurrentPageKey()
        let provider: UsageProvider = if LemelsonOverviewPageState.isShown(onPage: pageKey) {
            // Overview is no provider's page: the provider the menu resolves to stands for it.
            self.resolvedMenuProvider() ?? .claude
        } else {
            LemelsonProviderPageState.state(forPageKey: pageKey)?.provider ?? .claude
        }
        for menu in self.openMenus.values where menu.supermenu == nil {
            self.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: provider)
        }
    }
}
