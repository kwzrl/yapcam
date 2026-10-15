import Foundation

/// Original cursor-set descriptors for pickers; artwork is generated from our own paths.
public struct VectorCursorSet: Sendable, Equatable, Identifiable {
    public enum Category: String, CaseIterable, Sendable { case essential, color, precision }
    public let id: String
    public let title: String
    public let category: Category
    enum Arrow { case standard, rounded, narrow }
    enum Touch { case disc, ring, target }
    let arrow: Arrow
    let touch: Touch
    let arrowFill: SIMD4<Float>
    let handFill: SIMD4<Float>
    let outline: SIMD4<Float>
    let handOutline: SIMD4<Float>
    let touchFill: SIMD4<Float>
    let touchOutline: SIMD4<Float>
    let weight: Double
}

public extension VectorCursorLibrary {
    /// Twelve original Yapcam sets; each provides every VectorCursorStyle at four logical sizes.
    static let presets: [VectorCursorSet] = {
        let ink=SIMD4<Float>(0.08,0.08,0.08,1),white=SIMD4<Float>(1,1,1,1)
        func set(_ id: String,_ title: String,_ category: VectorCursorSet.Category,
                 arrow: VectorCursorSet.Arrow = .standard,touch: VectorCursorSet.Touch = .disc,
                 fill: SIMD4<Float>,hand: SIMD4<Float>? = nil,outline: SIMD4<Float> = white,
                 handOutline: SIMD4<Float>? = nil,touchFill: SIMD4<Float>? = nil,weight: Double = 2) -> VectorCursorSet {
            VectorCursorSet(id: id,title: title,category: category,arrow: arrow,touch: touch,
                arrowFill: fill,handFill: hand ?? fill,outline: outline,handOutline: handOutline ?? outline,
                touchFill: touchFill ?? SIMD4(fill.x,fill.y,fill.z,0.5),
                touchOutline: SIMD4(outline.x,outline.y,outline.z,0.85),weight: weight)
        }
        return [
            // Classic preserves the previously shipped three cursor rasters exactly.
            VectorCursorSet(id: "classic",title: "Classic",category: .essential,arrow: .standard,touch: .disc,
                arrowFill: ink,handFill: white,outline: white,handOutline: ink,
                touchFill: SIMD4(1,1,1,0.55),touchOutline: SIMD4(0.15,0.15,0.15,0.7),weight: 2),
            set("paper","Paper",.essential,fill: white,hand: SIMD4(0.98,0.96,0.9,1),outline: ink,touchFill: SIMD4(0.08,0.08,0.08,0.2)),
            set("soft-slate","Soft Slate",.essential,arrow: .rounded,fill: SIMD4(0.19,0.25,0.32,1),weight: 2.4),
            set("soft-cloud","Soft Cloud",.essential,arrow: .rounded,fill: SIMD4(0.95,0.97,1,1),outline: SIMD4(0.19,0.25,0.32,1),weight: 1.8),
            set("lagoon","Lagoon",.color,arrow: .rounded,fill: SIMD4(0.02,0.53,0.62,1)),
            set("coral","Coral",.color,fill: SIMD4(0.91,0.25,0.24,1),weight: 2.3),
            set("sage","Sage",.color,arrow: .rounded,touch: .ring,fill: SIMD4(0.24,0.48,0.31,1),weight: 2.2),
            set("violet","Violet",.color,touch: .ring,fill: SIMD4(0.51,0.32,0.77,1)),
            set("gold","Gold",.color,fill: SIMD4(1,0.72,0.16,1),outline: SIMD4(0.22,0.15,0.04,1),weight: 2.1),
            set("precision-dark","Precision Dark",.precision,arrow: .narrow,touch: .target,fill: ink,weight: 1.2),
            set("precision-light","Precision Light",.precision,arrow: .narrow,touch: .target,fill: white,outline: ink,weight: 1.2),
            set("signal","Signal",.precision,arrow: .narrow,touch: .target,fill: SIMD4(0.08,0.36,0.94,1),weight: 2.6)
        ]
    }()
    static func preset(id: String) -> VectorCursorSet? { presets.first { $0.id==id } }
    static func artwork(_ style: VectorCursorStyle,setID: String,size: VectorCursorSize = .regular,scale: CGFloat = 2) throws -> VectorCursorArtwork {
        guard let preset=preset(id: setID) else { throw RenderError.invalidSettings("Unknown original cursor set: \(setID)") }
        return try artwork(style,preset: preset,size: size,scale: scale)
    }
}
