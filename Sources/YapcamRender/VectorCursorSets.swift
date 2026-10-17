import Foundation

/// Original cursor-set descriptors for pickers; artwork is generated from our own paths.
public struct VectorCursorSet: Sendable, Equatable, Identifiable {
    public enum Category: String, CaseIterable, Sendable { case essential, color, precision }
    public let id: String
    public let title: String
    public let category: Category
    public enum Geometry: String, CaseIterable, Sendable {
        case classic, cutPaper, rounded, pill, kite, chevron, leaf, orbit, facet, technical, minimal, accessible
        case plume, stepped, lance, scallop, pennant, ribbon, doubleNib, bracket, droplet, comet
    }
    /// Geometry is independent of color; existing stable IDs now have their own silhouettes.
    public var geometry: Geometry {
        switch id {
        case "paper": .cutPaper
        case "soft-slate": .rounded
        case "soft-cloud", "touch": .pill
        case "lagoon": .kite
        case "coral": .chevron
        case "sage": .leaf
        case "violet": .orbit
        case "gold": .facet
        case "precision-dark": .technical
        case "precision-light": .minimal
        case "signal": .accessible
        case "glacier": .plume
        case "poppy": .stepped
        case "graphite": .lance
        case "linen": .scallop
        case "citrus": .pennant
        case "petal": .ribbon
        case "cobalt": .doubleNib
        case "moss": .bracket
        case "quartz": .droplet
        case "comet": .comet
        default: .classic
        }
    }
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
    /// Twenty-two original Yapcam sets, plus the catalog's Original and Touch.
    /// Every authored set supports all types, variants and point sizes16…128.
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
            set("signal","Signal",.precision,arrow: .narrow,touch: .target,fill: SIMD4(0.08,0.36,0.94,1),weight: 2.6),
            set("glacier","Glacier",.essential,fill: SIMD4(0.65,0.86,0.96,1),outline: SIMD4(0.1,0.26,0.38,1),weight: 1.9),
            set("poppy","Poppy",.color,fill: SIMD4(0.77,0.13,0.29,1),weight: 2.1),
            set("graphite","Graphite",.precision,fill: SIMD4(0.22,0.24,0.28,1),weight: 1.4),
            set("linen","Linen",.essential,fill: SIMD4(0.93,0.88,0.74,1),outline: SIMD4(0.28,0.23,0.17,1),weight: 1.8),
            set("citrus","Citrus",.color,fill: SIMD4(0.88,0.95,0.26,1),outline: SIMD4(0.24,0.3,0.05,1),weight: 2.1),
            set("petal","Petal",.color,fill: SIMD4(0.96,0.58,0.77,1),outline: SIMD4(0.35,0.1,0.27,1),weight: 1.8),
            set("cobalt","Cobalt",.precision,fill: SIMD4(0.12,0.22,0.58,1),weight: 1.6),
            set("moss","Moss",.color,fill: SIMD4(0.32,0.41,0.13,1),weight: 2),
            set("quartz","Quartz",.essential,fill: SIMD4(0.87,0.83,0.96,1),outline: SIMD4(0.27,0.19,0.38,1),weight: 1.8),
            set("comet","Comet",.precision,fill: SIMD4(0.98,0.55,0.17,1),outline: SIMD4(0.28,0.13,0.06,1),weight: 1.6)
        ]
    }()
    static func preset(id: String) -> VectorCursorSet? {
        if id == "touch" {
            var base = presets[0]
            base = VectorCursorSet(id: "touch",title: "Touch",category: .essential,arrow: .rounded,touch: .disc,
                arrowFill: base.arrowFill,handFill: base.handFill,outline: base.outline,handOutline: base.handOutline,
                touchFill: SIMD4(1,1,1,0.28),touchOutline: SIMD4(0.08,0.1,0.14,0.8),weight: 1.5)
            return base
        }
        return presets.first { $0.id==id }
    }
    static func artwork(_ style: VectorCursorStyle,setID: String,size: VectorCursorSize = .regular,scale: CGFloat = 2,
                        variant: VectorCursorVariant = .standard,pressed: Bool = false) throws -> VectorCursorArtwork {
        if setID == "original" { throw RenderError.missingMedia("Original cursor artwork requires the recording's cursor sidecar") }
        guard let preset=preset(id: setID) else { throw RenderError.invalidSettings("Unknown original cursor set: \(setID)") }
        return try artwork(setID == "touch" ? .touch : style,preset: preset,size: size,scale: scale,variant: variant,pressed: pressed)
    }
}
