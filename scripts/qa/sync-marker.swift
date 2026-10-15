// A/V sync marker for QA: every 2 s a white flash on the main display together with a
// 1 kHz beep (60 ms). Capture the screen + system audio while this runs, then compare the
// flash frame times with the beep onsets (scripts/qa/analyze-sync.sh).
// usage: sync-marker <seconds> [width height] ; logs "flash <seconds since start>" lines to stdout.
import AppKit
import AVFoundation

let total = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let argv = CommandLine.arguments
let winW = argv.count > 3 ? Double(argv[2]) ?? 200 : 200, winH = argv.count > 3 ? Double(argv[3]) ?? 200 : 200
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!
// Small corner window keeps the desktop usable; the flash is a 200x200 white square.
let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: winW, height: winH), styleMask: .borderless, backing: .buffered, defer: false)
win.level = .screenSaver; win.backgroundColor = .black; win.isOpaque = true
win.collectionBehavior = [.canJoinAllSpaces, .stationary]; win.orderFrontRegardless()

let engine = AVAudioEngine(), player = AVAudioPlayerNode()
let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let frames = AVAudioFrameCount(48000 * 0.06)
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
buf.frameLength = frames
for c in 0..<2 { let p = buf.floatChannelData![c]; for i in 0..<Int(frames) { p[i] = 0.5 * sinf(2 * .pi * 1000 * Float(i) / 48000) } }
engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: fmt)
try! engine.start(); player.play()

let t0 = DispatchTime.now().uptimeNanoseconds
setbuf(stdout, nil)
func secs() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 }
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    win.backgroundColor = .white; player.scheduleBuffer(buf, at: nil)
    print(String(format: "flash %.3f", secs()))
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { win.backgroundColor = .black }
    if secs() > total { app.terminate(nil) }
}
app.run()
