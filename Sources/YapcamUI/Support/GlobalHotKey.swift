import Carbon.HIToolbox
import Foundation

/// System-wide shortcut via Carbon `RegisterEventHotKey` (needs no extra permission).
@MainActor final class GlobalHotKey {
    private static var nextID: UInt32 = 1
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    nonisolated(unsafe) private var ref: EventHotKeyRef?
    private let id: UInt32

    init() { id = Self.nextID; Self.nextID += 1; Self.installHandlerOnce() }
    /// A deinit can run on any thread: release the Carbon key here and clear the main-actor handler table on main.
    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        let id = id
        DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.handlers[id] = nil } }
    }

    @discardableResult
    func register(_ combo: KeyCombo, action: @escaping () -> Void) -> Bool {
        unregister()
        var r: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x59414D43) /* YAMC */, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hid, GetApplicationEventTarget(), 0, &r)
        guard status == noErr, let r else { return false }
        ref = r
        Self.handlers[id] = action
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hid = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hid)
            let id = hid.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
