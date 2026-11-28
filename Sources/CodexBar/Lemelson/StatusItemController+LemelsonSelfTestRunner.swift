import AppKit
import CodexBarCore
import LemelsonUsageKit
import SwiftUI

// The self-test runner: `lemelsonSelfTest` and the plans it starts (moved out of
// `StatusItemController+LemelsonUsagePanel.swift`; the plans themselves are in
// `StatusItemController+LemelsonDetailSelfTest.swift`). See codexbar-fork/README.md, "Fast loop for UI work".

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
            // A key reaches the open menu only: none once it closed.
            guard let self, menu != nil else { return }
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
                @MainActor func walk(_ view: NSView, _ depth: Int) {
                    guard depth <= 3 else { return }
                    let name = String(describing: type(of: view))
                    let frame = NSStringFromRect(view.frame)
                    let hidden = view.isHidden
                    let alpha = view.alphaValue
                    log.notice("tree \(String(repeating: "  ", count: depth), privacy: .public)\(name, privacy: .public) \(frame, privacy: .public) hidden=\(hidden) alpha=\(alpha)")
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
        // Written for the line Overview, Codex Limits, Spend, Value, Claude Limits, Spend, Value, Antigravity,
        // opened on Claude Limits. The log names the page after each step, so another line still reads.
        // On Antigravity (the last page) its two limit rows are pointed at: the detail panel appears
        // fused to the menu and morphs from one row to the other and back. Codex Limits' first two limit rows
        // are pointed at the same way on the way back.
        let back = 1.3
        let steps: [(TimeInterval, () -> Void)] = [
            (0.7, { key(right, "right, to Spend") }),
            (1.3, { key(right, "right, to Value") }),
            (1.9, { swipe(-6, 0.5, "content-left, to Antigravity (last page)") }),
            (3.1, { key(right, "right at the end, stays") }),
            (3.5, { swipe(0.4, -9, "vertical, no page") }),
            (3.8, { highlight(0) }),
            (4.4, { highlight(1) }),
            (5.0, { highlight(0) }),
            (5.5, { highlight(nil) }),
            (4.7 + back, { key(left, "left, to Claude Value") }),
            // Two presses 50 ms apart: the second lands mid-slide.
            (5.3 + back, { key(left, "left, to Spend") }),
            (5.35 + back, { key(left, "left mid-slide, to Limits") }),
            (6.0 + back, { swipe(6, -0.5, "content-right, to Codex Value") }),
            (6.6 + back, { key(left, "left, to Codex Spend") }),
            (6.9 + back, { key(left, "left, to Codex Limits") }),
            (7.2 + back, { key(left, "left, to Overview (first page)") }),
            (7.8 + back, { key(left, "left at the start, stays") }),
            (8.3 + back, { key(right, "right, to Codex Limits") }),
            // Back again 80 ms later: the strip turns around from where it is.
            (8.38 + back, { key(left, "left mid-slide, reversal, to Overview") }),
            (8.8 + back, { key(right, "right, to Codex Limits") }),
            // Codex Limits' first two limit rows: the detail panel appears and morphs between them.
            (9.4 + back, { highlight(0) }),
            (10.0 + back, { highlight(1) }),
            (10.5 + back, { highlight(nil) }),
            (10.7 + back, { key(right, "right, to Codex Spend") }),
            (10.8 + back, { key(right, "right mid-slide, to Codex Value") }),
            (10.9 + back, { key(right, "right into Claude Limits") }),
            (11.4 + back, { highlight(0) }),
            (11.8 + back, { highlight(2) }),
            (12.9 + back, { [weak menu] in
                LemelsonPageTransition.shared.trace = nil
                menu?.cancelTracking()
            }),
        ]
        // With `lemelsonSmoothScroll` on: a slow vertical two-finger scroll and its momentum, one sample
        // per frame like a real gesture.
        var scrollSteps: [(TimeInterval, () -> Void)] = [(11.9 + back, { highlight(nil) })]
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
            scrollSteps.append((11.95 + back + Double(index) / 60, { [weak self, weak menu] in
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
        } else if UserDefaults.standard.bool(forKey: "lemelsonSelfTestValue") {
            self.lemelsonValueSelfTestPlan(menu: menu)
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
            // The timer runs on the main run loop, so the step runs on the main actor; the box only carries it
            // across the timer's @Sendable callback.
            let step = LemelsonSelfTestStep(run: action)
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { step.run() }
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

/// One step of a self-test plan, carried into a main-run-loop timer's callback and run there with
/// `MainActor.assumeIsolated` (which traps if it is ever called elsewhere).
private struct LemelsonSelfTestStep: @unchecked Sendable {
    let run: () -> Void
}
