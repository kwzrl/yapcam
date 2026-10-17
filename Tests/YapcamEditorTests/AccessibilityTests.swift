import Testing
import SwiftUI
import AppKit
@testable import YapcamEditor

@MainActor @Suite struct KeyboardNavigationTests {
    private func populated() -> EditorModel {
        let m = EditorModel(project: FakeProject(durationNs: 30_000_000_000), player: FakePlayer())
        m.seek(toNs: 8_000_000_000); m.splitAtPlayhead()
        m.seek(toNs: 3_000_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 12_000_000_000); m.addHighlightAtPlayhead(); m.addText(.annotation, text: "Hello")
        m.seek(toNs: 20_000_000_000); m.addBuiltInMusic(builtInMusic[0])
        m.selection = .none
        return m
    }

    @Test func itemsAreOrderedByTimeWithSpokenLabels() {
        let items = populated().selectableItems
        #expect(items.map(\.startNs) == items.map(\.startNs).sorted())
        #expect(items.first?.label == "Clip 1" && items.first?.startNs == 0)
        let labels = items.map(\.label)
        #expect(labels.contains { $0.hasPrefix("Zoom 2.0×") } && labels.contains("Highlight region") && labels.contains("Text: Hello") && labels.contains("Music: Calm"))
    }

    @Test func downAndUpWalkThroughItemsAndWrap() {
        let m = populated(); let n = m.selectableItems.count
        #expect(m.selectAdjacent(forward: true)); let first = m.selection
        var seen = [first]
        for _ in 1..<n { m.selectAdjacent(forward: true); seen.append(m.selection) }
        #expect(Set(seen.map { "\($0)" }).count == n)                                        // visits every item once
        m.selectAdjacent(forward: true); #expect(m.selection == first)                       // wraps
        m.selectAdjacent(forward: false); #expect(m.selection == seen.last)                  // and back
        #expect(m.playheadNs == m.selectableItems.first { $0.selection == m.selection }!.startNs)   // preview follows selection
    }

    @Test func downFromNothingStartsAtThePlayhead() {
        let m = populated(); m.seek(toNs: 10_000_000_000)
        m.selectAdjacent(forward: true)
        #expect(m.selectableItems.first { $0.selection == m.selection }!.startNs >= 10_000_000_000)
    }

    @Test func editPointJumpsStopAtEveryEdgeAndAtTheEnds() {
        let m = populated(); m.seek(toNs: 0)
        var stops: [Int64] = []
        while m.jumpToEditPoint(forward: true) { stops.append(m.playheadNs) }
        #expect(stops.last == m.durationNs && stops == stops.sorted() && stops.contains(3_000_000_000) && stops.contains(8_000_000_000))
        #expect(!m.jumpToEditPoint(forward: true))
        while m.jumpToEditPoint(forward: false) {}
        #expect(m.playheadNs == 0)
    }

    @Test func nudgingMovesZoomsAndRangesWithoutAPointer() {
        let m = populated()
        let z = m.zooms[0]; m.selection = .zoom(z.id)
        m.nudgeSelection(byNs: 100_000_000); #expect(m.zooms[0].startNs == z.startNs + 100_000_000)
        m.nudgeSelection(byNs: -1_000_000_000); #expect(m.zooms[0].startNs == z.startNs - 900_000_000)
        let h = m.highlights[0]; m.selection = .highlight(h.id)
        m.nudgeSelection(byNs: 1_000_000_000); #expect(m.highlights[0].startNs == h.startNs + 1_000_000_000)
        m.selection = .clip(m.clips[0].id); let before = m.clips
        m.nudgeSelection(byNs: 100_000_000); #expect(m.clips == before)                      // clips cannot be nudged
        m.undo(); m.undo()
    }

    @Test func describeSpeaksSelectionAndTimes() {
        let m = populated(); m.selection = .zoom(m.zooms[0].id)
        #expect(m.selectionDescription == "Zoom 2.0×, 0:03.00 to 0:06.00")
        #expect(m.describe(.none) == "Nothing selected")
    }

    @Test func focusNudgeMovesTheFocusPointInsideTheFrame() {
        let m = populated(); m.selection = .zoom(m.zooms[0].id)
        m.nudgeFocus(dx: 0.05, dy: -0.05)
        #expect(abs(m.zooms[0].focusX - 0.55) < 1e-9 && abs(m.zooms[0].focusY - 0.45) < 1e-9)
        for _ in 0..<30 { m.nudgeFocus(dx: 0.05, dy: 0) }
        #expect(m.zooms[0].focusX <= 0.75)                                                  // clamped by the zoom crop
    }
}

/// Probe of the AppKit-visible part of the accessibility tree. SwiftUI-native nodes (timeline chips, transport
/// buttons) are not reachable through this API, so their labels are covered by code review and the model tests above;
/// a VoiceOver walk-through remains a manual check (see docs/status/editor.md).
@MainActor @Suite struct AccessibilityProbeTests {
    private func walk(_ element: Any, depth: Int = 0, _ visit: (NSAccessibilityProtocol) -> Void) {
        guard depth < 60, let a = element as? NSAccessibilityProtocol else { return }
        visit(a)
        var kids: [Any] = a.accessibilityChildren() ?? []
        if let v = element as? NSView { kids += v.subviews.filter { sv in !kids.contains { ($0 as AnyObject) === sv } } }
        for k in kids { walk(k, depth: depth + 1, visit) }
    }

    @Test func backgroundTypeOptionsAreTheReferenceList() {
        // The pills are SwiftUI buttons (label + selected trait); AppKit's accessibility probe cannot see SwiftUI-only nodes,
        // so this checks the option list; VoiceOver behavior of the pills is NOT verified here.
        #expect(BackgroundPanel.Mode.allCases.map(\.rawValue) == ["Wallpaper", "Gradient", "Color", "Image", "Blur"])
    }
}

@Suite struct InspectorSectionTests {
    @Test func everySectionHasATitleAndIcon() {
        #expect(InspectorSection.allCases.count == 10)
        #expect(Set(InspectorSection.allCases.map(\.title)).count == 10 && Set(InspectorSection.allCases.map(\.symbol)).count == 10)
        #expect(InspectorSection.allCases.map(\.title).contains("Keyboard shortcuts") && InspectorSection.allCases.map(\.title).contains("Animations"))
    }
}
