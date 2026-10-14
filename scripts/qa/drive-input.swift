// Scripted input for QA: moves the cursor and clicks at known times, prints a
// JSON log of what was posted (host-relative ms) to compare with events.jsonl.
// usage: swift scripts/qa/drive-input.swift   (needs Accessibility permission)
import CoreGraphics
import Foundation

struct Step { let atMs: Int; let x: Double; let y: Double; let click: Bool }
let steps = [Step(atMs: 0, x: 200, y: 200, click: false),
             Step(atMs: 500, x: 600, y: 400, click: true),
             Step(atMs: 1500, x: 1200, y: 700, click: true),
             Step(atMs: 2500, x: 300, y: 800, click: false)]
let start = DispatchTime.now().uptimeNanoseconds
func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
var log: [[String: Any]] = []
for s in steps {
    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    if s.atMs > elapsed { usleep(UInt32((s.atMs - elapsed) * 1000)) }
    let p = CGPoint(x: s.x, y: s.y)
    post(.mouseMoved, p)
    log.append(["ms": Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000), "type": "move", "x": s.x, "y": s.y])
    if s.click {
        post(.leftMouseDown, p); usleep(80_000); post(.leftMouseUp, p)
        log.append(["ms": Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000), "type": "click", "x": s.x, "y": s.y])
    }
}
let data = try! JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted])
print(String(data: data, encoding: .utf8)!)
