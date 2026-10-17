import Testing
import SwiftUI
import AppKit
@testable import YapcamEditor

@MainActor @Suite(.serialized) struct SliderLayoutTests {
    private func allSliders(_ v: NSView) -> [NSSlider] {
        var out: [NSSlider] = []; if let s = v as? NSSlider { out.append(s) }
        for c in v.subviews { out += allSliders(c) }; return out
    }

    @Test func inspectorSlidersFillTheRowAtTheRealInspectorWidth() async throws {
        _ = NSApplication.shared
        let m = EditorModel(project: FakeProject(durationNs: 10_000_000_000), player: FakePlayer())
        for section in InspectorSection.allCases {
            m.inspectorSection = section
            let host = NSHostingView(rootView: InspectorView(model: m, initialSection: section).frame(width: 450, height: 700))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.orderBack(nil); defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded()
            let found = allSliders(host)
            if [InspectorSection.background, .cursor, .animations].contains(section) { #expect(!found.isEmpty, "no sliders found in \(section)") }
            let widths = found.map { Int($0.frame.width) }
            print("SLIDERS \(section): \(widths) host=\(host.bounds.width) abs=\(found.map { host.convert($0.bounds, from: $0) })")
            // Row = inspector width − rail − form margins; track must get what is left after label, value, reset slot and gaps.
            let rowWidth = 450 - 54 - 8 - 2 * 30 as CGFloat       // rail 54 pt, card 8 pt from the window edge; the grouped form insets rows by 30 pt each side
            let minTrack = rowWidth - SliderRow<EmptyView>.labelWidth - EditorMetrics.valueWidth - EditorMetrics.resetSlot - 3 * EditorMetrics.s - 4
            for (s, w) in zip(found, widths) { #expect(CGFloat(w) >= minTrack, "\(section): slider \(w) pt < \(minTrack) pt (\(s.frame))") }
        }
    }
}
