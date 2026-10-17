import AppKit

/// Wire IDs shared with Core/Render. Identity is deliberately stricter than
/// NSCursor.isEqual, image hashes, cursor numbers, names, or pixel resemblance.
/// AppKit does not promise semantic identity for cross-process cursor snapshots;
/// those remain unknown unless the observation is an actual standard instance.
enum CapturedCursorShape: String, CaseIterable, Sendable {
    case arrow, text, crosshair
    case pointingHand = "pointing_hand"
    case resizeHorizontal = "resize_horizontal", resizeVertical = "resize_vertical"
    case resizeDiagonalNWSE = "resize_diagonal_nwse", resizeDiagonalNESW = "resize_diagonal_nesw"
    case openHand = "open_hand", closedHand = "closed_hand", notAllowed = "not_allowed"

    @MainActor static let standards: [(NSCursor, Self)] = [
        (.arrow, .arrow), (.pointingHand, .pointingHand), (.iBeam, .text),
        (.columnResize, .resizeHorizontal), (.rowResize, .resizeVertical),
        (.frameResize(position: .topLeft, directions: .all), .resizeDiagonalNWSE),
        (.frameResize(position: .bottomRight, directions: .all), .resizeDiagonalNWSE),
        (.frameResize(position: .topRight, directions: .all), .resizeDiagonalNESW),
        (.frameResize(position: .bottomLeft, directions: .all), .resizeDiagonalNESW),
        (.openHand, .openHand), (.closedHand, .closedHand), (.crosshair, .crosshair),
        (.operationNotAllowed, .notAllowed),
        (.resizeLeftRight, .resizeHorizontal), (.resizeUpDown, .resizeVertical)
    ]

    @MainActor static func identify(_ cursor: NSCursor?) -> Self? {
        guard let cursor else { return nil }
        return identify(ObjectIdentifier(cursor), standards: standards.map { (ObjectIdentifier($0.0), $0.1) })
    }

    static func identify(_ identity: ObjectIdentifier?, standards: [(ObjectIdentifier, Self)]) -> Self? {
        guard let identity else { return nil }
        return standards.first { $0.0 == identity }?.1
    }
}
