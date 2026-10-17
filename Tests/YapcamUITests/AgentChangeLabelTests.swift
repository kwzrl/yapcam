import Foundation
import Testing
@testable import YapcamUI

@MainActor @Suite struct AgentChangeLabelTests {
    @Test func readsAndNavigationNeverCreateChanges() {
        for name in ["seek", "select", "read_project", "read_events", "capture", "grab", "filmstrip", "waveform", "moments", "check", "transcription_status", "list_documents", "save"] {
            #expect(AgentServer.changeLabels(name: name, args: [:]).isEmpty)
        }
        #expect(AgentServer.changeLabels(name: "tighten_pauses", args: [:], result: ["changed": false]).isEmpty)
        #expect(AgentServer.changeLabels(name: "apply", args: ["command": ["op": "set"]], result: ["changed": [String]()]).isEmpty)
    }
    @Test func labelsDescribeEditorActions() {
        func label(_ command: [String: Any]) -> String { AgentServer.changeLabels(name: "apply", args: ["command": command]).first?.label ?? "" }
        #expect(label(["op": "delete_range", "tl_start_ns": 12_000_000_000, "tl_end_ns": 14_000_000_000, "text": "um"]) == "Cut 0:12–0:14 ‘um’")
        #expect(label(["op": "add_zoom", "tl_start_ns": 42_000_000_000, "scale": 1.8]) == "Zoom 1.8× 0:42")
        #expect(label(["op": "set", "path": "canvas.padding_ratio", "value": 0.1]) == "Padding 10 %")
        #expect(label(["op": "set", "path": "canvas.padding", "value": 48]) == "Padding 48 px")
        #expect(label(["op": "set", "path": "canvas.background", "value": ["kind": "image", "wallpaper_id": "sonoma"]]) == "Background: wallpaper Sonoma")
        #expect(label(["op": "add_caption", "record": ["text": "Edited by Claude", "tl_start_ns": 0]]) == "Caption ‘Edited by Claude’ 0:00")
        #expect(AgentServer.changeLabels(name: "tighten_pauses", args: [:], result: ["removed_count": 3]).first?.label == "Tightened 3 pauses")
        #expect(AgentServer.changeLabels(name: "zoom_on_click", args: [:], result: ["at_s": 42]).first?.label == "Zoom 1.8× on click 0:42")
    }
    @Test func nestedBatchesFlattenAndLongTextStaysReadable() {
        let changes = AgentServer.changeLabels(name: "batch", args: ["commands": [["op": "batch", "commands": [["op": "split", "at_tl_ns": 1_000_000_000], ["op": "coalesced_edit", "command": ["op": "set_speed", "speed": 2]]]]]])
        #expect(changes.map(\.label) == ["Split clip 0:01", "Clip speed 2×"])
        let caption = AgentServer.changeLabels(name: "apply", args: ["command": ["op": "add_caption", "record": ["text": String(repeating: "x", count: 1000), "tl_start_ns": 0]]])
        #expect(caption[0].label.count < 100)
    }
}
