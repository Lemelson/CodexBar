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

/// Modes of the Claude tab, switched by the row of buttons at the top of the menu.
enum LemelsonPanelMode: String, CaseIterable {
    /// Limits of every account, split into mine / not mine, with a pace mark.
    case limits
    /// My Claude Code spend on this Mac.
    case spend
    /// What the plan is worth at API prices and whether the limit changes.
    case value
    /// The stock CodexBar card, unchanged.
    case classic

    var title: String {
        switch self {
        case .limits: "Limits"
        case .spend: "Spend"
        case .value: "Value"
        case .classic: "Classic"
        }
    }

    var help: String {
        switch self {
        case .limits: "Limits of every account: your share, others, pace"
        case .spend: "Your Claude Code spend on this Mac"
        case .value: "What the plan is worth at API prices"
        case .classic: "The original CodexBar view"
        }
    }
}

/// The prompt cache row of a page: a low row of its own above the menu's action rows, with a detail panel.
struct LemelsonCacheRow {
    let id: String
    let view: AnyView
    let detail: @MainActor () -> AnyView
    let heightCacheScope: String
    let heightFingerprint: String
}

@MainActor
final class LemelsonPanelSession {
    static let shared = LemelsonPanelSession()
    /// The pinned mode (the pin button in the mode row); unset = no pin.
    private static let pinnedModeKey = "lemelsonPanelDefaultMode"
    /// The mode shown last, kept across app restarts.
    private static let lastModeKey = "lemelsonPanelLastMode"

    /// The mode shown now. A menu opens in the pinned mode, or without a pin in the mode shown last.
    var mode: LemelsonPanelMode {
        didSet {
            guard self.mode != oldValue else { return }
            UserDefaults.standard.set(self.mode.rawValue, forKey: Self.lastModeKey)
        }
    }

    /// Set while a page is built (`addLemelsonUsagePanel`), added by `addLemelsonPendingCacheRow` at the end
    /// of the page's content, below the stock rows a mode keeps.
    var pendingCacheRow: LemelsonCacheRow?
    var isRefreshing = false
    var lastRefreshStarted: Date?
    /// Version of the summary the menu was built from: a newer file rebuilds the menu on open.
    var renderedStateDate: Date?
    var openSubpanels = 0
    var rebuildPending = false
    var storeRefreshPending = false
    /// A collector pass was asked for while one was running: run once more when it ends (fresh Antigravity
    /// readings arrived after the running pass had read the live file).
    var refreshAgain = false
    /// Whether the stock CodexBar rows (Cost, Usage history, Plan Usage) stay under the panel.
    var stockExtrasVisible = true
    /// The mode whose rows are in the menu now, and rendered rows of the other modes kept for an
    /// instant switch (a fresh hosting view paints a frame late, which reads as a blink).
    var renderedMode: LemelsonPanelMode?
    var warmRows: [LemelsonPanelMode: [String: NSView]] = [:]
    var warmWidth: CGFloat = 0
    var isWarming = false
    var modeWarmTimer: Timer?

    /// The pinned mode: every menu opens in it. Nil: the menu opens in the mode shown last.
    var pinnedMode: LemelsonPanelMode? {
        get {
            UserDefaults.standard.string(forKey: Self.pinnedModeKey).flatMap(LemelsonPanelMode.init(rawValue:))
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: Self.pinnedModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pinnedModeKey)
            }
        }
    }

    /// The mode a menu opens in.
    var startMode: LemelsonPanelMode {
        self.pinnedMode
            ?? UserDefaults.standard.string(forKey: Self.lastModeKey).flatMap(LemelsonPanelMode.init(rawValue:))
            ?? .limits
    }

    private init() {
        self.mode = .limits
        self.mode = self.startMode
    }
}

/// Runs the usage collector: it queries the limits (following the VPN rule) and rewrites the summary.
private enum LemelsonCollectorRunner {
    /// `Process` is not `Sendable`; it is only started here and terminated from the timeout below.
    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    /// Returns when the collector exits, or after 45 seconds at most. No thread waits in the meantime.
    static func run(python: String, tick: String) async {
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: python)
        box.process.arguments = [tick, "--refresh"]
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
/// shown last.
private final class LemelsonModeSwitcherView: NSView {
    private let modes = LemelsonPanelMode.allCases
    private var buttons: [NSButton] = []
    private let pinButton: NSButton
    private let onSelect: (LemelsonPanelMode) -> Void
    private let onPin: () -> Void
    private let preferredSize: NSSize
    private var pressed: NSButton?

    init(
        selected: LemelsonPanelMode,
        pinnedMode: LemelsonPanelMode?,
        width: CGFloat,
        onSelect: @escaping (LemelsonPanelMode) -> Void,
        onPin: @escaping () -> Void)
    {
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
            button.toolTip = mode.help
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

    /// Draws the Claude tab in the selected mode. Returns `false` when there is no summary or the mode is
    /// Classic: the menu is then built from the stock CodexBar cards.
    func addLemelsonUsagePanel(to menu: NSMenu, context: MenuCardContext, captureMenu: NSMenu) -> Bool {
        let session = LemelsonPanelSession.shared
        session.stockExtrasVisible = true
        session.pendingCacheRow = nil
        // The Antigravity tab is one page of its own (`+LemelsonAntigravity.swift`).
        if context.currentProvider == .antigravity {
            return self.addLemelsonAntigravityPage(to: menu, context: context)
        }
        self.lemelsonKeepAntigravityRowsLeaving()
        guard context.currentProvider == .claude,
              self.menuCardRenderingEnabledForController,
              let state = UsagePanelStore.load()
        else { return false }
        session.renderedStateDate = UsagePanelStore.modificationDate()

        let width = context.menuWidth
        // Every mode, Classic too, ends with the prompt cache row above the action rows.
        session.pendingCacheRow = Self.lemelsonClaudeCacheRow(state, width: width)
        self.lemelsonExchangeWarmRows(width: width)
        let switcher = NSMenuItem()
        switcher.view = LemelsonModeSwitcherView(
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
        case .classic:
            return false
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
        for (index, account) in state.orderedAccounts.enumerated() {
            menu.addItem(self.makeMenuCardItem(
                UsageAccountHeaderView(account: account, now: now, width: width),
                id: "lemelsonHeader-\(index)",
                width: width,
                heightCacheScope: "lemelson-header-\(account.uuid)",
                heightCacheFingerprint: "\(stamp):\(ageBucket)"))
            for (kind, window) in account.visibleWindows {
                // The detail view is shown by the hover panel, not by a native submenu: it appears at
                // once and morphs between rows. The empty click handler keeps the row highlightable.
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
                    LemelsonHighlightBridge(
                        content: UsageLimitRowView(
                        kind: kind,
                        window: window,
                        now: now,
                        width: width,
                        sessionsLeft: UsageSessionsLeft.make(for: kind, account: account, in: state, now: now)),
                        showsChevron: true),
                    id: id,
                    width: width,
                    heightCacheScope: "lemelson-limit-\(account.uuid)-\(kind.rawValue)",
                    heightCacheFingerprint: "\(stamp):\(ageBucket)",
                    onClick: {}))
            }
            menu.addItem(.separator())
        }
        self.addLemelsonFooter(state, to: menu, width: width, now: now, showsLegend: true)
    }

    private func addLemelsonSpend(_ state: UsagePanelState, to menu: NSMenu, width: CGFloat, now: Date) {
        let stamp = Int(state.generatedAt)
        let panelWidth = Self.lemelsonSubpanelWidth
        // All Spend numbers for every period, computed once: the period switch and hovering only read them.
        let spend = UsageSpendDigest(state: state, now: now)
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
        let refreshing = LemelsonPanelSession.shared.isRefreshing
        menu.addItem(self.makeMenuCardItem(
            UsageFooterView(state: state, now: now, width: width, refreshing: refreshing, showsLegend: showsLegend),
            id: "lemelsonFooter",
            width: width,
            heightCacheScope: "lemelson-footer-\(showsLegend)",
            heightCacheFingerprint: "\(Int(state.generatedAt)):\(refreshing)"))
        menu.addItem(.separator())
    }

    // MARK: - Prompt cache row

    static func lemelsonClaudeCacheRow(_ state: UsagePanelState, width: CGFloat) -> LemelsonCacheRow? {
        guard let summary = UsageCacheSummary.claude(state) else { return nil }
        let panelWidth = Self.lemelsonSubpanelWidth
        return LemelsonCacheRow(
            id: summary.rowID,
            view: AnyView(UsageCacheRowView(summary: summary, width: width)),
            detail: { AnyView(UsageCachePanelView(summary: summary, width: panelWidth)) },
            heightCacheScope: "lemelson-cache-claude",
            heightFingerprint: "\(Int(state.generatedAt))")
    }

    /// Hook at the end of `addPrimaryMenuContent`: the cache row of the page just built goes under everything
    /// the page shows (the stock rows Spend and Classic keep included), right above the action rows.
    func addLemelsonPendingCacheRow(to menu: NSMenu, width: CGFloat) {
        let session = LemelsonPanelSession.shared
        guard let row = session.pendingCacheRow else { return }
        session.pendingCacheRow = nil
        self.addLemelsonCacheRow(row, to: menu, width: width)
    }

    /// A low row of its own, between separators, like "Status Page" below it. Hovering opens its detail in
    /// the panel, as a limit row does; the empty click handler keeps the row highlightable.
    func addLemelsonCacheRow(_ row: LemelsonCacheRow, to menu: NSMenu, width: CGFloat) {
        if let last = menu.items.last, !last.isSeparatorItem {
            menu.addItem(.separator())
        }
        self.lemelsonRegisterDetail(.swiftUI(key: row.id, width: Self.lemelsonSubpanelWidth) { row.detail() })
        menu.addItem(self.makeMenuCardItem(
            // The row draws its own chevron, the native submenu one (larger than the limit rows').
            LemelsonHighlightBridge(content: row.view),
            id: row.id,
            width: width,
            heightCacheScope: row.heightCacheScope,
            heightCacheFingerprint: row.heightFingerprint,
            onClick: {}))
        menu.addItem(.separator())
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
            // The Antigravity page's rows belong to another tab, not to a Claude mode.
            for (id, view) in self.menuCardViewRecyclePool
                where id.hasPrefix("lemelson") && !Self.lemelsonIsAntigravityRow(id)
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
        session.isWarming = true
        defer { session.isWarming = false }
        for mode in Self.lemelsonWarmableModes where mode != session.mode && session.warmRows[mode] == nil {
            let scratch = NSMenu()
            scratch.autoenablesItems = false
            switch mode {
            case .limits: self.addLemelsonLimits(state, to: scratch, width: width, now: now)
            case .spend: self.addLemelsonSpend(state, to: scratch, width: width, now: now)
            case .value: self.addLemelsonValue(state, to: scratch, width: width, now: now)
            case .classic: break
            }
            if let row = Self.lemelsonClaudeCacheRow(state, width: width) {
                self.addLemelsonCacheRow(row, to: scratch, width: width)
            }
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

    func handleLemelsonModeSelection(_ mode: LemelsonPanelMode, menu: NSMenu?) {
        self.lemelsonSelectMode(mode, menu: menu)
    }

    func lemelsonModeRowItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.view is LemelsonModeSwitcherView }
    }

    /// Pins the mode shown, or unpins it when it is the pinned one.
    private func handleLemelsonModePin(menu: NSMenu?) {
        let session = LemelsonPanelSession.shared
        session.pinnedMode = session.pinnedMode == session.mode ? nil : session.mode
        self.lemelsonRebuildAfterModeChange(menu: menu)
    }

    func lemelsonRebuildAfterModeChange(menu: NSMenu?) {
        self.advanceMenuInteraction(for: menu)
        // Only the Claude tab depends on the mode, so the rendered rows of the other tabs are kept.
        // Dropping them made the sibling warm-up render every tab again after each mode switch:
        // 0.2–0.3 s of main-thread work that delayed the end of the slide and the next key press.
        self.preservingMergedSwitcherContentCachesDuringInvalidation {
            self.invalidateMenus()
        }
        for key in Array(self.mergedSwitcherContentCaches.keys) {
            let stale = self.mergedSwitcherContentCaches[key]?.keys.filter { selection in
                if case let .provider(id) = selection { return id.firstPartyProvider == .claude }
                return false
            } ?? []
            for selection in stale {
                self.mergedSwitcherContentCaches[key]?.removeValue(forKey: selection)
            }
        }
        if let menu {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .claude)
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
        var changed = self.lemelsonRunSelfTestIfRequested(menu: menu)
        if !changed, self.openMenus.isEmpty, session.mode != session.startMode {
            session.mode = session.startMode
            changed = true
        }
        let stateDate = UsagePanelStore.modificationDate()
        if stateDate != session.renderedStateDate {
            changed = true
        }
        if let rendered = LemelsonAntigravityState.shared.renderedStateDate, rendered != stateDate {
            changed = true
        }
        if self.lemelsonStartRefreshIfDue() {
            changed = true
        }
        if changed {
            self.invalidateMenus()
        }
        self.lemelsonScheduleModeWarmup()
        self.lemelsonAntigravityPageMayBeShown(in: menu)
    }

    func lemelsonAllMenusDidClose() {
        let session = LemelsonPanelSession.shared
        LemelsonPageTransition.shared.menuDidClose()
        self.lemelsonDetailAllMenusDidClose()
        session.modeWarmTimer?.invalidate()
        session.modeWarmTimer = nil
        LemelsonAntigravityState.shared.warmTimer?.invalidate()
        LemelsonAntigravityState.shared.warmTimer = nil
        session.openSubpanels = 0
        session.rebuildPending = false
        guard session.storeRefreshPending else { return }
        session.storeRefreshPending = false
        self.lemelsonRefreshStore()
    }

    /// Starts the collector unless it ran in the last 20 seconds. The collector itself queries an account
    /// at most once every 45 seconds and follows the VPN rule. `force` (fresh Antigravity readings) skips
    /// the 20 seconds and, while a pass is running, asks for one more after it.
    @discardableResult
    func lemelsonStartRefreshIfDue(force: Bool = false) -> Bool {
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
            await LemelsonCollectorRunner.run(python: python, tick: tick)
            await self?.lemelsonRefreshDidFinish()
        }
        return true
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
        let provider: UsageProvider = self.lemelsonCurrentPageKey() == UsageProvider.antigravity.rawValue
            ? .antigravity
            : .claude
        for menu in self.openMenus.values where menu.supermenu == nil {
            self.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: provider)
        }
    }
}

extension StatusItemController {
    /// `defaults write com.steipete.codexbar lemelsonSelfTest -bool YES` (`….debug` for the debug build)
    /// makes the menu drive itself
    /// after it opens, without any pointer or keyboard input, and then close: arrow keys and swipes walk
    /// the line of pages (they are built as NSEvent objects or scroll samples and handed to the same
    /// functions the event filter calls; nothing is posted to the system), then a limit row is hovered.
    /// Each step logs the page it reached:
    /// `log show --last 2m --info --predicate 'subsystem == "com.steipete.codexbar.lemelson"'`.
    /// The menu opens on the page named by `lemelsonSelfTestStart` (default `claude:limits`; `overview`,
    /// `codex`, `antigravity`, `claude:spend`, …; `keep` opens where the menu was left). Returns true when a
    /// self-test runs and its start page was set.
    func lemelsonRunSelfTestIfRequested(menu: NSMenu) -> Bool {
        guard UserDefaults.standard.bool(forKey: "lemelsonSelfTest"), menu.supermenu == nil else { return false }
        let log = Self.lemelsonLog
        let forced = self.lemelsonForceSelfTestStart(
            UserDefaults.standard.string(forKey: "lemelsonSelfTestStart") ?? "claude:limits")
        let selection = UsagePanelSelection.shared
        log.notice("self-test opens: start \(forced ? "forced" : "kept", privacy: .public) mode=\(LemelsonPanelSession.shared.mode.rawValue, privacy: .public) pinned=\(LemelsonPanelSession.shared.pinnedMode?.rawValue ?? "none", privacy: .public) period=\(selection.spendPeriod.rawValue) breakdown=\(selection.spendBreakdown.rawValue, privacy: .public)")
        LemelsonPageTransition.shared.trace = { message in
            log.notice("transition: \(message, privacy: .public)")
        }
        let page: () -> String = { [weak self] in
            self?.lemelsonCurrentPageKey() ?? "?"
        }
        let key: (UInt16, String) -> Void = { [weak self, weak menu] code, label in
            guard let self, let menu else { return }
            let character = String(UnicodeScalar(code == 123 ? 0xF702 : 0xF703)!)
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.numericPad, .function],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: character,
                charactersIgnoringModifiers: character,
                isARepeat: false,
                keyCode: code)
            else { return }
            let before = page()
            let swallowed = self.lemelsonHandleTrackedEvent(event)
            log.notice("key \(label, privacy: .public): \(before, privacy: .public) -> \(page(), privacy: .public) swallowed=\(swallowed)")
        }
        // A two-finger flick: began, travel, ended, then a long momentum tail.
        let swipe: (CGFloat, CGFloat, String) -> Void = { [weak self, weak menu] stepX, stepY, label in
            guard let self, let menu else { return }
            let before = page()
            var time = ProcessInfo.processInfo.systemUptime
            var samples = [LemelsonScrollSample(dx: 0, dy: 0, phase: .began, time: time)]
            for _ in 0..<8 {
                time += 0.008
                samples.append(LemelsonScrollSample(dx: stepX, dy: stepY, phase: .changed, time: time))
            }
            samples.append(LemelsonScrollSample(dx: 0, dy: 0, phase: .ended, time: time + 0.008))
            for _ in 0..<20 {
                time += 0.016
                samples.append(LemelsonScrollSample(
                    dx: stepX * 2, dy: stepY * 2, phase: .none, isMomentum: true, time: time))
            }
            let claimed = samples.map { self.lemelsonHandleScrollSample($0, menu: menu) }
            let count = claimed.filter(\.self).count
            log.notice("swipe \(label, privacy: .public): \(before, privacy: .public) -> \(page(), privacy: .public) claimed \(count)/\(samples.count)")
        }
        let rows: () -> [NSMenuItem] = { [weak menu] in
            (menu?.items ?? []).filter {
                ($0.representedObject as? String)?.hasPrefix(Self.lemelsonLimitRowPrefix) == true
            }
        }
        let highlight: (Int?) -> Void = { [weak self, weak menu] index in
            guard let self, let menu else { return }
            let all = rows()
            let item = index.flatMap { all.indices.contains($0) ? all[$0] : nil }
            self.menu(menu, willHighlight: item, eventType: .mouseMoved)
            let panel = UsageHoverPanelController.shared
            let row = (item?.representedObject as? String) ?? "none"
            // A document taller than the clip view means the menu scrolls (NSMenu draws an arrow).
            let scroll = Self.attachedMenuScrollView(in: menu)
            let fit = "\(Int(scroll?.documentView?.frame.height ?? -1))/\(Int(scroll?.contentView.bounds.height ?? -1))"
            if index == nil, let window = scroll?.window, let content = window.contentView {
                // What sits in the menu window besides the rows (NSMenu's scroll arrows among them).
                func walk(_ view: NSView, _ depth: Int) {
                    guard depth <= 3 else { return }
                    let name = String(describing: type(of: view))
                    log.notice("tree \(String(repeating: "  ", count: depth), privacy: .public)\(name, privacy: .public) \(NSStringFromRect(view.frame), privacy: .public) hidden=\(view.isHidden) alpha=\(view.alphaValue)")
                    for sub in view.subviews where !(sub is NSClipView) || depth < 2 {
                        walk(sub, depth + 1)
                    }
                }
                log.notice("tree window \(NSStringFromRect(window.frame), privacy: .public) screen visible \(NSStringFromRect(window.screen?.visibleFrame ?? .zero), privacy: .public)")
                walk(content, 0)
            }
            log.notice("highlight \(index ?? -1) of \(all.count) limit rows on \(page(), privacy: .public): \(row, privacy: .public) -> panel \(panel.visibleKey ?? "hidden", privacy: .public) card \(NSStringFromRect(panel.cardScreenRect), privacy: .public) menu document/clip \(fit, privacy: .public)")
        }
        let left: UInt16 = 123
        let right: UInt16 = 124
        log.notice("self-test start on \(page(), privacy: .public)")
        // Written for the line Overview, Codex, Claude Limits, Spend, Value, Classic, Antigravity, opened on
        // Claude Limits. The log names the page after each step, so another line still reads.
        // On Antigravity (the last page) its two limit rows are pointed at: the detail panel appears
        // fused to the menu and morphs from one row to the other and back.
        let back = 1.3
        let steps: [(TimeInterval, () -> Void)] = [
            (0.7, { key(right, "right, to Spend") }),
            (1.3, { key(right, "right, to Value") }),
            (1.9, { swipe(-6, 0.5, "content-left, to Classic") }),
            (2.5, { key(right, "right, to Antigravity (last page)") }),
            (3.1, { key(right, "right at the end, stays") }),
            (3.5, { swipe(0.4, -9, "vertical, no page") }),
            (3.8, { highlight(0) }),
            (4.4, { highlight(1) }),
            (5.0, { highlight(0) }),
            (5.5, { highlight(nil) }),
            (4.7 + back, { key(left, "left, to Classic") }),
            // Two presses 50 ms apart: the second lands mid-slide.
            (5.3 + back, { key(left, "left, to Value") }),
            (5.35 + back, { key(left, "left mid-slide, to Spend") }),
            (6.0 + back, { swipe(6, -0.5, "content-right, to Limits") }),
            (6.6 + back, { key(left, "left, to Codex") }),
            (7.2 + back, { key(left, "left, to Overview (first page)") }),
            (7.8 + back, { key(left, "left at the start, stays") }),
            (8.3 + back, { key(right, "right, to Codex") }),
            // Back again 80 ms later: the strip turns around from where it is.
            (8.38 + back, { key(left, "left mid-slide, reversal, to Overview") }),
            (8.8 + back, { key(right, "right, to Codex") }),
            (9.1 + back, { key(right, "right into Claude Limits") }),
            (9.6 + back, { highlight(0) }),
            (10.0 + back, { highlight(2) }),
            (11.1 + back, { [weak menu] in
                LemelsonPageTransition.shared.trace = nil
                menu?.cancelTracking()
            }),
        ]
        // With `lemelsonSmoothScroll` on: a slow vertical two-finger scroll and its momentum, one sample
        // per frame like a real gesture.
        var scrollSteps: [(TimeInterval, () -> Void)] = [(10.1 + back, { highlight(nil) })]
        let scrollStart = ProcessInfo.processInfo.systemUptime
        for index in 0...40 {
            let sample = index == 0
                ? LemelsonScrollSample(dx: 0, dy: 0, phase: .began, time: scrollStart)
                : LemelsonScrollSample(
                    dx: 0.2,
                    dy: -3,
                    phase: index <= 20 ? .changed : .none,
                    isMomentum: index > 20,
                    time: scrollStart + Double(index) / 60)
            scrollSteps.append((10.15 + back + Double(index) / 60, { [weak self, weak menu] in
                guard let self, let menu else { return }
                let scrollView = Self.attachedMenuScrollView(in: menu)
                let before = scrollView?.contentView.bounds.origin.y ?? -1
                let claimed = self.lemelsonHandleScrollSample(sample, menu: menu)
                if index == 0 || index == 40 {
                    log.notice("smooth scroll sample \(index) claimed=\(claimed) offset \(before)")
                }
            }))
        }
        // `lemelsonSelfTestHover` on top of `lemelsonSelfTest`: only hover the first and the last limit
        // row of the page the menu opened on, to look at how the detail panel joins the menu.
        let hoverOnly: [(TimeInterval, () -> Void)] = [
            (0.7, { highlight(0) }),
            (2.2, { highlight(rows().count - 1) }),
            (3.7, { [weak menu] in
                LemelsonPageTransition.shared.trace = nil
                menu?.cancelTracking()
            }),
        ]
        let plan = if UserDefaults.standard.bool(forKey: "lemelsonSelfTestTour") {
            self.lemelsonTourSelfTestPlan(menu: menu)
        } else if UserDefaults.standard.bool(forKey: "lemelsonSelfTestPeek") {
            self.lemelsonPeekSelfTestPlan(menu: menu)
        } else if UserDefaults.standard.bool(forKey: "lemelsonSelfTestAdopted") {
            self.lemelsonAdoptedSelfTestPlan(menu: menu)
        } else if Self.lemelsonDetailSelfTestRequested {
            self.lemelsonDetailSelfTestPlan(menu: menu)
        } else if UserDefaults.standard.bool(forKey: "lemelsonSelfTestHover") {
            hoverOnly
        } else {
            steps + scrollSteps
        }
        for (delay, action) in plan {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated(action)
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        return forced
    }

    /// Puts the menu on a self-test's start page before it is built. "keep" leaves it where it was.
    private func lemelsonForceSelfTestStart(_ key: String) -> Bool {
        guard key != "keep" else { return false }
        let session = LemelsonPanelSession.shared
        if key == "overview" {
            self.settings.mergedMenuLastSelectedWasOverview = true
            return true
        }
        let parts = key.split(separator: ":").map(String.init)
        guard let provider = parts.first.flatMap(UsageProvider.init(rawValue:)),
              self.store.enabledFirstPartyProvidersForDisplay().contains(provider)
        else {
            Self.lemelsonLog.notice("self-test start \(key, privacy: .public): no such tab, kept")
            return false
        }
        self.settings.mergedMenuLastSelectedWasOverview = false
        self.selectedMenuProvider = provider.instanceID
        if provider == .claude {
            session.mode = parts.dropFirst().first.flatMap(LemelsonPanelMode.init(rawValue:)) ?? .limits
        }
        return true
    }
}
