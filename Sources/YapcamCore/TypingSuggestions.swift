import Foundation

/// Source-stable keystroke burst with all retained occurrences on the timeline.
public struct TypingSuggestion: Decodable, Sendable, Equatable, Identifiable {
    public struct Range: Decodable, Sendable, Equatable {
        public var tlStartNs: Int64
        public var tlEndNs: Int64
    }
    public var id: String
    public var srcStartNs: Int64
    public var srcEndNs: Int64
    public var keyCount: Int
    public var speed: Double
    public var ranges: [Range]
}
extension Project {
    public func typingSuggestions() throws -> [TypingSuggestion] {
        try query("{\"q\":\"typing_suggestions\"}", as: [TypingSuggestion].self)
    }
}
