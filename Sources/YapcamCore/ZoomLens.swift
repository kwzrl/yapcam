import Foundation

/// A local magnification instruction; the base frame retains its screen crop.
public struct CoreZoomLens: Decodable, Sendable, Equatable {
    public var zoomId: String
    public var center: [Double]
    public var sourceCenter: [Double]
    public var scale: Double
    public var radiusPx: Double
    public var bevel: Double
    public var chromaticAberration: Double
    public var opacity: Double
}
extension Project {
    public func zoomLens(atNs: Int64) throws -> CoreZoomLens? {
        try query("{\"q\":\"zoom_lens_at\",\"tl_ns\":\(atNs)}", as: CoreZoomLens?.self)
    }
}
