import Foundation

/// A marker uses the same source clock as video, with pauses removed.
public struct RecordingMarker: Sendable, Equatable, Identifiable {
    public let id: String
    public let segmentIndex: Int
    public let segmentNs: Int64
    public let srcNs: Int64
}
