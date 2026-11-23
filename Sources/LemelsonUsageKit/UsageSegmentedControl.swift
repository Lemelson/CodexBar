import AppKit
import SwiftUI

/// Direct `NSSegmentedControl` wrapper for menu and hover-panel switchers.
///
/// SwiftUI's `.pickerStyle(.segmented)` (`SystemSegmentedControl`) calls
/// `accessibilitySetOverrideValue:forAttribute:` inside `updateNSView` during an active
/// `AttributeGraph` pass; inside an `NSHostingView` hosted by `NSMenu`, AppKit walks back into
/// `NSHostingView.accessibilityChildren()` -> `ViewRendererHost.updateViewGraph` ->
/// `AG::Graph::print_cycle`, hanging the menu loop on macOS 27.2 while WindowServer holds
/// `keyThief` (blocking keyboard input system-wide).
///
/// Wrapping `NSSegmentedControl` directly keeps native macOS appearance, `UsageHoverPanelController`
/// click forwarding, and self-test discovery (`$0 is NSSegmentedControl`) without touching
/// accessibility overrides during `updateNSView`.
struct UsageSegmentedControl<Option: Hashable>: NSViewRepresentable {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option
    var fillWidth: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let labels = self.options.map(self.title)
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:)))
        control.controlSize = .small
        control.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        control.segmentStyle = .automatic
        control.segmentDistribution = self.fillWidth ? .fillEqually : .fit
        control.setContentHuggingPriority(.required, for: .vertical)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        control.setContentHuggingPriority(self.fillWidth ? .defaultLow : .required, for: .horizontal)

        let selectedIndex = self.options.firstIndex(of: self.selection) ?? -1
        if control.selectedSegment != selectedIndex {
            control.selectedSegment = selectedIndex
        }

        context.coordinator.options = self.options
        context.coordinator.lastLabels = labels
        context.coordinator.selected = self.selection
        context.coordinator.setSelection = { [selection = self.$selection] value in
            selection.wrappedValue = value
        }
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.options = self.options
        context.coordinator.selected = self.selection
        context.coordinator.setSelection = { [selection = self.$selection] value in
            selection.wrappedValue = value
        }

        let labels = self.options.map(self.title)
        if context.coordinator.lastLabels != labels {
            context.coordinator.lastLabels = labels
            if control.segmentCount != labels.count {
                control.segmentCount = labels.count
            }
            for (index, label) in labels.enumerated() where control.label(forSegment: index) != label {
                control.setLabel(label, forSegment: index)
            }
        }

        let desiredDistribution: NSSegmentedControl.Distribution = self.fillWidth ? .fillEqually : .fit
        if control.segmentDistribution != desiredDistribution {
            control.segmentDistribution = desiredDistribution
        }

        let desiredIndex = self.options.firstIndex(of: self.selection) ?? -1
        if control.selectedSegment != desiredIndex {
            control.selectedSegment = desiredIndex
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context _: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let height = intrinsic.height > 0 ? intrinsic.height : 20
        if self.fillWidth, let width = proposal.width, width.isFinite {
            return CGSize(width: width, height: height)
        }
        let width = intrinsic.width > 0 ? intrinsic.width : (proposal.width ?? 0)
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var options: [Option] = []
        var lastLabels: [String] = []
        var selected: Option?
        var setSelection: ((Option) -> Void)?

        @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard self.options.indices.contains(index) else { return }
            let next = self.options[index]
            guard next != self.selected else { return }
            self.selected = next
            self.setSelection?(next)
        }
    }
}
