import Foundation

/// Local playback controls. These do not change the project or export settings.
public struct PreviewSettings: Equatable, Sendable {
    public enum Resolution: Double, CaseIterable, Sendable {
        case full = 1, half = 0.5, quarter = 0.25
    }
    public static let maximumHeights = [480,720,1080,1440,2160]
    public static let playbackRates: [Double] = [0.25,0.5,1,2,4,8]
    /// Nil preserves the view's automatic backing-pixel size.
    public var maximumHeight: Int?
    public var resolution: Resolution
    public var playbackRate: Double
    /// Caps only interactive preview presentation. Exports always use their
    /// independently configured frame rate and quality.
    public var powerSaving: Bool
    /// Matches ExportSettings.screenQuality when a local processing preference
    /// should apply to both paths. Nil inherits evaluated project settings.
    public var screenQuality: ScreenQualitySettings?
    /// Local interface guides drawn by PreviewView above the video, never exported.
    public var reelMode: ReelPreviewMode

    public init(maximumHeight: Int? = nil, resolution: Resolution = .full, playbackRate: Double = 1,
                powerSaving: Bool = false,screenQuality: ScreenQualitySettings? = nil,reelMode: ReelPreviewMode = .off) {
        self.maximumHeight=maximumHeight; self.resolution=resolution; self.playbackRate=playbackRate
        self.powerSaving=powerSaving
        self.screenQuality=screenQuality
        self.reelMode=reelMode
    }
    public var preferredFramesPerSecond: Int { powerSaving ? 30 : 60 }
    public func validate() throws {
        try screenQuality?.validate()
        guard maximumHeight.map(Self.maximumHeights.contains) ?? true,
              Self.playbackRates.contains(playbackRate) else {
            throw RenderError.invalidSettings("Unsupported preview height or playback rate")
        }
    }
    /// Height is a cap in backing pixels; resolution applies after the cap.
    /// Smaller views are never upscaled. Drawable dimensions need not be even.
    public func drawableSize(forBackingSize backing: CGSize) throws -> CGSize {
        try validate()
        guard backing.width.isFinite, backing.height.isFinite, backing.width>0, backing.height>0 else {
            throw RenderError.invalidSettings("Invalid preview backing size")
        }
        let scale=min(1,maximumHeight.map { Double($0)/backing.height } ?? 1)*resolution.rawValue
        return CGSize(width: max(1,floor(backing.width*scale)),height: max(1,floor(backing.height*scale)))
    }
}

enum PreviewClock {
    /// A malformed custom source must not underflow `durationNs - 1` while a
    /// user seek is being clamped.
    static func position(_ requestedNs: Int64, durationNs: Int64) -> Int64 {
        guard durationNs > 0 else { return 0 }
        return max(0,min(requestedNs,durationNs-1))
    }

    /// AVFoundation clocks are floating point and may report invalid or very
    /// large finite values for damaged media. Saturate before converting.
    static func playerTime(seconds: Double, fallbackNs: Int64, durationNs: Int64) -> Int64 {
        let end=max(0,durationNs)
        guard seconds.isFinite else { return position(fallbackNs,durationNs: durationNs) }
        let nanoseconds=seconds*1e9
        guard nanoseconds.isFinite, nanoseconds<Double(Int64.max), nanoseconds<Double(end) else { return end }
        guard nanoseconds>0 else { return 0 }
        return min(end,Int64(nanoseconds.rounded()))
    }

    /// Saturates before converting to Int64, including a long sleep or huge timeline.
    static func time(anchorNs: Int64, elapsed: Double, rate: Double, durationNs: Int64) -> Int64 {
        let end=max(0,durationNs), anchor=max(0,min(anchorNs,end))
        let advance=max(0,elapsed)*rate*1e9
        guard advance.isFinite, advance<Double(end-anchor) else { return end }
        return anchor+Int64(advance)
    }
}
