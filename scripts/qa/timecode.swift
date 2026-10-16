// Shows a large always-on-top running timecode (seconds since launch, 10 ms) so recordings contain
// content that identifies every moment: cut/trim checks can read the time off any exported frame.
// usage: swiftc -O scripts/qa/timecode.swift -o <bin> && <bin> [seconds=120]
import AppKit
let total = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 120 : 120
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let frame = NSRect(x: 340, y: 380, width: 1000, height: 300)
let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
w.level = .screenSaver; w.backgroundColor = .black; w.isOpaque = true; w.ignoresMouseEvents = true
let label = NSTextField(labelWithString: "T+0.00")
label.font = .monospacedDigitSystemFont(ofSize: 200, weight: .bold); label.textColor = .white
label.alignment = .center; label.frame = NSRect(x: 0, y: 40, width: 1000, height: 220); w.contentView?.addSubview(label)
w.orderFrontRegardless()
let t0 = Date()
Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
    let e = Date().timeIntervalSince(t0)
    label.stringValue = String(format: "T+%06.2f", e)
    w.backgroundColor = NSColor(hue: CGFloat((e * 0.5).truncatingRemainder(dividingBy: 1)), saturation: 0.7, brightness: 0.35, alpha: 1)
    if e > total { exit(0) }
}
app.run()
