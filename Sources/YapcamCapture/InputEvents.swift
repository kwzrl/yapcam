import AppKit
import CryptoKit

struct CaptureEvent: Codable, Equatable, Sendable {
    var t: Int64
    var type: String
    var x: Double? = nil
    var y: Double? = nil
    var button: String? = nil
    var dx: Double? = nil
    var dy: Double? = nil
    var id: Int? = nil
    var key: String? = nil
    var modifiers: [String]? = nil
}

struct CursorMetadata: Codable, Sendable {
    var file: String
    var hotspot: [Double]
    var sizePoints: [Double]
    enum CodingKeys: String, CodingKey { case file, hotspot, sizePoints = "size_points" }
}

/// The tap is attached only to the main run loop. File writes are small, buffered by
/// the OS and synchronized at segment close; keystrokes are opt-in at the tap mask.
@MainActor final class InputEventRecorder {
    private let directory: URL
    private var mapping: CaptureCoordinateMapping
    private let outputSize: CGSize
    private let hostStartNs: Int64
    private let keys: Bool
    private var file: FileHandle?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var monitor: Any?
    private var timer: Timer?
    private var lastTime: Int64 = 0
    private var cursorIDs: [String: Int] = [:]
    private var cursors: [String: CursorMetadata] = [:]
    private var currentCursor: Int?
    private var lastPoint: CGPoint?
    private var failed = false
    var warning: ((String) -> Void)?
    var failure: ((CaptureError) -> Void)?

    init(directory: URL, rect: CGRect, hostStartNs: Int64, keys: Bool) {
        self.directory = directory; self.hostStartNs = hostStartNs; self.keys = keys
        self.outputSize = rect.size
        self.mapping = CaptureCoordinateMapping(source: rect, destination: CGRect(origin: .zero, size: rect.size))
    }

    func start() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("cursors"), withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw CaptureError.writerFailed("Cannot create event log") }
        file = try FileHandle(forWritingTo: path)
        var types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        if keys { types.append(.keyDown) }
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                               eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let recorder = Unmanaged<InputEventRecorder>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = recorder.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else { recorder.consume(event, type: type) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            var mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
            if keys { mask.insert(.keyDown) }
            monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let cg = event.cgEvent else { return }
                    self?.consume(cg, type: cg.type)
                }
            }
            warning?("Input event tap unavailable; using the global event monitor. Enable Input Monitoring for complete click/key capture.")
        }
        // Cursor shapes are not CGEvents. Poll the system cursor, and also keep move
        // positions available when permissions prevent global event delivery.
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        if let point = CGEvent(source: nil)?.location, point != lastPoint {
            lastPoint = point
            let local = mapping.local(point)
            emit(CaptureEvent(t: relative(CaptureClock.now), type: "move", x: local.x, y: local.y))
        }
        let cursor = NSCursor.currentSystem ?? .arrow
        guard let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        let signature = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            + "-\(cursor.hotSpot.x)-\(cursor.hotSpot.y)-\(cursor.image.size.width)-\(cursor.image.size.height)-\(mapping.cursorScale)"
        let id: Int
        if let existing = cursorIDs[signature] { id = existing }
        else {
            id = cursorIDs.count
            do {
                try PackageIO.writeBytes(png, to: directory.appendingPathComponent("cursors/\(id).png"))
                cursors[String(id)] = CursorMetadata(file: "cursors/\(id).png", hotspot: [cursor.hotSpot.x * mapping.cursorScale, cursor.hotSpot.y * mapping.cursorScale],
                                                    sizePoints: [cursor.image.size.width * mapping.cursorScale, cursor.image.size.height * mapping.cursorScale])
                try PackageIO.write(cursors, to: directory.appendingPathComponent("cursors.json"))
                cursorIDs[signature] = id
            } catch { report(error); return }
        }
        if currentCursor != id {
            currentCursor = id
            emit(CaptureEvent(t: relative(CaptureClock.now), type: "cursor", id: id))
        }
    }

    private func relative(_ host: Int64) -> Int64 { max(lastTime, max(0, host - hostStartNs)) }

    private func consume(_ event: CGEvent, type: CGEventType) {
        let time = relative(Int64(clamping: event.timestamp))
        let point = event.location
        let local = mapping.local(point)
        let x = local.x, y = local.y
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            lastPoint = point
            emit(CaptureEvent(t: time, type: "move", x: x, y: y))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            emit(CaptureEvent(t: time, type: down ? "down" : "up", x: x, y: y,
                              button: button == 0 ? "left" : button == 1 ? "right" : "other"))
        case .scrollWheel:
            emit(CaptureEvent(t: time, type: "scroll",
                dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)))
        case .keyDown where keys:
            var chars = [UniChar](repeating: 0, count: 8)
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &count, unicodeString: &chars)
            let text = String(utf16CodeUnits: chars, count: count)
            let flags = event.flags
            let modifiers: [String] = [(.maskCommand, "cmd"), (.maskShift, "shift"), (.maskAlternate, "alt"), (.maskControl, "ctrl")]
                .compactMap { (flag: CGEventFlags, name: String) in flags.contains(flag) ? name : nil }
            emit(CaptureEvent(t: time, type: "key", key: text.isEmpty ? "keycode:\(event.getIntegerValueField(.keyboardEventKeycode))" : text,
                              modifiers: modifiers))
        default: break
        }
    }

    private func emit(_ event: CaptureEvent) {
        guard !failed else { return }
        do {
            var bytes = try JSONEncoder().encode(event)
            bytes.append(0x0a)
            try file?.write(contentsOf: bytes)
            lastTime = event.t
        } catch { report(error) }
    }
    private func report(_ error: Error) {
        guard !failed else { return }
        failed = true
        failure?(.writerFailed("Input event log: \(error.localizedDescription)"))
    }

    func updateContentRect(_ rect: CGRect, destination: CGRect? = nil) {
        guard rect.width > 0, rect.height > 0, !rect.isInfinite, !rect.isNull else { return }
        if let destination, destination.width > 0, destination.height > 0 {
            mapping = CaptureCoordinateMapping(source: rect, destination: destination)
        } else { mapping = .fitted(source: rect, outputSize: outputSize) }
    }

    func stop() throws {
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        tap = nil; source = nil; monitor = nil
        try file?.synchronize(); try file?.close(); file = nil
        try PackageIO.write(cursors, to: directory.appendingPathComponent("cursors.json"))
    }
}
