import Foundation

/// One retained occurrence of an immutable captured recording marker.
public struct TimelineMarker: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var markerID: String
    public var segment: Int
    public var segmentNs: Int64
    public var srcNs: Int64
    public var tlNs: Int64
    public var clipID: String
    // Project.query converts the wire's snake_case before matching coding keys.
    enum CodingKeys: String, CodingKey {
        case id, markerID = "markerId", segment, segmentNs, srcNs, tlNs, clipID = "clipId"
    }
}
extension Project {
    public func markers() throws -> [TimelineMarker] {
        try query("{\"q\":\"markers\"}", as: [TimelineMarker].self)
    }
}
