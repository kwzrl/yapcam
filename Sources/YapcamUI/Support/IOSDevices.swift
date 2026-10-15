import Foundation

/// An iPhone or iPad that can be recorded over USB.
struct IOSDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Seam for the iOS device source. Capture implements the real discovery and recording; until that
/// lands on this branch this reports "not available" and never lists a made-up device.
enum IOSDevices {
    /// Devices ready to record right now.
    static func connected() -> [IOSDevice] { [] }

    /// Whether this build can record an iOS device at all.
    static let isSupported = false

    static let unsupportedMessage = "Recording an iPhone or iPad isn't available in this build yet. Pick Display, Window or Area instead."
}
