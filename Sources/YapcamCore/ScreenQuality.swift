import Foundation

/// Screen-only spatial filtering/resampling. Nil preserves the original samples.
public struct CoreScreenQuality: Codable, Sendable, Equatable {
    public enum Upscaling: String, Codable, Sendable, CaseIterable { case off, fast, quality }
    public var improveQuality: Double
    public var upscaling: Upscaling
    public init(improveQuality: Double = 0.5, upscaling: Upscaling = .quality) {
        self.improveQuality = improveQuality; self.upscaling = upscaling
    }
}

extension Project {
    @discardableResult public func setScreenQuality(_ settings: CoreScreenQuality?) throws -> ChangeSet {
        try apply(.set(path: "canvas.screen_quality", value: settings.map {
            .object(["improve_quality": .number($0.improveQuality), "upscaling": .string($0.upscaling.rawValue)])
        } ?? .null))
    }
}
