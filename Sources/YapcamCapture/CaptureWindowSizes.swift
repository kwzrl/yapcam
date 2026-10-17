import Foundation

public struct CaptureWindowSizePreset: Sendable, Equatable, Identifiable {
    public enum Group: String, CaseIterable, Sendable { case widescreen = "16:9", classic = "4:3", portrait = "9:16", wide = "16:10", square = "1:1" }
    public let group: Group
    public let size: CGSize
    public var id: String { "\(group.rawValue):\(Int(size.width))x\(Int(size.height))" }

    /// Exact logical sizes. Unlike an aspect-fit operation, a preset never changes
    /// its advertised size to fit the screen. The picker can append custom/saved sizes.
    public static func fitting(in displaySize: CGSize) -> [Self] {
        guard displaySize.width.isFinite, displaySize.height.isFinite else { return [] }
        let groups: [(Group, [(Int, Int)])] = [
            (.widescreen, [(1280, 720), (1920, 1080), (2560, 1440)]),
            (.classic, [(640, 480), (800, 600), (1024, 768), (1280, 960), (1600, 1200)]),
            (.portrait, [(720, 1280), (1080, 1920), (1440, 2560)]),
            (.wide, [(640, 400), (1280, 800), (1440, 900), (1680, 1050), (1920, 1200), (2560, 1600)]),
            (.square, [(640, 640), (800, 800), (1024, 1024), (1280, 1280), (1600, 1600)])
        ]
        return groups.flatMap { group, sizes in
            sizes.compactMap { width, height in
                let size = CGSize(width: width, height: height)
                return size.width <= displaySize.width && size.height <= displaySize.height ? Self(group: group, size: size) : nil
            }
        }
    }
}
