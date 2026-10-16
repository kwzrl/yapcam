import Foundation

extension RenderConfiguration.CursorStyle {
    init(_ vector: VectorCursorStyle) {
        switch vector {
        case .arrow: self = .arrow
        case .pointer: self = .pointer
        case .touch: self = .touch
        case .text: self = .text
        case .resizeHorizontal: self = .resizeHorizontal
        case .resizeVertical: self = .resizeVertical
        case .resizeDiagonalNWSE: self = .resizeDiagonalNWSE
        case .resizeDiagonalNESW: self = .resizeDiagonalNESW
        case .openHand: self = .openHand
        case .closedHand: self = .closedHand
        case .crosshair: self = .crosshair
        case .notAllowed: self = .notAllowed
        }
    }
    var vector: VectorCursorStyle? {
        switch self {
        case .recorded: nil
        case .arrow: .arrow
        case .pointer: .pointer
        case .touch: .touch
        case .text: .text
        case .resizeHorizontal: .resizeHorizontal
        case .resizeVertical: .resizeVertical
        case .resizeDiagonalNWSE: .resizeDiagonalNWSE
        case .resizeDiagonalNESW: .resizeDiagonalNESW
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .crosshair: .crosshair
        case .notAllowed: .notAllowed
        }
    }
}

/// Pure policy shared by preview/export and portable selection tests.
struct CursorRenderSelection {
    let recorded: Bool
    let style: VectorCursorStyle
    let preset: VectorCursorSet
    let variant: VectorCursorVariant
    let pressed: Bool
    init(configuration c: RenderConfiguration,recordedShape: String?,clickProgress: Float) {
        recorded = c.cursorSetID == "original" || (c.cursorSetID == nil && c.cursorStyle == .recorded)
        style = c.cursorSetID == "touch" ? .touch : c.cursorStyle.vector ?? recordedShape.flatMap(VectorCursorStyle.init(shapeID:)) ?? .arrow
        // Frame validation rejects unknown ids before this policy is evaluated.
        preset = VectorCursorLibrary.preset(id: c.cursorSetID ?? "classic") ?? VectorCursorLibrary.presets[0]
        variant = c.cursorVariants[style.shapeID] ?? .standard
        pressed = style == .touch && (c.cursorPressed ?? (clickProgress >= 0 && clickProgress < 0.5))
    }
}
