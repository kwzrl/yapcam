import Testing
import SwiftUI
import AppKit
import YapcamDesign
@testable import YapcamEditor

@MainActor @Suite(.serialized) struct SliderLayoutTests {
    /// Kit sliders sit in fixed columns (slider, value, reset slot) so every slider of a section lines up; the label column
    /// that is left in the 300-pt content column must hold the usual labels on one line ("Rounded corners", "Shadow intensity").
    @Test func inspectorSlidersLineUpAtTheRealInspectorWidth() {
        let content = Yap.Inspector.column - 2 * Yap.Inspector.gutter
        let label = content - Yap.Inspector.slider - Yap.Inspector.readout - Yap.Inspector.resetSlot - 4 * Yap.Inspector.gap   // label, spacer, slider, value, reset
        #expect(label >= 100, "label column \(label) pt")
        #expect(Yap.Inspector.slider >= 90)
    }

    /// Every section renders in the docked width without a system slider (those drew the blue accent).
    @Test func sectionsRenderWithoutSystemSliders() async throws {
        let m = EditorModel(project: FakeProject(durationNs: 10_000_000_000), player: FakePlayer())
        func sliders(_ v: NSView) -> [NSSlider] { [v as? NSSlider].compactMap { $0 } + v.subviews.flatMap(sliders) }
        for section in InspectorSection.allCases {
            m.inspectorSection = section
            let host = NSHostingView(rootView: InspectorView(model: m, initialSection: section).frame(width: InspectorView.width, height: 700))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: InspectorView.width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.orderBack(nil); defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
            #expect(sliders(host).isEmpty, "\(section) still uses NSSlider")
        }
    }
}
