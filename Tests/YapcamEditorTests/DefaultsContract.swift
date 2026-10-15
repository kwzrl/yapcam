import Foundation
import YapcamCore
@testable import YapcamEditor

/// The factory-default contract of core (docs/FORMATS.md "Default contract"): `Project.create` applies revision 1
/// (aspect Auto = the recording's aspect at the output height, padding ratio 0.10, corners 16, motion blur 1, classic cursor,
/// no cursor smoothing, no click effect, 125/12/1.5 screen spring); projects whose fields are absent keep the legacy values.
/// Tests derive their expectations from the project's own `defaults_revision` so they hold for both.
@MainActor enum DefaultsContract {
    /// Canvas size core must evaluate for a project, from its stored aspect and output size.
    static func expectedCanvas(_ m: EditorModel, source: (w: Double, h: Double)) -> (w: Double, h: Double) {
        let size = m.numbers("canvas.output_size"); let h = size.count == 2 ? size[1] : 1080
        let aspect = m.string("canvas.aspect", default: "16:9")
        func even(_ x: Double) -> Double { (x / 2).rounded() * 2 }
        if aspect == "source" { return (even(h * source.w / source.h), h) }
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return (even(h * parts[0] / parts[1]), h) }
        return (size.first ?? 1920, h)
    }
}
