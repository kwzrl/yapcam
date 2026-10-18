import SwiftUI
import YapcamCore
import YapcamDesign

extension EditorModel {
    /// Pixel size of the recorded screen track; nil for projects without one (unit-test fakes).
    public var screenPixelSize: CGSize? {
        guard let core = project as? CoreEditingProject else { return nil }
        let s = core.project.session.tracks.screen.pixelSize
        return s.count == 2 && s[0] > 0 && s[1] > 0 ? CGSize(width: s[0], height: s[1]) : nil
    }
    /// The crop draft the tool starts from: the stored `canvas.crop` on the real frame size (1920×1080 when unknown).
    public func cropDraft() -> CropDraft { CropDraft(frame: screenPixelSize ?? CGSize(width: 1920, height: 1080), stored: numbers("canvas.crop")) }

    /// Writes the draft to `canvas.crop` as one undo step. A full-frame draft clears the crop.
    public func applyCrop(_ draft: CropDraft) {
        let d = draft.rounded(), i = d.insets
        setCrop(left: i.left, top: i.top, right: i.right, bottom: i.bottom)
    }
}

/// Crop tool sheet: the whole unzoomed frame at the playhead, eight handles, pixel fields, an aspect lock. Changes are staged and
/// written once by Confirm (Return); Discard (Esc) leaves the project untouched.
struct CropToolView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CropDraft
    @State private var image: CGImage?
    @State private var dragStart: (handle: CropHandle, rect: CGRect)?

    init(model: EditorModel) {
        self.model = model
        _draft = State(initialValue: model.cropDraft())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Crop recording").font(Yap.Font.title(18)).foregroundStyle(Yap.title)
            fields
            canvas
            HStack {
                InspectorAction("Reset") { draft.reset() }.disabled(draft.isFullFrame)
                Spacer()
                Button("Discard changes") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Confirm changes ↩") { model.applyCrop(draft); dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 760)
        .task { image = await model.sourceFrame(atNs: model.playheadNs) }
    }

    private var fields: some View {
        HStack(spacing: 14) {
            pair("Size", "W", get: { draft.rect.width }, set: { draft.setWidth($0) }, "H", get: { draft.rect.height }, set: { draft.setHeight($0) })
            pair("Position", "X", get: { draft.rect.minX }, set: { draft.setX($0) }, "Y", get: { draft.rect.minY }, set: { draft.setY($0) })
            VStack(alignment: .leading, spacing: 3) {
                Text("Aspect").font(Yap.Font.caption).foregroundStyle(Yap.caption)
                Picker("Aspect", selection: Binding(get: { draft.lock }, set: { draft.setLock($0) })) {
                    ForEach(CropAspectLock.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 90)
            }
            Spacer()
        }
    }

    private func pair(_ title: String, _ a: String, get ga: @escaping () -> Double, set sa: @escaping (Double) -> Void,
                      _ b: String, get gb: @escaping () -> Double, set sb: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Yap.Font.caption).foregroundStyle(Yap.caption)
            HStack(spacing: 6) { PixelField(label: a, get: ga, set: sa); PixelField(label: b, get: gb, set: sb) }
        }
    }

    // MARK: image + handles

    private var canvas: some View {
        let aspect = draft.frame.width / draft.frame.height
        return GeometryReader { geo in
            let scale = geo.size.width / draft.frame.width
            ZStack(alignment: .topLeading) {
                if let image { Image(decorative: image, scale: 1).resizable().frame(width: geo.size.width, height: geo.size.height) }
                else { Rectangle().fill(Color.white.opacity(0.06)) }
                let r = CGRect(x: draft.rect.minX * scale, y: draft.rect.minY * scale, width: draft.rect.width * scale, height: draft.rect.height * scale)
                Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(r) }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                Rectangle().stroke(Color.white, lineWidth: 1).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
                Path { p in                                    // 25/50/75 % guides inside the crop (MKT-137)
                    for f in [0.25, 0.5, 0.75] {
                        p.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
                        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
                    }
                }
                .stroke(Color.white.opacity(0.3), lineWidth: 0.5).allowsHitTesting(false)
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .gesture(drag(.body, scale: scale))
                ForEach(CropHandle.allCases.filter { $0 != .body }, id: \.self) { h in
                    let c = Self.point(of: h, in: r)
                    RoundedRectangle(cornerRadius: 2).fill(Color.white).overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                        .frame(width: 10, height: 10).position(c).gesture(drag(h, scale: scale))
                        .accessibilityLabel("Crop handle \(String(describing: h))")
                }
            }
            .clipped()
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func drag(_ handle: CropHandle, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                if dragStart == nil { dragStart = (handle, draft.rect) }
                guard let s = dragStart else { return }
                draft.rect = draft.dragged(s.handle, from: s.rect, dx: v.translation.width / scale, dy: v.translation.height / scale)
            }
            .onEnded { _ in draft = draft.rounded(); dragStart = nil }
    }

    static func point(of h: CropHandle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: r.minX, y: r.minY); case .top: CGPoint(x: r.midX, y: r.minY); case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY); case .bottomRight: CGPoint(x: r.maxX, y: r.maxY); case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY); case .left: CGPoint(x: r.minX, y: r.midY); case .body: CGPoint(x: r.midX, y: r.midY)
        }
    }
}

/// Whole-pixel number field; commits on Return or focus loss, clamping happens in the draft.
private struct PixelField: View {
    let label: String
    let get: () -> Double
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(Yap.Font.caption).foregroundStyle(Yap.caption)
            TextField("", text: $text).textFieldStyle(.roundedBorder).frame(width: 64).focused($focused).monospacedDigit()
                .onSubmit { commit() }
                .onChange(of: focused) { _, f in if !f { commit() } }
                .onAppear { text = "\(Int(get().rounded()))" }
                .onChange(of: get()) { _, v in if !focused { text = "\(Int(v.rounded()))" } }
                .accessibilityLabel(label)
        }
    }
    private func commit() {
        if let v = Double(text.trimmingCharacters(in: .whitespaces)) { set(v.rounded()) }
        text = "\(Int(get().rounded()))"
    }
}
