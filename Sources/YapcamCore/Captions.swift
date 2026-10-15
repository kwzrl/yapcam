import Foundation

public struct CoreCaptionWordEvaluation: Decodable, Sendable, Equatable {
    public var text: String
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public var visible: Bool
    public var progress: Double
    public var opacity: Double
    public var offsetY: Double
}
public struct CoreCaptionEvaluation: Decodable, Sendable, Equatable {
    public var fullText: String
    public var visibleText: String
    public var fontFamily: TextStyle.FontFamily
    public var reveal: TextStyle.Reveal
    public var growth: TextStyle.Growth
    public var entrance: TextStyle.Entrance
    public var language: String
    public var lineOpacity: Double
    public var lineOffsetY: Double
    public var words: [CoreCaptionWordEvaluation]
}
public struct CoreCaptionOptions: Decodable, Sendable, Equatable {
    public struct Language: Decodable, Sendable, Equatable {
        public var automatic: String
        public var supportsLocaleTags: Bool
        public var supportedLocalesRequireCapture: Bool
    }
    public var fontFamilies: [TextStyle.FontFamily]
    public var revealModes: [TextStyle.Reveal]
    public var growthModes: [TextStyle.Growth]
    public var entrances: [TextStyle.Entrance]
    public var language: Language
}
extension Project {
    public func captionOptions() throws -> CoreCaptionOptions {
        try query("{\"q\":\"caption_options\"}", as: CoreCaptionOptions.self)
    }
}
