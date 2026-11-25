import AppKit
import CodexBarCore
import LemelsonUsageKit
import os

// `lemelsonSelfTestDetail -bool YES` together with `lemelsonSelfTest -bool YES` runs a plan for the
// detail panel instead of the paging walk. Mouse events are built in the app and posted to this app's
// own event queue (`NSApp.postEvent`), never to the system: NSMenu's tracking loop dequeues them through
// the same call as real ones, so they take the real path through the event filter and the panel's
// router. Nothing moves the pointer.

extension StatusItemController {
    static var lemelsonDetailSelfTestRequested: Bool {
        UserDefaults.standard.bool(forKey: "lemelsonSelfTestDetail")
    }

    func lemelsonDetailSelfTestPlan(menu: NSMenu) -> [(TimeInterval, () -> Void)] {
        let log = Self.lemelsonLog
        let panel = UsageHoverPanelController.shared
        panel.trace = { message in
            log.notice("panel: \(message, privacy: .public)")
        }
        #if DEBUG
        var probed = 0
        LemelsonMenuEventFilter.probe = { event, mode, dequeue in
            guard dequeue, probed < 80 else { return }
            switch event.type {
            case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .scrollWheel:
                probed += 1
                let mode = mode.replacingOccurrences(of: "NSEventTrackingRunLoopMode", with: "tracking")
                log.notice("probe \(String(describing: event.type), privacy: .public) mode=\(mode, privacy: .public) window=\(event.windowNumber)")
            default:
                break
            }
        }
        #endif

        let rows: (String) -> [NSMenuItem] = { [weak menu] prefix in
            (menu?.items ?? []).filter { ($0.representedObject as? String)?.hasPrefix(prefix) == true }
        }
        let highlight: (String, Int?) -> Void = { [weak self, weak menu] prefix, index in
            guard let self, let menu else { return }
            let all = rows(prefix)
            let item = index.flatMap { all.indices.contains($0) ? all[$0] : nil }
            self.menu(menu, willHighlight: item, eventType: .mouseMoved)
            log.notice("highlight \(prefix, privacy: .public) \(index ?? -1) of \(all.count) -> panel \(panel.visibleKey ?? "hidden", privacy: .public)")
        }
        let post: (NSEvent.EventType, NSPoint, NSWindow?, String) -> Void = { type, screenPoint, window, label in
            let location = window.map { $0.convertPoint(fromScreen: screenPoint) } ?? screenPoint
            let isPress = type != .mouseMoved
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: isPress ? 1 : 0,
                pressure: type == .leftMouseDown ? 1 : 0)
            else { return }
            NSApp.postEvent(event, atStart: false)
            log.notice("post \(label, privacy: .public) at \(Int(screenPoint.x)),\(Int(screenPoint.y))")
        }
        let screenCenter: (NSView) -> NSPoint? = { view in
            guard let window = view.window else { return nil }
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            return NSPoint(x: rect.midX, y: rect.midY)
        }
        let find: (String) -> [NSView] = { name in
            guard let root = panel.visibleContentView else { return [] }
            return Self.lemelsonViews(in: root) { String(describing: type(of: $0)).contains(name) }
        }
        let segmented: () -> NSSegmentedControl? = {
            panel.visibleContentView.flatMap { root in
                Self.lemelsonViews(in: root) { $0 is NSSegmentedControl }.first as? NSSegmentedControl
            }
        }
        let describeMenu: () -> Void = { [weak self, weak menu] in
            guard let self, let menu, let window = self.lemelsonMenuWindow(of: menu) else { return }
            let table = Self.lemelsonMenuTable(in: window.contentView)
            log.notice("menu window \(String(describing: type(of: window)), privacy: .public) table=\(table.map { String(describing: type(of: $0)) } ?? "none", privacy: .public) rows=\(table?.numberOfRows ?? -1) items=\(menu.items.count)")
        }
        let spend = Self.lemelsonSpendAccountPrefix
        let menuWindow: () -> NSWindow? = { [weak self, weak menu] in
            menu.flatMap { self?.lemelsonMenuWindow(of: $0) }
        }
        let rowCenter: (Int) -> NSPoint? = { index in
            let all = rows(spend)
            guard all.indices.contains(index), let view = all[index].view else { return nil }
            return screenCenter(view)
        }
        var weekPoints: [NSPoint] = []
        return [
            (0.5, { [weak self, weak menu] in
                describeMenu()
                self?.lemelsonSelectMode(.spend, menu: menu)
            }),
            // NSMenu itself on a posted move over a row: does it highlight the row under the event?
            (1.3, {
                guard let point = rowCenter(1) else { return log.notice("no spend account rows") }
                post(.mouseMoved, point, menuWindow(), "move over account row 1 (menu window)")
            }),
            (1.7, { [weak self, weak menu] in
                let highlighted = menu.flatMap { self?.highlightedMenuItems[ObjectIdentifier($0)] }
                log.notice("after posted move: highlighted=\(highlighted?.representedObject as? String ?? "none", privacy: .public) panel=\(panel.visibleKey ?? "hidden", privacy: .public)")
            }),
            (1.9, { highlight(spend, 0) }),
            (2.4, {
                let trackers = find("TrackingView")
                weekPoints = trackers.compactMap(screenCenter)
                log.notice("panel card \(NSStringFromRect(panel.cardScreenRect), privacy: .public) week trackers=\(trackers.count)")
                guard weekPoints.count > 2 else { return }
                post(.mouseMoved, weekPoints[2], nil, "move over week 2 (no window)")
            }),
            (3.0, {
                guard weekPoints.count > 3 else { return }
                post(.mouseMoved, weekPoints[3], panel.panelWindow, "move over week 3 (panel window)")
            }),
            (3.6, {
                guard let control = segmented() else { return log.notice("no segmented control in the panel") }
                log.notice("segmented \(String(describing: type(of: control)), privacy: .public) segments=\(control.segmentCount) selected=\(control.selectedSegment)")
                guard control.segmentCount > 1, let window = control.window else { return }
                let target = (max(0, control.selectedSegment) + 1) % control.segmentCount
                let width = control.bounds.width / CGFloat(control.segmentCount)
                let local = NSRect(x: width * CGFloat(target), y: 0, width: width, height: control.bounds.height)
                let rect = window.convertToScreen(control.convert(local, to: nil))
                let point = NSPoint(x: rect.midX, y: rect.midY)
                post(.leftMouseDown, point, nil, "press segment \(target)")
                post(.leftMouseUp, point, nil, "release segment \(target)")
            }),
            (4.2, { [weak menu] in
                let control = segmented()
                log.notice("after click: segmented selected=\(control?.selectedSegment ?? -1) menu open=\(menu.map { self.openMenus[ObjectIdentifier($0)] != nil } ?? false)")
                let trackers = find("TrackingView")
                weekPoints = trackers.compactMap(screenCenter)
                log.notice("week trackers now=\(trackers.count)")
                guard weekPoints.count > 1 else { return }
                post(.mouseMoved, weekPoints[1], nil, "move over week 1 of the switched account")
            }),
            (5.0, {
                let card = panel.cardScreenRect
                post(.mouseMoved, NSPoint(x: card.minX - 90, y: card.midY), nil, "move out to the left of the panel")
            }),
            (5.7, { log.notice("after leaving: panel=\(panel.visibleKey ?? "hidden", privacy: .public)") }),
            (5.9, { highlight(spend, 1) }),
            (6.5, { highlight(spend, 2) }),
            (7.1, { highlight(Self.lemelsonLimitRowPrefix, nil) }),
            (7.8, { [weak menu] in
                panel.trace = nil
                #if DEBUG
                LemelsonMenuEventFilter.probe = nil
                #endif
                LemelsonPageTransition.shared.trace = nil
                menu?.cancelTracking()
            }),
        ]
    }

    /// `lemelsonSelfTestAdopted -bool YES`: points at every row of the opened page whose details the
    /// panel took over from a native submenu (in Claude, first switches to the mode named by
    /// `lemelsonSelfTestClaudeMode`, default Spend), then pages once with the arrow key with the panel open.
    func lemelsonAdoptedSelfTestPlan(menu: NSMenu) -> [(TimeInterval, () -> Void)] {
        let log = Self.lemelsonLog
        let panel = UsageHoverPanelController.shared
        panel.trace = { message in
            log.notice("panel: \(message, privacy: .public)")
        }
        let adopted: () -> [NSMenuItem] = { [weak self, weak menu] in
            let keys = LemelsonDetailPanelState.shared.itemKeys
            if LemelsonDetailPanel.usesNativeSubmenus {
                // The same rows with their native submenus, to compare.
                return (menu?.items ?? []).filter { item in
                    item.submenu.map { self?.isHostedSubviewMenu($0) == true } ?? false
                }
            }
            return (menu?.items ?? []).filter {
                keys[ObjectIdentifier($0)]?.hasPrefix(Self.lemelsonAdoptedKeyPrefix) == true
            }
        }
        let name: (NSMenuItem) -> String = { item in
            item.title.isEmpty ? (item.representedObject as? String ?? "?") : item.title
        }
        let popups: () -> Int = { [weak self, weak menu] in
            let root = menu.flatMap { self?.lemelsonMenuWindow(of: $0) }
            return NSApp.windows.filter {
                $0 !== root && $0.isVisible && String(describing: type(of: $0)) == "NSPopupMenuWindow"
            }.count
        }
        // `lemelsonSelfTestSteps` (integer): arrow presses before anything else, negative = left.
        let steps = UserDefaults.standard.integer(forKey: "lemelsonSelfTestSteps")
        var plan: [(TimeInterval, () -> Void)] = (0..<abs(steps)).map { index in
            (0.3 + Double(index) * 0.6, { [weak self] in
                guard let self else { return }
                let code: UInt16 = steps < 0 ? 123 : 124
                let character = String(UnicodeScalar(code == 123 ? 0xF702 : 0xF703)!)
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: code)
                else { return }
                _ = self.lemelsonHandleTrackedEvent(event)
                log.notice("step to \(self.lemelsonCurrentPageKey(), privacy: .public)")
            })
        }
        let offset = Double(abs(steps)) * 0.6
        plan += [
            (0.4, { [weak self, weak menu] in
                guard let self, let menu, steps == 0 else { return }
                if self.lemelsonCurrentPageKey().hasPrefix("claude:") {
                    let raw = UserDefaults.standard.string(forKey: "lemelsonSelfTestClaudeMode") ?? "spend"
                    self.lemelsonSelectMode(LemelsonPanelMode(rawValue: raw) ?? .spend, menu: menu)
                }
            }),
            (1.6 + offset, { [weak self] in
                let rows = adopted()
                let keys = LemelsonDetailPanelState.shared.itemKeys
                log.notice("page \(self?.lemelsonCurrentPageKey() ?? "?", privacy: .public): adopted rows=\(rows.count)")
                for item in rows {
                    let stub = item.submenu.map { $0.items.isEmpty } ?? false
                    log.notice("  \(name(item), privacy: .public) -> \(keys[ObjectIdentifier(item)] ?? "", privacy: .public) emptyStub=\(stub)")
                }
            }),
        ]
        for index in 0..<6 {
            let start = 2.0 + offset + Double(index) * 1.1
            plan.append((start, { [weak self, weak menu] in
                guard let self, let menu else { return }
                let rows = adopted()
                guard rows.indices.contains(index),
                      let (rect, window) = self.lemelsonScreenRect(of: rows[index], in: menu),
                      let event = NSEvent.mouseEvent(
                          with: .mouseMoved,
                          location: window.convertPoint(fromScreen: NSPoint(x: rect.midX, y: rect.midY)),
                          modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber,
                          context: nil,
                          eventNumber: 0,
                          clickCount: 0,
                          pressure: 0)
                else { return }
                NSApp.postEvent(event, atStart: false)
                log.notice("post move over \(name(rows[index]), privacy: .public)")
            }))
            plan.append((start + 0.6, { [weak self, weak menu] in
                guard let self, let menu, adopted().indices.contains(index) else { return }
                let highlighted = self.highlightedMenuItems[ObjectIdentifier(menu)]
                    ?? menu.highlightedItem
                log.notice("  highlighted=\(highlighted.map(name) ?? "none", privacy: .public) panel=\(panel.visibleKey ?? "hidden", privacy: .public) card=\(NSStringFromSize(panel.cardScreenRect.size), privacy: .public) native popups=\(popups())")
                if let content = panel.visibleContentView {
                    let rows = content.subviews.map {
                        "\(String(describing: type(of: $0)).prefix(40)) \(NSStringFromRect($0.frame))"
                    }.joined(separator: "; ")
                    log.notice("  content \(NSStringFromRect(content.frame), privacy: .public): \(rows, privacy: .public)")
                }
            }))
        }
        if UserDefaults.standard.bool(forKey: "lemelsonSelfTestBrowse") {
            plan += self.lemelsonBrowseSelfTestSteps(menu: menu, adopted: adopted, start: 7.0 + offset)
        }
        plan.append((9.0 + offset, { [weak self, weak menu] in
            guard let self, let menu else { return }
            let before = self.lemelsonCurrentPageKey()
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: String(UnicodeScalar(0xF703)!), charactersIgnoringModifiers: String(UnicodeScalar(0xF703)!),
                isARepeat: false, keyCode: 124)
            else { return }
            let swallowed = self.lemelsonHandleTrackedEvent(event)
            log.notice("key right with panel \(panel.visibleKey ?? "hidden", privacy: .public): \(before, privacy: .public) -> \(self.lemelsonCurrentPageKey(), privacy: .public) swallowed=\(swallowed) panel after=\(panel.visibleKey ?? "hidden", privacy: .public)")
            _ = menu
        }))
        plan.append((10.0 + offset, { [weak menu] in
            panel.trace = nil
            LemelsonPageTransition.shared.trace = nil
            menu?.cancelTracking()
        }))
        return plan
    }

    /// `lemelsonSelfTestBrowse -bool YES` (with the adopted plan): points at the cost history row, scrolls
    /// its chart inside the panel with a built scroll event, then clicks a "Browse sessions" target in it,
    /// which must close the menu and open Settings.
    private func lemelsonBrowseSelfTestSteps(
        menu: NSMenu,
        adopted: @escaping () -> [NSMenuItem],
        start: TimeInterval) -> [(TimeInterval, () -> Void)]
    {
        let log = Self.lemelsonLog
        let panel = UsageHoverPanelController.shared
        let screenRect: (NSView) -> NSRect = { view in
            view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
        }
        let scrollView: () -> NSScrollView? = {
            panel.visibleContentView.flatMap {
                Self.lemelsonViews(in: $0) { $0 is CostHistoryMenuScrollView }.first as? NSScrollView
            }
        }
        let postMouse: (NSEvent.EventType, NSPoint) -> Void = { type, point in
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { return }
            NSApp.postEvent(event, atStart: false)
        }
        return [
            (start, { [weak self, weak menu] in
                guard let self, let menu else { return }
                let keys = LemelsonDetailPanelState.shared.itemKeys
                guard let row = adopted().first(where: {
                    keys[ObjectIdentifier($0)]?.contains(Self.costHistoryChartID) == true
                }), let (rect, _) = self.lemelsonScreenRect(of: row, in: menu)
                else {
                    log.notice("browse: no cost history row on this page")
                    return
                }
                postMouse(.mouseMoved, NSPoint(x: rect.midX, y: rect.midY))
                log.notice("browse: move over the cost history row")
            }),
            (start + 0.6, {
                guard let scroll = scrollView() else {
                    log.notice("browse: no scroll view in the panel (key \(panel.visibleKey ?? "hidden", privacy: .public))")
                    return
                }
                let rect = screenRect(scroll)
                let height = NSScreen.screens.first?.frame.height ?? 0
                guard let cg = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0)
                else { return }
                // Built here and handed to this app's own queue only; never posted to the system.
                cg.location = CGPoint(x: rect.midX, y: height - rect.midY)
                guard let event = NSEvent(cgEvent: cg) else { return }
                log.notice("browse: scroll view \(NSStringFromRect(rect), privacy: .public) document=\(NSStringFromSize(scroll.documentView?.frame.size ?? .zero), privacy: .public) offset before=\(Int(scroll.contentView.bounds.origin.y))")
                NSApp.postEvent(event, atStart: false)
            }),
            (start + 0.9, {
                guard let scroll = scrollView() else { return }
                log.notice("browse: offset after scroll=\(Int(scroll.contentView.bounds.origin.y))")
            }),
            (start + 1.1, {
                guard let scroll = scrollView() else { return }
                let visible = screenRect(scroll)
                let targets = Self.lemelsonViews(in: scroll) { $0 is SessionUsageMenuActionView }
                    .map { ($0, screenRect($0)) }
                    .filter { visible.contains(NSPoint(x: $0.1.midX, y: $0.1.midY)) }
                log.notice("browse: \(targets.count) visible browse targets")
                guard let (view, rect) = targets.first else { return }
                let point = NSPoint(x: rect.midX, y: rect.midY)
                log.notice("browse: click \(view.toolTip ?? "?", privacy: .public) at \(Int(point.x)),\(Int(point.y))")
                postMouse(.leftMouseDown, point)
                postMouse(.leftMouseUp, point)
            }),
            (start + 1.7, {
                let open = LemelsonDetailPanelState.shared.openRootMenus.count
                let settings = NSApp.windows.filter { $0.isVisible && $0.title.contains("Settings") }.count
                log.notice("browse: after click: root menus open=\(open) panel=\(panel.visibleKey ?? "hidden", privacy: .public) settings windows=\(settings)")
            }),
        ]
    }

    // MARK: - Tour

    /// `lemelsonSelfTestTour -bool YES`: one walk over the rows added in message 24, with mouse events posted
    /// to the app's own queue (the real path through NSMenu's tracking loop): Claude Limits, the cache row,
    /// Spend (Accounts → Models → Accounts, then 90d), Value, Classic and its cache row, Antigravity and its
    /// cache row and Status Page, back to Classic's Status Page (the fused panel) and its "Open Status Page"
    /// row, the Codex page (its rows listed, both limit rows, the credits and reset credits facts, "Plan worth",
    /// the cache row, the rows around it, Status Page), and back to Claude, where a click on Status Page closes the menu (the
    /// self-test only logs the page it would open).
    func lemelsonTourSelfTestPlan(menu: NSMenu) -> [(TimeInterval, () -> Void)] {
        let log = Self.lemelsonLog
        let panel = UsageHoverPanelController.shared
        panel.trace = { message in
            log.notice("panel: \(message, privacy: .public)")
        }
        let tools = LemelsonSelfTestTools(controller: self, menu: menu)
        #if DEBUG
        // Which presses the tracking loops read, and in which mode (NSMenu's, or a control's own).
        LemelsonMenuEventFilter.probe = { event, mode, dequeue in
            guard dequeue, event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
            let mode = mode.replacingOccurrences(of: "NSEventTrackingRunLoopMode", with: "tracking")
            log.notice("probe \(String(describing: event.type), privacy: .public) mode=\(mode, privacy: .public) window=\(event.windowNumber) at \(NSStringFromPoint(event.locationInWindow), privacy: .public)")
        }
        #endif
        let cacheRow: () -> NSMenuItem? = { [weak menu] in
            menu?.items.first { LemelsonSelfTestTools.isCacheRow($0) }
        }
        let statusRow: () -> NSMenuItem? = { [weak menu] in
            let keys = LemelsonDetailPanelState.shared.itemKeys
            return menu?.items.first { item in
                keys[ObjectIdentifier(item)]?.hasPrefix(Self.lemelsonStatusKeyPrefix) == true
            } ?? menu?.items.first { $0.title == "Status Page" }
        }
        let hover: (String, @escaping () -> NSMenuItem?) -> [(TimeInterval, () -> Void)] = { name, find in
            [
                (0, {
                    guard let item = find() else { return log.notice("tour: no \(name, privacy: .public) row on \(tools.page(), privacy: .public)") }
                    tools.moveOver(item, label: name)
                }),
                (0.6, {
                    tools.describeHover(name, item: find())
                }),
            ]
        }
        var plan: [(TimeInterval, () -> Void)] = []
        func at(_ time: TimeInterval, _ steps: [(TimeInterval, () -> Void)]) {
            plan += steps.map { (time + $0.0, $0.1) }
        }
        // Every page's height against the room on the screen: the Claude modes here, the providers below.
        let claudeHeight: (String) -> [(TimeInterval, () -> Void)] = { label in
            [(0, { tools.describeRows(prefixes: ["lemelson"], label: label) })]
        }
        at(0.5, claudeHeight("claude:limits"))
        at(0.6, hover("cache", cacheRow))
        at(1.6, [(0, { tools.describeFooter() })])
        at(2.0, [(0, { tools.key(right: true, "right, to Spend") })])
        at(2.9, [(0, { tools.clickSegment("Models", inRow: "lemelsonSpendSummary") })])
        at(3.6, [(0, { tools.clickSegment("Accounts", inRow: "lemelsonSpendSummary") })])
        at(4.3, [(0, { tools.clickSegment("90d", inRow: "lemelsonSpendSummary") })])
        at(4.9, claudeHeight("claude:spend"))
        at(5.0, [(0, { tools.key(right: true, "right, to Value") })])
        at(5.6, claudeHeight("claude:value"))
        at(5.7, [(0, { tools.key(right: true, "right, to Classic") })])
        at(6.4, claudeHeight("claude:classic"))
        at(6.5, hover("cache", cacheRow))
        at(7.4, [(0, { tools.key(right: true, "right, to Antigravity") })])
        let codex = UsageProviderSpec.codex
        let antigravity = UsageProviderSpec.antigravity
        let row: (String) -> () -> NSMenuItem? = { [weak menu] id in
            { menu?.items.first { ($0.representedObject as? String) == id } }
        }
        at(8.0, [(0, { tools.describeRows(prefixes: [antigravity.idPrefix, antigravity.limitRowPrefix], label: "antigravity") })])
        at(8.1, hover("Antigravity plan worth", row(antigravity.idPrefix + "value")))
        at(8.8, hover("cache", cacheRow))
        at(9.5, hover("Status Page", statusRow))
        at(10.4, [(0, { tools.key(right: false, "left, to Classic") })])
        at(11.2, hover("Status Page", statusRow))
        at(12.0, [(0, { tools.moveOverPanelRow("Open Status Page") })])
        at(12.6, [(0, { tools.key(right: false, "left, to Value") })])
        at(13.1, [(0, { tools.key(right: false, "left, to Spend") })])
        at(13.6, [(0, { tools.key(right: false, "left, to Limits") })])
        at(14.2, [(0, { tools.key(right: false, "left, to Codex") })])
        // The Codex page: its two limit rows (the detail panel morphs between them), the card facts with a
        // detail (credits, limit reset credits, when CodexBar has them), "Plan worth", the cache row and the
        // rows around them.
        at(14.9, [(0, { tools.describeRows(prefixes: [codex.idPrefix, codex.limitRowPrefix], label: "codex") })])
        at(15.0, hover("Codex 5h", row(codex.limitRowPrefix + "5h")))
        at(15.7, hover("Codex 7d", row(codex.limitRowPrefix + "7d")))
        at(16.4, hover("Codex credits", row(codex.idPrefix + "fact-credits")))
        at(17.1, hover("Codex reset credits", row(codex.idPrefix + "fact-reset-credits")))
        at(17.8, hover("Codex plan worth", row(codex.idPrefix + "value")))
        at(18.5, hover("cache", cacheRow))
        at(19.2, [(0, { tools.describeFooter() })])
        at(19.4, hover("Status Page", statusRow))
        at(20.4, [(0, { tools.key(right: true, "right, back to Claude Limits") })])
        at(21.2, hover("Status Page", statusRow))
        at(22.0, [(0, {
            guard let item = statusRow() else { return }
            tools.click(item, label: "Status Page")
        })])
        at(22.8, [(0, { [weak menu] in
            log.notice("tour: end, menu open=\(menu.map { self.openMenus[ObjectIdentifier($0)] != nil } ?? false)")
            #if DEBUG
            LemelsonMenuEventFilter.probe = nil
            #endif
            panel.trace = nil
            LemelsonPageTransition.shared.trace = nil
            menu?.cancelTracking()
        })])
        return plan
    }

    /// `lemelsonSelfTestValue -bool YES` (opened on `claude:value`): the limit chart's Month | Week and unit
    /// switches in all six positions, the chart pointed at in each, then the plan card's Month | Week, then a
    /// page turn away and back. After every step the log gives each card's row height next to the height its
    /// content wants: the row is measured once, so the two must keep the same distance in every position.
    func lemelsonValueSelfTestPlan(menu: NSMenu) -> [(TimeInterval, () -> Void)] {
        let log = Self.lemelsonLog
        let tools = LemelsonSelfTestTools(controller: self, menu: menu)
        let rows = ["lemelsonValue", "lemelsonDrift"]
        var plan: [(TimeInterval, () -> Void)] = []
        var time: TimeInterval = 0.8
        func step(_ gap: TimeInterval, _ action: @escaping () -> Void) {
            plan.append((time, action))
            time += gap
        }
        step(0.4) { [weak menu] in
            let selection = UsagePanelSelection.shared
            log.notice("value: opened on \(tools.page(), privacy: .public) drift=\(selection.driftPeriod.rawValue, privacy: .public) unit=\(selection.driftUnit.rawValue, privacy: .public) plan card=\(selection.valuePeriod.rawValue, privacy: .public)")
            // Every card row of the page the menu opened on, as first measured.
            let all = (menu?.items ?? []).compactMap { $0.representedObject as? String }
                .filter { $0.hasPrefix("lemelson") }
            tools.describeHeights(of: all, label: "open")
        }
        for period in ["Month", "Week"] {
            step(0.5) { tools.clickSegment(period, inRow: "lemelsonDrift") }
            for unit in ["Opus $", "My mix", "Fable $"] {
                step(0.5) { tools.clickSegment(unit, inRow: "lemelsonDrift") }
                step(0.3) { tools.describeHeights(of: rows, label: "\(period) \(unit)") }
                for fraction in [0.08, 0.55, 0.97] {
                    step(0.35) { tools.moveOverTracker(inRow: "lemelsonDrift", fraction: fraction) }
                }
            }
        }
        step(0.5) { tools.moveOverTracker(inRow: "lemelsonDrift", fraction: nil) }
        step(0.5) { tools.clickSegment("Week", inRow: "lemelsonValue") }
        step(0.5) { tools.describeHeights(of: rows, label: "plan card Week") }
        step(0.5) { tools.clickSegment("Month", inRow: "lemelsonValue") }
        step(0.5) { tools.describeHeights(of: rows, label: "plan card Month") }
        step(0.9) { tools.key(right: false, "left, to Spend") }
        step(0.9) { tools.key(right: true, "right, back to Value") }
        step(0.4) { tools.describeHeights(of: rows, label: "after the turn") }
        step(0) { [weak menu] in
            let selection = UsagePanelSelection.shared
            log.notice("value: end drift=\(selection.driftPeriod.rawValue, privacy: .public) unit=\(selection.driftUnit.rawValue, privacy: .public) plan card=\(selection.valuePeriod.rawValue, privacy: .public)")
            LemelsonPageTransition.shared.trace = nil
            menu?.cancelTracking()
        }
        return plan
    }

    /// `lemelsonSelfTestPeek -bool YES`: the opening line of the log says on which page and with which Spend
    /// switches the menu opened; with `lemelsonSelfTestPeekClick` (a segment label, e.g. "Models") that segment
    /// of the Spend row is clicked first when the menu opened on Spend. Then the menu closes.
    func lemelsonPeekSelfTestPlan(menu: NSMenu) -> [(TimeInterval, () -> Void)] {
        let log = Self.lemelsonLog
        let tools = LemelsonSelfTestTools(controller: self, menu: menu)
        let click = UserDefaults.standard.string(forKey: "lemelsonSelfTestPeekClick")
        return [
            (0.8, {
                log.notice("peek: page \(tools.page(), privacy: .public)")
                if let click { tools.clickSegment(click, inRow: "lemelsonSpendSummary") }
            }),
            (1.6, { [weak menu] in
                let selection = UsagePanelSelection.shared
                log.notice("peek: end on \(tools.page(), privacy: .public) period=\(selection.spendPeriod.rawValue) breakdown=\(selection.spendBreakdown.rawValue, privacy: .public)")
                menu?.cancelTracking()
            }),
        ]
    }

    static func lemelsonViews(in root: NSView, where matches: (NSView) -> Bool) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if matches(view) { found.append(view) }
            for sub in view.subviews {
                visit(sub)
            }
        }
        visit(root)
        // Top to bottom on screen.
        return found.sorted { lhs, rhs in
            let l = lhs.convert(lhs.bounds, to: nil).maxY
            let r = rhs.convert(rhs.bounds, to: nil).maxY
            return l > r
        }
    }
}

/// Small actions the self-test plans share. Mouse events go to this app's own queue only.
@MainActor
struct LemelsonSelfTestTools {
    weak var controller: StatusItemController?
    weak var menu: NSMenu?

    init(controller: StatusItemController, menu: NSMenu) {
        self.controller = controller
        self.menu = menu
    }

    private var log: Logger {
        StatusItemController.lemelsonLog
    }

    /// The prompt cache row of a Claude, Antigravity or Codex page.
    static func isCacheRow(_ item: NSMenuItem) -> Bool {
        let id = item.representedObject as? String
        return id == "lemelsonCache-claude"
            || UsageProviderSpec.Key.allCases.contains { id == UsageProviderSpec.spec(for: $0).idPrefix + "cache" }
    }

    func page() -> String {
        self.controller?.lemelsonCurrentPageKey() ?? "?"
    }

    private var menuWindow: NSWindow? {
        self.menu.flatMap { self.controller?.lemelsonMenuWindow(of: $0) }
    }

    func post(_ type: NSEvent.EventType, at screenPoint: NSPoint, in window: NSWindow?) {
        let isPress = type != .mouseMoved
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: window.map { $0.convertPoint(fromScreen: screenPoint) } ?? screenPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: isPress ? 1 : 0,
            pressure: type == .leftMouseDown ? 1 : 0)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    func key(right: Bool, _ label: String) {
        guard let controller = self.controller else { return }
        let code: UInt16 = right ? 124 : 123
        let character = String(UnicodeScalar(right ? 0xF703 : 0xF702)!)
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)
        else { return }
        let before = self.page()
        _ = controller.lemelsonHandleTrackedEvent(event)
        self.log.notice("key \(label, privacy: .public): \(before, privacy: .public) -> \(self.page(), privacy: .public)")
    }

    private func rect(of item: NSMenuItem) -> (NSRect, NSWindow)? {
        guard let menu = self.menu else { return nil }
        return self.controller?.lemelsonScreenRect(of: item, in: menu)
    }

    func moveOver(_ item: NSMenuItem, label: String) {
        guard let (rect, window) = self.rect(of: item) else {
            return self.log.notice("tour: \(label, privacy: .public) row has no frame")
        }
        self.post(.mouseMoved, at: NSPoint(x: rect.midX, y: rect.midY), in: window)
        self.log.notice("tour: move over \(label, privacy: .public) on \(self.page(), privacy: .public)")
    }

    func click(_ item: NSMenuItem, label: String) {
        guard let (rect, window) = self.rect(of: item) else { return }
        let point = NSPoint(x: rect.midX, y: rect.midY)
        self.post(.leftMouseDown, at: point, in: window)
        self.post(.leftMouseUp, at: point, in: window)
        self.log.notice("tour: click \(label, privacy: .public) on \(self.page(), privacy: .public)")
    }

    func describeHover(_ label: String, item: NSMenuItem?) {
        guard let menu = self.menu, let controller = self.controller else { return }
        let panel = UsageHoverPanelController.shared
        let highlighted = controller.highlightedMenuItems[ObjectIdentifier(menu)] ?? menu.highlightedItem
        let name = highlighted.map { $0.title.isEmpty ? ($0.representedObject as? String ?? "?") : $0.title } ?? "none"
        let row = item.flatMap(self.rect(of:)).map { NSStringFromRect($0.0) } ?? "-"
        self.log.notice("tour: \(label, privacy: .public) on \(self.page(), privacy: .public): highlighted=\(name, privacy: .public) panel=\(panel.visibleKey ?? "hidden", privacy: .public) card=\(NSStringFromRect(panel.cardScreenRect), privacy: .public) row=\(row, privacy: .public) menu=\(NSStringFromRect(self.menuWindow?.frame ?? .zero), privacy: .public)")
    }

    /// Every row of the menu whose id starts with one of `prefixes`, with its frame and the height its
    /// content wants: the page's rows as built, in menu order.
    func describeRows(prefixes: [String], label: String) {
        guard let menu = self.menu else { return }
        var count = 0
        for item in menu.items {
            guard let id = item.representedObject as? String, prefixes.contains(where: id.hasPrefix) else { continue }
            count += 1
            let frame = self.rect(of: item).map { NSStringFromRect($0.0) } ?? "-"
            let wants = item.view.map { Int($0.fittingSize.height) } ?? -1
            self.log.notice("tour: \(label, privacy: .public) row \(id, privacy: .public) \(frame, privacy: .public) wants \(wants)")
        }
        let titles = menu.items.filter { !$0.isSeparatorItem && $0.view == nil }.map(\.title)
        self.log.notice("tour: \(label, privacy: .public) \(count) page rows on \(self.page(), privacy: .public); native rows: \(titles.joined(separator: " | "), privacy: .public)")
        // The whole menu against the room it has on this screen: the page fits when the first is smaller.
        let visible = (self.menuWindow?.screen ?? NSScreen.main).map { Int($0.visibleFrame.height) } ?? -1
        let window = Int(self.menuWindow?.frame.height ?? 0)
        self.log.notice("tour: \(label, privacy: .public) menu content \(Int(menu.size.height)) pt, window \(window) pt, visible \(visible) pt")
    }

    /// Frames of the rows around the cache row: it and the native rows next to it should line up.
    func describeFooter() {
        guard let menu = self.menu else { return }
        guard let index = menu.items.firstIndex(where: Self.isCacheRow) else {
            return self.log.notice("tour: no cache row")
        }
        for item in menu.items[max(0, index - 2)...min(menu.items.count - 1, index + 4)] {
            let name = item.isSeparatorItem ? "—" : (item.title.isEmpty ? (item.representedObject as? String ?? "?") : item.title)
            let frame = self.rect(of: item).map { NSStringFromRect($0.0) } ?? "-"
            self.log.notice("tour: footer row \(name, privacy: .public) \(frame, privacy: .public)")
        }
    }

    /// Presses the segment labelled `label` of a segmented control inside the row `rowID`.
    func clickSegment(_ label: String, inRow rowID: String) {
        guard let item = self.menu?.items.first(where: { ($0.representedObject as? String) == rowID }),
              let view = item.view, let window = view.window
        else { return self.log.notice("tour: no row \(rowID, privacy: .public) on \(self.page(), privacy: .public)") }
        let controls = StatusItemController.lemelsonViews(in: view) { $0 is NSSegmentedControl }
            .compactMap { $0 as? NSSegmentedControl }
        guard let control = controls.first(where: { control in
            (0..<control.segmentCount).contains { control.label(forSegment: $0) == label }
        }), let segment = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == label })
        else { return self.log.notice("tour: no segment \(label, privacy: .public) in \(rowID, privacy: .public)") }
        // Segments are as wide as their labels (or all equal, in a control that fills its width): the
        // point is placed by the labels' widths.
        let font = control.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let widths = (0..<control.segmentCount).map { index in
            control.segmentDistribution == .fillEqually
                ? 1 : (control.label(forSegment: index) ?? "").size(withAttributes: [.font: font]).width + 16
        }
        let total = widths.reduce(0, +)
        let start = widths.prefix(segment).reduce(0, +)
        let x = control.bounds.width * (start + widths[segment] / 2) / max(1, total)
        let local = NSPoint(x: x, y: control.bounds.midY)
        let point = window.convertPoint(toScreen: control.convert(local, to: nil))
        let before = control.selectedSegment
        let hit = window.contentView.flatMap { content in
            content.hitTest(content.superview?.convert(window.convertPoint(fromScreen: point), from: nil)
                ?? window.convertPoint(fromScreen: point))
        }
        let frame = control.convert(control.bounds, to: nil)
        let chain = sequence(first: control as NSView, next: \.superview).prefix(6)
            .map { String(describing: type(of: $0)).prefix(40) }.joined(separator: " < ")
        self.log.notice("tour: \(label, privacy: .public) point \(NSStringFromPoint(window.convertPoint(fromScreen: point)), privacy: .public) hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing", privacy: .public); control \(NSStringFromRect(frame), privacy: .public) hidden=\(control.isHiddenOrHasHiddenAncestor) in \(chain, privacy: .public)")
        self.post(.leftMouseDown, at: point, in: window)
        self.post(.leftMouseUp, at: point, in: window)
        self.log.notice("tour: press \(label, privacy: .public) (segment \(segment) of \(controls.count) controls, selected \(before))")
        let timer = Timer(timeInterval: 0.4, repeats: false) { _ in
            MainActor.assumeIsolated {
                let selection = UsagePanelSelection.shared
                self.log.notice("tour: after \(label, privacy: .public): selected \(control.selectedSegment) period=\(selection.spendPeriod.rawValue) breakdown=\(selection.spendBreakdown.rawValue, privacy: .public) menu open=\(self.menu.map { self.controller?.openMenus[ObjectIdentifier($0)] != nil } ?? false)")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The height of each row next to the height its content wants now (the menu measured the row once, at
    /// build time, and adds a fixed padding).
    func describeHeights(of rowIDs: [String], label: String) {
        let parts = rowIDs.map { id -> String in
            guard let view = self.menu?.items.first(where: { ($0.representedObject as? String) == id })?.view
            else { return "\(id) none" }
            let hosting = StatusItemController.lemelsonViews(in: view) {
                String(describing: type(of: $0)).hasPrefix("NSHostingView<")
            }.max { $0.frame.height < $1.frame.height }
            let wants = hosting.map { Int($0.fittingSize.height.rounded()) } ?? -1
            return "\(id) row=\(Int(view.frame.height)) wants=\(wants)"
        }
        self.log.notice("value: heights \(label, privacy: .public): \(parts.joined(separator: ", "), privacy: .public)")
    }

    /// Points at a chart of the row `rowID` (its mouse tracker) at `fraction` of its width, half-way down;
    /// nil moves to the row's top edge, off the chart.
    func moveOverTracker(inRow rowID: String, fraction: CGFloat?) {
        guard let view = self.menu?.items.first(where: { ($0.representedObject as? String) == rowID })?.view,
              let window = view.window
        else { return self.log.notice("tour: no row \(rowID, privacy: .public)") }
        guard let tracker = StatusItemController.lemelsonViews(in: view, where: {
            String(describing: type(of: $0)).contains("TrackingView")
        }).first else { return self.log.notice("tour: no chart tracker in \(rowID, privacy: .public)") }
        let chart = window.convertToScreen(tracker.convert(tracker.bounds, to: nil))
        let row = window.convertToScreen(view.convert(view.bounds, to: nil))
        let point = fraction.map { NSPoint(x: chart.minX + chart.width * $0, y: chart.midY) }
            ?? NSPoint(x: row.midX, y: row.maxY - 6)
        // A posted move does not reach the chart's tracking area (AppKit drives those from the real
        // pointer), so the built event is handed to the tracker itself, as the key presses are.
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: window.convertPoint(fromScreen: point),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0)
        else { return }
        if fraction == nil {
            tracker.mouseExited(with: event)
        } else {
            tracker.mouseMoved(with: event)
        }
        self.log.notice("value: move \(fraction.map { String(format: "%.2f", $0) } ?? "off", privacy: .public) of the chart \(NSStringFromRect(chart), privacy: .public)")
    }

    /// Moves over a row of the panel by its title (a plain action row such as "Open Status Page").
    func moveOverPanelRow(_ title: String) {
        let panel = UsageHoverPanelController.shared
        guard let content = panel.visibleContentView, let window = content.window else {
            return self.log.notice("tour: no panel for \(title, privacy: .public)")
        }
        let rows = StatusItemController.lemelsonViews(in: content) {
            String(describing: type(of: $0)).contains("ActionRow")
        }
        guard let row = rows.first else { return self.log.notice("tour: no action row in the panel") }
        let rect = window.convertToScreen(row.convert(row.bounds, to: nil))
        self.post(.mouseMoved, at: NSPoint(x: rect.midX, y: rect.midY), in: self.menuWindow)
        self.log.notice("tour: move over panel row \(title, privacy: .public) at \(NSStringFromRect(rect), privacy: .public)")
    }
}
