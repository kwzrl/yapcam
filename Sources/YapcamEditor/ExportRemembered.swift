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
