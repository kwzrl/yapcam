import AVFoundation

public enum CameraMaxResolution: Int, CaseIterable, Codable, Sendable {
    case hd720 = 720
    case hd1080 = 1080
    case uhd4K = 2160

    func contains(width: Int, height: Int) -> Bool {
        let longLimit = self == .hd720 ? 1280 : self == .hd1080 ? 1920 : 3840
        return min(width, height) >= 2 && max(width, height) <= longLimit && min(width, height) <= rawValue
    }
}

struct CameraFormatChoice: Equatable {
    var index: Int
    var width: Int
    var height: Int
    var fps: Int
    var frameRate: Double
}

struct CameraFormatCandidate {
    var width: Int
    var height: Int
    var rates: [ClosedRange<Double>]
}

enum CameraFormatPolicy {
    /// Prefer the largest native frame below the cap, then the requested rate.
    /// Do not upscale smaller cameras or silently exceed the selected maximum.
    static func choose(_ formats: [CameraFormatCandidate], maximum: CameraMaxResolution, fps: Int) throws -> CameraFormatChoice {
        guard fps == 30 || fps == 60 else { throw CaptureError.writerFailed("Camera frame rate must be 30 or 60") }
        let choices = formats.enumerated().compactMap { index, format -> CameraFormatChoice? in
            guard maximum.contains(width: format.width, height: format.height) else { return nil }
            for nominal in [fps, 30] {
                // Common USB modes expose 29.97/59.94 rather than exact 30/60.
                // Use their real supported duration; do not force a faster clock.
                let rate = format.rates.compactMap { range -> Double? in
                    if range.contains(Double(nominal)) { return Double(nominal) }
                    let maximum = range.upperBound
                    return maximum > 0 && maximum < Double(nominal) && Double(nominal) - maximum < 0.1 ? maximum : nil
                }.max()
                if let rate {
                    return CameraFormatChoice(index: index, width: format.width, height: format.height, fps: nominal, frameRate: rate)
                }
            }
            return nil
        }
        guard let choice = choices.max(by: { a, b in
            if a.width * a.height != b.width * b.height { return a.width * a.height < b.width * b.height }
            if a.fps != b.fps { return a.fps < b.fps }
            return a.index > b.index
        }) else { throw CaptureError.writerFailed("Camera has no supported 30/60 fps format within the selected resolution limit") }
        return choice
    }

    static func configure(_ device: AVCaptureDevice, maximum: CameraMaxResolution, fps: Int) throws -> CameraFormatChoice {
        let formats = device.formats
        let choice = try choose(formats.map {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return CameraFormatCandidate(width: Int(size.width), height: Int(size.height),
                rates: $0.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate })
        }, maximum: maximum, fps: fps)
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = formats[choice.index]
        let duration: CMTime
        if choice.frameRate == Double(choice.fps) { duration = CMTime(value: 1, timescale: CMTimeScale(choice.fps)) }
        else if let range = formats[choice.index].videoSupportedFrameRateRanges.first(where: { abs($0.maxFrameRate - choice.frameRate) < 0.000_001 }) {
            duration = range.minFrameDuration
        } else { throw CaptureError.writerFailed("Camera frame duration is unavailable") }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        return choice
    }
}
