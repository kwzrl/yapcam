import Foundation

/// The editor's single-key shortcuts and the keys they can be rebound to (Settings > Shortcuts > Editing in the app).
/// Defaults follow the reference: C split, X ripple delete, S speed, V volume, J/K/L shuttle, Z add zoom, A/M/D on a zoom.
public struct EditorKeyAction: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let defaultKey: Character
}

public final class EditorKeyBindings: @unchecked Sendable {
    public static let shared = EditorKeyBindings(defaults: .standard)
    public static let actions: [EditorKeyAction] = [
        EditorKeyAction(id: "split", title: "Split at playhead (selected item, else the clip)", defaultKey: "c"),
        EditorKeyAction(id: "ripple", title: "Remove video before the previous cut", defaultKey: "x"),
        EditorKeyAction(id: "speed", title: "Set clip speed", defaultKey: "s"),
        EditorKeyAction(id: "volume", title: "Set clip volume", defaultKey: "v"),
        EditorKeyAction(id: "addZoom", title: "Add zoom at playhead", defaultKey: "z"),
        EditorKeyAction(id: "zoomAuto", title: "Zoom: automatic", defaultKey: "a"),
        EditorKeyAction(id: "zoomManual", title: "Zoom: manual", defaultKey: "m"),
        EditorKeyAction(id: "zoomToggle", title: "Zoom: enable / disable", defaultKey: "d"),
        EditorKeyAction(id: "shuttleBack", title: "Play backward / step back", defaultKey: "j"),
        EditorKeyAction(id: "shuttleStop", title: "Pause", defaultKey: "k"),
        EditorKeyAction(id: "shuttleForward", title: "Play", defaultKey: "l"),
        EditorKeyAction(id: "trimStart", title: "Trim start to playhead", defaultKey: "["),
        EditorKeyAction(id: "trimEnd", title: "Trim end to playhead", defaultKey: "]"),
    ]
    private static let storeKey = "yapcam.editor.keybindings"
    private let defaults: UserDefaults
    private let lock = NSLock()
    public init(defaults: UserDefaults) { self.defaults = defaults }

    private var overrides: [String: String] { defaults.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:] }

    /// The key an action currently uses.
    public func key(for id: String) -> Character {
        lock.lock(); defer { lock.unlock() }
        guard let a = Self.actions.first(where: { $0.id == id }) else { return " " }
        return overrides[id]?.first ?? a.defaultKey
    }
    /// Rebinds an action. Refused (false) for keys another action uses, keys reserved by the editor (digits, space, = -, arrows)
    /// and anything that is not a single printable character.
    @discardableResult
    public func setKey(_ key: Character?, for id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let a = Self.actions.first(where: { $0.id == id }) else { return false }
        var o = overrides
        guard let key else { o[id] = nil; defaults.set(o, forKey: Self.storeKey); return true }
        let k = Character(String(key).lowercased())
        guard !k.isWhitespace, !"0123456789=+-".contains(k), k.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value != 127 }) else { return false }
        for other in Self.actions where other.id != id { if (o[other.id]?.first ?? other.defaultKey) == k { return false } }
        o[id] = k == a.defaultKey ? nil : String(k)
        defaults.set(o, forKey: Self.storeKey)
        return true
    }
    public func resetAll() { lock.lock(); defaults.removeObject(forKey: Self.storeKey); lock.unlock() }
    public var isCustomized: Bool { !overrides.isEmpty }

    /// Maps a pressed key to the default key of the action it triggers (what `handleShortcut` switches on), or nil when the key
    /// is not bound to any action any more (its default owner was moved elsewhere).
    func canonical(_ pressed: Character) -> Character? {
        let p = Character(String(pressed).lowercased())
        for a in Self.actions where key(for: a.id) == p { return a.defaultKey }
        if Self.actions.contains(where: { $0.defaultKey == p }) { return nil }       // moved away from this key
        return p
    }
}
