import SwiftUI

/// Local preview controls (size cap, resolution, playback speed, motion blur). They never change the project or exports;
/// they are remembered per user in the editor's defaults.
public struct PreviewOptions: Equatable, Sendable {
    public static let heights = [480, 720, 1080, 1440, 2160]
    public static let resolutions: [(label: String, value: Double)] = [("Full", 1), ("Half", 0.5), ("Quarter", 0.25)]
    public static let rates: [Double] = [0.25, 0.5, 1, 2, 4, 8]
    public var maxHeight: Int? = nil           // nil = follow the view size
    public var resolution = 1.0
    public var rate = 1.0
    public var motionBlur = true
    public init() {}
    public static func rateLabel(_ r: Double) -> String { r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r) }
}

extension PlaybackEngine {
    public func setPreviewOptions(_ options: PreviewOptions) throws {}
}

extension EditorModel {
    private static let previewKey = "yapcam.preview."

    /// Reads the remembered options and applies them to the player (call after `defaults` is set).
    public func loadStoredPreviewOptions() {
        var o = PreviewOptions()
        let h = defaults.integer(forKey: Self.previewKey + "maxHeight")
        if PreviewOptions.heights.contains(h) { o.maxHeight = h }
        let r = defaults.double(forKey: Self.previewKey + "resolution")
        if PreviewOptions.resolutions.contains(where: { $0.value == r }) { o.resolution = r }
        let rate = defaults.double(forKey: Self.previewKey + "rate")
        if PreviewOptions.rates.contains(rate) { o.rate = rate }
        if defaults.object(forKey: Self.previewKey + "motionBlur") != nil { o.motionBlur = defaults.bool(forKey: Self.previewKey + "motionBlur") }
        guard o != previewOptions else { return }
        setPreviewOptions(o)
    }

    public func setPreviewOptions(_ o: PreviewOptions) {
        do { try player.setPreviewOptions(o) } catch { lastError = error.localizedDescription; return }
        previewOptions = o
        defaults.set(o.maxHeight ?? 0, forKey: Self.previewKey + "maxHeight")
        defaults.set(o.resolution, forKey: Self.previewKey + "resolution")
        defaults.set(o.rate, forKey: Self.previewKey + "rate")
        defaults.set(o.motionBlur, forKey: Self.previewKey + "motionBlur")
    }
}

/// Preview menu above the preview: size, resolution, playback speed and the preview-only motion blur switch.
struct PreviewOptionsMenu: View {
    @ObservedObject var model: EditorModel
    private func edit(_ change: (inout PreviewOptions) -> Void) { var o = model.previewOptions; change(&o); model.setPreviewOptions(o) }
    var body: some View {
        Menu {
            Picker("Size", selection: Binding(get: { model.previewOptions.maxHeight ?? 0 }, set: { v in edit { $0.maxHeight = v == 0 ? nil : v } })) {
                Text("Automatic").tag(0)
                ForEach(PreviewOptions.heights, id: \.self) { Text("\($0)p").tag($0) }
            }
            Picker("Resolution", selection: Binding(get: { model.previewOptions.resolution }, set: { v in edit { $0.resolution = v } })) {
                ForEach(PreviewOptions.resolutions, id: \.value) { Text($0.label).tag($0.value) }
            }
            Picker("Playback speed", selection: Binding(get: { model.previewOptions.rate }, set: { v in edit { $0.rate = v } })) {
                ForEach(PreviewOptions.rates, id: \.self) { Text(PreviewOptions.rateLabel($0)).tag($0) }
            }
            Toggle("Motion blur in preview", isOn: Binding(get: { model.previewOptions.motionBlur }, set: { v in edit { $0.motionBlur = v } }))
        } label: { Label("Preview", systemImage: "play.rectangle") }
            .menuStyle(.borderlessButton).fixedSize().help("Preview size, resolution and speed (does not change the export)")
    }
}
