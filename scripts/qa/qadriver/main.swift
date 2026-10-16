// QADriver: a tiny background app that executes real-input commands for QA.
// It needs Accessibility (post events, read AX) and Screen Recording (screenshots),
// granted once by the user. Commands arrive as JSON lines in a spool directory:
//   <spool>/cmd-<n>.json  -> result written to <spool>/res-<n>.json
// ops: click{x,y,count?,button?} move{x,y} drag{x,y,x2,y2,dur} key{code,flags?}
//      type{text} shot{path,display?} ax{pid|name} status quit
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let spool = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSHomeDirectory() + "/Movies/Yapcam/QA/round3/spool")
try? FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func mouse(_ t: CGEventType, _ p: CGPoint, clicks: Int64 = 1, button: CGMouseButton = .left) {
    let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks); post(e)
}
func click(_ p: CGPoint, count: Int, right: Bool) {
    let (d, u, b): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
    mouse(.mouseMoved, p); usleep(40_000)
    for i in 1...max(1, count) { mouse(d, p, clicks: Int64(i), button: b); usleep(30_000); mouse(u, p, clicks: Int64(i), button: b); usleep(60_000) }
}
func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
    for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); e?.flags = flags; post(e); usleep(30_000) }
}
func typeText(_ s: String) {
    for ch in s.utf16 { for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down); var c = ch
        e?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(e); usleep(15_000) } }
}
func axDump(_ el: AXUIElement, _ depth: Int, _ out: inout [[String: Any]]) {
    func s(_ a: String) -> String? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, a as CFString, &v); return v as? String }
    var pos = CGPoint.zero, size = CGSize.zero; var v: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success { AXValueGetValue(v as! AXValue, .cgPoint, &pos) }
    if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success { AXValueGetValue(v as! AXValue, .cgSize, &size) }
    var acts: CFArray?; AXUIElementCopyActionNames(el, &acts)
    out.append(["d": depth, "role": s("AXRole") ?? "", "title": s("AXTitle") ?? "", "desc": s("AXDescription") ?? "", "value": s("AXValue") ?? "",
                "id": s("AXIdentifier") ?? "", "x": pos.x, "y": pos.y, "w": size.width, "h": size.height, "actions": (acts as? [String]) ?? []])
    if depth > 12 { return }
    var ch: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ch) == .success, let arr = ch as? [AXUIElement] { for c in arr { axDump(c, depth + 1, &out) } }
}
func run(_ c: [String: Any]) -> [String: Any] {
    func d(_ k: String) -> Double { (c[k] as? NSNumber)?.doubleValue ?? 0 }
    switch c["op"] as? String ?? "" {
    case "status": return ["ax": AXIsProcessTrusted(), "screen": CGPreflightScreenCaptureAccess(), "mouse": "\(CGEvent(source: nil)!.location)"]
    case "move": mouse(.mouseMoved, CGPoint(x: d("x"), y: d("y"))); return ["ok": true]
    case "click": click(CGPoint(x: d("x"), y: d("y")), count: Int(d("count")), right: (c["button"] as? String) == "right"); return ["ok": true]
    case "drag":
        let a = CGPoint(x: d("x"), y: d("y")), b = CGPoint(x: d("x2"), y: d("y2")); let n = max(2, Int(d("dur") * 60))
        mouse(.mouseMoved, a); usleep(50_000); mouse(.leftMouseDown, a)
        for i in 1...n { let t = Double(i) / Double(n); mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); usleep(16_000) }
        mouse(.leftMouseUp, b); return ["ok": true]
    case "key":
        var f = CGEventFlags(); for m in (c["flags"] as? String ?? "").split(separator: "+") {
            switch m { case "cmd": f.insert(.maskCommand); case "shift": f.insert(.maskShift); case "alt": f.insert(.maskAlternate); case "ctrl": f.insert(.maskControl); default: break } }
        key(CGKeyCode(d("code")), f); return ["ok": true]
    case "type": typeText(c["text"] as? String ?? ""); return ["ok": true]
    case "shot":
        let path = c["path"] as? String ?? "/tmp/shot.png"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = ["-x", path]
        try? p.run(); p.waitUntilExit()
        return ["ok": FileManager.default.fileExists(atPath: path)]
    case "ax":
        let name = c["name"] as? String ?? "Yapcam"
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { return ["ok": false, "err": "no app"] }
        var out: [[String: Any]] = []; axDump(AXUIElementCreateApplication(app.processIdentifier), 0, &out); return ["ok": true, "pid": app.processIdentifier, "tree": out]
    case "windows":
        let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return ["ok": true, "windows": l.map { ["owner": $0["kCGWindowOwnerName"] ?? "", "name": $0["kCGWindowName"] ?? "", "layer": $0["kCGWindowLayer"] ?? 0, "bounds": $0["kCGWindowBounds"] ?? [:]] }]
    case "quit": exit(0)
    default: return ["ok": false, "err": "unknown op"]
    }
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
print("qadriver spool=\(spool.path) ax=\(AXIsProcessTrusted()) screen=\(CGPreflightScreenCaptureAccess())")
if !AXIsProcessTrusted() { AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    let files = (try? FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)) ?? []
    for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.lastPathComponent.hasPrefix("cmd-") && f.pathExtension == "json" {
        let id = f.deletingPathExtension().lastPathComponent.dropFirst(4)
        let cmd = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: f))) as? [String: Any]) ?? [:]
        try? FileManager.default.removeItem(at: f)
        let res = run(cmd)
        let data = (try? JSONSerialization.data(withJSONObject: res)) ?? Data()
        try? data.write(to: spool.appendingPathComponent("res-\(id).tmp")); try? FileManager.default.moveItem(at: spool.appendingPathComponent("res-\(id).tmp"), to: spool.appendingPathComponent("res-\(id).json"))
    }
}
app.run()
