import AppKit

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect          // global points
    let scale: CGFloat
    var pixelSize: CGSize { CGSize(width: frame.width * scale, height: frame.height * scale) }
    var isMain: Bool { CGDisplayIsMain(id) != 0 }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum Displays {
    static func all() -> [DisplayInfo] {
        NSScreen.screens.compactMap { s in
            guard let id = s.displayID else { return nil }
            return DisplayInfo(id: id, name: s.localizedName, frame: s.frame, scale: s.backingScaleFactor)
        }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? { NSScreen.screens.first { $0.displayID == id } }

    static func info(for id: CGDirectDisplayID) -> DisplayInfo? { all().first { $0.id == id } }

    /// The display to record when the saved one is gone: main display.
    static func resolve(_ saved: UInt32) -> DisplayInfo? {
        info(for: saved) ?? all().first(where: \.isMain) ?? all().first
    }
}
