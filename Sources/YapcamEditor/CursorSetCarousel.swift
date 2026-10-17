import SwiftUI
import YapcamDesign
import YapcamCore
import YapcamRender

/// One entry of the cursor set picker: render's descriptor plus the `cursor.set_id` value it stores.
struct CursorSetChoice: Identifiable, Equatable {
    let descriptor: CursorSetDescriptor
    /// Stored value; nil = the recorded cursor on cores that predate the explicit "original" id.
    let stored: String?
    var id: String { descriptor.id }
}

extension EditorModel {
    /// Render's catalog restricted to ids this core accepts, so every card can be chosen without an error.
    func cursorSetChoices() -> [CursorSetChoice] {
        let accepted = Set(cursorSetIDs)
        return VectorCursorLibrary.catalog.compactMap { d in
            if d.id == "original" { return CursorSetChoice(descriptor: d, stored: accepted.contains("original") ? "original" : nil) }
            return accepted.contains(d.id) ? CursorSetChoice(descriptor: d, stored: d.id) : nil
        }
    }

    /// The card matching the stored value (null counts as the recorded cursor).
    func selectedCursorSetID() -> String {
        if case .string(let s)? = value("cursor.set_id") { return s }
        return "original"
    }

    func chooseCursorSet(_ choice: CursorSetChoice) {
        set("cursor.set_id", choice.stored.map { .string($0) } ?? .null)
    }
}

extension EditorModel {
    /// Variant of one cursor type (`cursor.variants.<shape>`); missing = standard.
    func cursorVariant(_ style: VectorCursorStyle) -> VectorCursorVariant {
        VectorCursorVariant(rawValue: string("cursor.variants.\(style.shapeID)", default: "standard")) ?? .standard
    }
    func setCursorVariant(_ style: VectorCursorStyle, _ v: VectorCursorVariant) {
        set("cursor.variants.\(style.shapeID)", string: v.rawValue)
    }
}

/// Per-type artwork variants (e.g. arrow / pen tip) of the chosen set.
struct CursorVariantPicker: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Text("Cursor type variants").font(Yap.Font.caption).foregroundStyle(Yap.caption)
        if model.selectedCursorSetID() == "original" {
            InspectorNote("The recorded cursor keeps its captured artwork; variants apply to the authored sets and Touch.")
        }
        ForEach(VectorCursorStyle.allCases, id: \.shapeID) { style in
            let names = VectorCursorLibrary.variants(for: style)
            ChoiceRow(names.first?.name ?? style.shapeID,
                      selection: Binding(get: { model.cursorVariant(style) }, set: { model.setCursorVariant(style, $0) }),
                      options: names.map { ($0.name, $0.id) })
                .accessibilityLabel("\(names.first?.name ?? style.shapeID) variant")
        }
    }
}

/// Horizontal carousel of the cursor sets with render's thumbnails; the chosen one on the bright platter.
struct CursorSetCarousel: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        let selected = model.selectedCursorSetID()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.cursorSetChoices()) { choice in
                    InspectorTile(selected: choice.id == selected, label: "\(choice.descriptor.name) cursor set") {
                        model.chooseCursorSet(choice)
                    } content: {
                        VStack(spacing: 4) {
                            CursorThumbnail(setID: choice.id)
                            Text(choice.descriptor.name).font(Yap.Font.caption).lineLimit(1)
                        }
                    }
                    .frame(width: 92)
                }
            }
        }
        .padding(.horizontal, -2)
    }
}

private struct CursorThumbnail: View {
    let setID: String
    @MainActor private static var cache: [String: CGImage] = [:]
    var body: some View {
        Group {
            if let image = Self.image(setID) {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .frame(width: 80, height: 50).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    @MainActor static func image(_ id: String) -> CGImage? {
        if let c = cache[id] { return c }
        guard let made = try? VectorCursorLibrary.thumbnail(setID: id, size: CGSize(width: 160, height: 100)) else { return nil }
        cache[id] = made; return made
    }
}
