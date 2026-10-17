import YapcamRender
import Foundation

/// Export choices remembered per context, so the export dialog and quick export (after recording) keep separate settings.
public struct ExportRememberedSettings: Codable, Equatable, Sendable {
    public enum Context: String, Sendable { case dialog, quick }
    public var format: String, height: Int, fps: Int, includeAudio: Bool, preset: String, gifHighQuality: Bool, gifDisableLoop: Bool
    /// File or clipboard (older saved settings decode without it: file).
    public var target: String? = nil

    static func key(_ c: Context) -> String { "yapcam.export.remembered.\(c.rawValue)" }
    public static func load(_ c: Context, from defaults: UserDefaults) -> ExportRememberedSettings? {
        defaults.data(forKey: key(c)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    public func save(_ c: Context, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key(c)) }
    }
}

extension ExportModel {
    public var rememberedSettings: ExportRememberedSettings {
        ExportRememberedSettings(format: format.rawValue, height: height, fps: fps, includeAudio: includeAudio, preset: preset.rawValue,
                                 gifHighQuality: gifHighQuality, gifDisableLoop: gifDisableLoop, target: target.rawValue)
    }

    /// Restores the context's last choices (invalid or unavailable values fall back to the format's defaults) and
    /// keeps saving every later change under that context only.
    public func remember(in context: ExportRememberedSettings.Context, defaults: UserDefaults) {
        rememberTarget = nil
        if let r = ExportRememberedSettings.load(context, from: defaults) {
            if let t = r.target.flatMap(ExportTarget.init(rawValue:)) { target = t }
            if let f = ExportFormat(rawValue: r.format), availableFormats.contains(f) { format = f }
            if format.options.heights.contains(r.height) { height = r.height }
            if format.options.fps.contains(r.fps) { fps = r.fps }
            if format.supportsAudio { includeAudio = r.includeAudio }
            if let p = CompressionPreset(rawValue: r.preset), availablePresets.contains(p) { preset = p }
            gifHighQuality = r.gifHighQuality; gifDisableLoop = r.gifDisableLoop
        }
        rememberTarget = (context, defaults)
    }
}

// MARK: quick export (after recording) reads and writes its own remembered store

extension ExportRememberedSettings {
    /// Reference defaults for a context nothing was remembered for: MP4 (H.264), 720p, 60 fps, Social Media, audio on, to a file.
    public static var factory: ExportRememberedSettings {
        ExportRememberedSettings(format: ExportFormat.mp4h264.rawValue, height: 720, fps: 60, includeAudio: true,
                                 preset: CompressionPreset.social.rawValue, gifHighQuality: true, gifDisableLoop: false, target: ExportTarget.file.rawValue)
    }

    /// The remembered values of a context as render settings (snapped into render's catalog), plus the remembered target.
    public func renderSettings() -> (settings: ExportSettings, target: ExportTarget) {
        let format = ExportFormat(rawValue: format) ?? .mp4h264
        let target = target.flatMap(ExportTarget.init(rawValue:)) ?? .file
        let compression = CompressionPreset(rawValue: preset)?.renderValue
        let s = ExportSettings(format: format.renderFormat, codec: format.renderCodec, outputHeight: height, fps: fps,
                               includeAudio: includeAudio && format.supportsAudio, compression: format == .gif ? nil : compression,
                               gifHighQuality: gifHighQuality, gifDisableLoop: gifDisableLoop)
        return (s.closestValidPreset(for: target == .clipboard ? .clipboard : .file), target)
    }
    /// What the quick export uses now: its own remembered values, else the factory defaults. The export dialog's store is separate.
    public static func quick(from defaults: UserDefaults) -> (settings: ExportSettings, target: ExportTarget) {
        (load(.quick, from: defaults) ?? factory).renderSettings()
    }
    /// Remembers the quick export's choices (call after the user changes them in the widget).
    public static func rememberQuick(format: ExportFormat, height: Int, fps: Int, compression: CompressionPreset, includeAudio: Bool,
                                     target: ExportTarget, gifHighQuality: Bool = true, gifDisableLoop: Bool = false, in defaults: UserDefaults) {
        ExportRememberedSettings(format: format.rawValue, height: height, fps: fps, includeAudio: includeAudio, preset: compression.rawValue,
                                 gifHighQuality: gifHighQuality, gifDisableLoop: gifDisableLoop, target: target.rawValue).save(.quick, to: defaults)
    }
}
