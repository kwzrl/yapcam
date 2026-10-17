import SwiftUI
import YapcamDesign

/// Quiet controls at the top of the stage: format, crop and reel preview on the left; preview quality and preview
/// zoom on the right. Text in caption grey, no surfaces until hovered.
struct StageControls: View {
    @ObservedObject var model: EditorModel
    @State private var showCrop = false
    static let height: CGFloat = 40

    var body: some View {
        HStack(spacing: 4) {
            formatMenu
            cropButton
            maskButton
            if model.reelPreviewAvailable { reelMenu }
            Spacer(minLength: 8)
            qualityMenu
            zoomControls
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .onChange(of: model.cropRequested) { _, v in if v { model.cropRequested = false; showCrop = true } }
    }

    private var aspectTitle: String {
        let a = model.string("canvas.aspect", default: "source")
        return AspectPreset(rawValue: a)?.label ?? a
    }

    private var formatMenu: some View {
        QuietMenu(symbol: "rectangle.dashed", title: aspectTitle, help: "Format of the output") {
            ForEach(AspectPreset.allCases, id: \.self) { a in
                Button { model.setAspect(a) } label: {
                    if model.string("canvas.aspect") == a.rawValue { Label(a.label, systemImage: "checkmark") } else { Text(a.label) }
                }
                .help(a.hint)
            }
        }
    }

    private var cropButton: some View {
        QuietButton(symbol: "crop", title: "Crop", help: "Crop the recording") { showCrop = true }
            .popover(isPresented: $showCrop) { Form { CropSection(model: model) }.formStyle(.grouped).frame(width: 300, height: 300) }
    }

    private var maskButton: some View {
        QuietButton(symbol: "square.dashed", title: "Mask", help: "Show the masks timeline and add a mask at the playhead (4)") { model.showMasksAndAddAtPlayhead() }
    }

    private var reelMenu: some View {
        QuietMenu(symbol: "iphone", title: model.reelMode == .off ? "Reel" : model.reelMode.label,
                  help: "Show a platform's safe areas over the preview (preview only, not exported)") {
            ForEach(ReelMode.allCases) { m in
                Button { model.setReelMode(m) } label: { if model.reelMode == m { Label(m.label, systemImage: "checkmark") } else { Text(m.label) } }
            }
        }
    }

    private func editOptions(_ change: (inout PreviewOptions) -> Void) { var o = model.previewOptions; change(&o); model.setPreviewOptions(o) }

    private var qualityMenu: some View {
        let res = PreviewOptions.resolutions.first { $0.value == model.previewOptions.resolution }?.label ?? "Full"
        return QuietMenu(symbol: "play.rectangle", title: res, help: "Preview size, resolution and speed (does not change the export)") {
            Picker("Size", selection: Binding(get: { model.previewOptions.maxHeight ?? 0 }, set: { v in editOptions { $0.maxHeight = v == 0 ? nil : v } })) {
                Text("Automatic").tag(0)
                ForEach(PreviewOptions.heights, id: \.self) { Text("\($0)p").tag($0) }
            }
            Picker("Resolution", selection: Binding(get: { model.previewOptions.resolution }, set: { v in editOptions { $0.resolution = v } })) {
                ForEach(PreviewOptions.resolutions, id: \.value) { Text($0.label).tag($0.value) }
            }
            Picker("Playback speed", selection: Binding(get: { model.previewOptions.rate }, set: { v in editOptions { $0.rate = v } })) {
                ForEach(PreviewOptions.rates, id: \.self) { Text(PreviewOptions.rateLabel($0)).tag($0) }
            }
            Toggle("Motion blur in preview", isOn: Binding(get: { model.previewOptions.motionBlur }, set: { v in editOptions { $0.motionBlur = v } }))
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            QuietButton(symbol: "minus.magnifyingglass", help: "Zoom the preview out") { model.zoomPreview(by: 0.8) }
                .disabled(model.previewZoom <= 1)
            if model.previewZoom > 1 {
                Button { model.resetPreviewZoom() } label: {
                    Text("\(Int(model.previewZoom * 100)) %").technical().padding(.horizontal, 4).frame(height: 28)
                }
                .buttonStyle(PressStyle()).help("Fit the preview").accessibilityLabel("Fit preview")
            }
            QuietButton(symbol: "plus.magnifyingglass", help: "Zoom the preview in (⌥-drag to pan)") { model.zoomPreview(by: 1.25) }
        }
    }
}

/// A quiet button on the stage: icon (and optional text) in caption grey, a platter on hover.
struct QuietButton: View {
    let symbol: String
    var title: String?
    let help: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    init(symbol: String, title: String? = nil, help: String, action: @escaping () -> Void) {
        self.symbol = symbol; self.title = title; self.help = help; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12))
                if let title { Text(title).font(Yap.Font.caption) }
            }
            .padding(.horizontal, title == nil ? 0 : 10).frame(minWidth: 28, minHeight: 28)
            .foregroundStyle(hover && enabled ? Yap.title : Yap.caption)
            .opacity(enabled ? 1 : 0.4)
            .background(Platter(active: false, hover: hover && enabled, radius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(title ?? help)
    }
}
