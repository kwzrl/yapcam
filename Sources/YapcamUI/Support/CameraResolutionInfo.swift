import AVFoundation
import SwiftUI
import YapcamCapture

/// What a camera will actually deliver under a chosen maximum. Mirrors the capture layer's rule:
/// the largest native frame within the cap, never upscaled.
enum CameraResolutionInfo {
    struct Size: Equatable { var width: Int; var height: Int }

    static func label(_ m: CameraMaxResolution) -> String {
        switch m { case .hd720: return "720p"; case .hd1080: return "1080p"; case .uhd4K: return "4K" }
    }

    static func limits(_ m: CameraMaxResolution) -> (long: Int, short: Int) {
        switch m { case .hd720: return (1280, 720); case .hd1080: return (1920, 1080); case .uhd4K: return (3840, 2160) }
    }

    static func effective(formats: [Size], maximum: CameraMaxResolution) -> Size? {
        let l = limits(maximum)
        return formats.filter { max($0.width, $0.height) <= l.long && min($0.width, $0.height) <= l.short && min($0.width, $0.height) >= 2 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    static func name(_ s: Size) -> String {
        let short = min(s.width, s.height)
        let tag = short >= 2160 ? "4K" : short >= 1080 ? "1080p" : short >= 720 ? "720p" : "\(short)p"
        return "\(tag) (\(s.width)×\(s.height))"
    }

    /// One line for the UI. `formats` is nil when no camera is selected or the device is unknown.
    static func summary(maximum: CameraMaxResolution, cameraSelected: Bool, formats: [Size]?) -> String {
        guard cameraSelected else { return "Applies when a camera is used." }
        guard let formats, !formats.isEmpty else { return "The camera's resolution is chosen when recording starts." }
        guard let used = effective(formats: formats, maximum: maximum) else {
            return "This camera has no format within \(label(maximum)). Recording the camera may fail."
        }
        let best = effective(formats: formats, maximum: .uhd4K)
        if let best, best != used { return "Will record at \(name(used)). The camera can do up to \(name(best))." }
        if used.width * used.height < limitPixels(maximum) { return "Will record at \(name(used)), the most this camera offers." }
        return "Will record at \(name(used))."
    }

    private static func limitPixels(_ m: CameraMaxResolution) -> Int { let l = limits(m); return l.long * l.short }

    /// Formats of a real device, or nil when it is not connected.
    static func deviceFormats(id: String?) -> [Size]? {
        guard let id, let d = AVCaptureDevice(uniqueID: id) else { return nil }
        return d.formats.map { let s = CMVideoFormatDescriptionGetDimensions($0.formatDescription); return Size(width: Int(s.width), height: Int(s.height)) }
    }
}

/// "Max camera resolution" picker with a line saying what will really be used.
struct CameraResolutionRow: View {
    @EnvironmentObject var settings: AppSettings
    var formatsProvider: (String?) -> [CameraResolutionInfo.Size]? = CameraResolutionInfo.deviceFormats

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Max camera resolution", selection: $settings.cameraMaxResolution) {
                ForEach(CameraMaxResolution.allCases, id: \.self) { Text(CameraResolutionInfo.label($0)).tag($0) }
            }
            Text(CameraResolutionInfo.summary(maximum: settings.cameraMaxResolution, cameraSelected: settings.cameraID != nil,
                                              formats: formatsProvider(settings.cameraID)))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
