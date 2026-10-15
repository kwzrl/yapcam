import Foundation
import CoreText

/// Local system fonts, resolved through CoreText; no font files are bundled.
public enum RenderTextFontFamily: String, CaseIterable, Codable, Sendable {
    case sans, serif, mono

    func font(size: Double) -> CTFont {
        let name: String
        switch self {
        case .sans: name = "Helvetica" // Preserve the existing text rendering default.
        case .serif: name = "Times-Roman"
        case .mono: name = "Menlo"
        }
        return CTFontCreateWithName(name as CFString,size,nil)
    }
}
