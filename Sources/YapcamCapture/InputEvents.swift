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
    var markerID: String? = nil
    enum CodingKeys: String, CodingKey {
        case t, type, x, y, button, dx, dy, id, key, modifiers
        case markerID = "marker_id"
    }
}

struct CursorMetadata: Codable, Sendable {
    var file: String
    var hotspot: [Double]
    var sizePoints: [Double]
    enum CodingKeys: String, CodingKey { case file, hotspot, sizePoints = "size_points" }
}

/// A value snapshot separates input translation from the OS event tap. The tap
/// only reads Unicode text when key capture was explicitly enabled.
struct InputEventSnapshot: Sendable {
    var type: CGEventType
    var hostNs: Int64
    var location: CGPoint = .zero
    var button: Int64 = 0
    var dx: Double = 0
    var dy: Double = 0
    var text = ""
    var keyCode: Int64 = 0
    var flags: CGEventFlags = []
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
    private var lastLocalPoint: CGPoint?
    private var failed = false
    var warning: ((String) -> Void)?
    var failure: ((CaptureError) -> Void)?

    init(directory: URL, rect: CGRect, hostStartNs: Int64, keys: Bool, outputSize: CGSize? = nil) {
        self.directory = directory; self.hostStartNs = hostStartNs; self.keys = keys
        self.outputSize = outputSize ?? rect.size
        self.mapping = .fitted(source: rect, outputSize: outputSize ?? rect.size)
    }

    func start() throws {
        try openEventLog()
        startMonitoring()
    }

    /// Opening the journal does not touch input permissions or WindowServer.
    func openEventLog() throws {
        guard file == nil else { throw CaptureError.writerFailed("Input event log is already open") }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("cursors"), withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw CaptureError.writerFailed("Cannot create event log") }
        file = try FileHandle(forWritingTo: path)
    }

    private func startMonitoring() {
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
        if let point = CGEvent(source: nil)?.location { recordPosition(point, hostNs: CaptureClock.now) }
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

    /// Explicit markers are independent of keystroke recording and input permission.
    /// Synchronize before acknowledging the action so crash recovery retains it.
    func addMarker(id: String, hostNs: Int64) throws -> Int64 {
        guard let file, !failed else { throw CaptureError.writerFailed("Marker event log is unavailable") }
        let time = relative(hostNs)
        do {
            var bytes = try JSONEncoder().encode(CaptureEvent(t: time, type: "marker", markerID: id))
            bytes.append(0x0a)
            try file.write(contentsOf: bytes)
            try file.synchronize()
            lastTime = time
            return time
        } catch { report(error); throw error }
    }

    /// A stationary global pointer still moves in content coordinates when its
    /// window moves or resizes underneath it.
    func recordPosition(_ global: CGPoint, hostNs: Int64) {
        let local = mapping.local(global)
        guard local.x.isFinite, local.y.isFinite else { return }
        guard local != lastLocalPoint else { return }
        lastLocalPoint = local
        emit(CaptureEvent(t: relative(hostNs), type: "move", x: local.x, y: local.y))
    }

    private func consume(_ event: CGEvent, type: CGEventType) {
        var snapshot = InputEventSnapshot(type: type, hostNs: CaptureClock.inputEventTime(), location: event.location,
            button: event.getIntegerValueField(.mouseEventButtonNumber),
            dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        if type == .keyDown, keys {
            var chars = [UniChar](repeating: 0, count: 8)
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &count, unicodeString: &chars)
            snapshot.text = String(utf16CodeUnits: chars, count: min(count, chars.count))
        }
        record(snapshot)
    }

    func record(_ event: InputEventSnapshot) {
        let time = relative(event.hostNs)
        let point = event.location
        let local = mapping.local(point)
        let x = local.x, y = local.y
        guard x.isFinite, y.isFinite else { return }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            recordPosition(point, hostNs: event.hostNs)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
            let button = event.button
            emit(CaptureEvent(t: time, type: down ? "down" : "up", x: x, y: y,
                              button: button == 0 ? "left" : button == 1 ? "right" : "other"))
        case .scrollWheel:
            guard event.dx.isFinite, event.dy.isFinite else { return }
            emit(CaptureEvent(t: time, type: "scroll", dx: event.dx, dy: event.dy))
        case .keyDown where keys:
            let flags = event.flags
            let modifiers: [String] = [(.maskCommand, "cmd"), (.maskShift, "shift"), (.maskAlternate, "alt"), (.maskControl, "ctrl")]
                .compactMap { (flag: CGEventFlags, name: String) in flags.contains(flag) ? name : nil }
            emit(CaptureEvent(t: time, type: "key", key: event.text.isEmpty ? "keycode:\(event.keyCode)" : event.text,
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
        guard rect.width > 0, rect.height > 0, !rect.isInfinite, !rect.isNull,
              rect.origin.x.isFinite, rect.origin.y.isFinite else { return }
        if let destination {
            guard destination.width > 0, destination.height > 0, !destination.isInfinite, !destination.isNull,
                  destination.origin.x.isFinite, destination.origin.y.isFinite else { return }
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
