import SwiftUI

/// "Reel preview": draws where a vertical platform's own interface covers the picture, so titles and captions can be
/// kept clear of it. Preview only (never exported). Own drawing; the fractions are approximations of the platforms' layouts.
public enum ReelMode: String, CaseIterable, Sendable, Identifiable {
    case off, instagram, tiktok
    public var id: String { rawValue }
    public var label: String { switch self { case .off: "Off"; case .instagram: "Instagram Reels"; case .tiktok: "TikTok" } }

    /// Zones in preview-normalised coordinates (x, y, width, height in 0…1) with a short name.
    public struct Zone: Equatable, Sendable { public var name: String; public var rect: CGRect }
    public var zones: [Zone] {
        switch self {
        case .off: []
        case .instagram:
            [Zone(name: "Top bar", rect: CGRect(x: 0, y: 0, width: 1, height: 0.12)),
             Zone(name: "Caption", rect: CGRect(x: 0, y: 0.80, width: 0.82, height: 0.20)),
             Zone(name: "Buttons", rect: CGRect(x: 0.86, y: 0.52, width: 0.14, height: 0.48))]
        case .tiktok:
            [Zone(name: "Top bar", rect: CGRect(x: 0, y: 0, width: 1, height: 0.10)),
             Zone(name: "Caption", rect: CGRect(x: 0, y: 0.74, width: 0.80, height: 0.26)),
             Zone(name: "Buttons", rect: CGRect(x: 0.84, y: 0.46, width: 0.16, height: 0.54))]
        }
    }
    /// The area that stays free of platform interface: the full frame minus the zones' bounding bands.
    public var safeRect: CGRect {
        switch self {
        case .off: CGRect(x: 0, y: 0, width: 1, height: 1)
        case .instagram: CGRect(x: 0.04, y: 0.12, width: 0.80, height: 0.68)
        case .tiktok: CGRect(x: 0.04, y: 0.10, width: 0.78, height: 0.64)
        }
    }
}

struct ReelOverlay: View {
    let mode: ReelMode
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(Array(mode.zones.enumerated()), id: \.offset) { _, z in
                    let r = CGRect(x: z.rect.minX * g.size.width, y: z.rect.minY * g.size.height, width: z.rect.width * g.size.width, height: z.rect.height * g.size.height)
                    Rectangle().fill(Color.black.opacity(0.35)).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                        .overlay(alignment: .topLeading) {
                            Text(z.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(4).offset(x: r.minX, y: r.minY)
                        }
                }
                let s = mode.safeRect
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: s.width * g.size.width, height: s.height * g.size.height)
                    .offset(x: s.minX * g.size.width, y: s.minY * g.size.height)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension EditorModel {
    public func setReelMode(_ m: ReelMode) { reelMode = m; defaults.set(m.rawValue, forKey: "editor.reelMode") }
}
