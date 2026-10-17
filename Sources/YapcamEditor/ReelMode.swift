import SwiftUI

/// "Reel preview": a platform's interface areas drawn over the preview so titles and captions can be kept clear of them.
/// The drawing itself is render's `ReelSafeAreaOverlay`, owned by the preview view (never a render layer, never exported);
/// the editor only keeps the choice, remembers it, and hands it to the player through `PreviewOptions.reel`.
public enum ReelMode: String, CaseIterable, Sendable, Identifiable {
    case off, instagram, tiktok
    public var id: String { rawValue }
    public var label: String { switch self { case .off: "Off"; case .instagram: "Instagram"; case .tiktok: "TikTok" } }
}

extension EditorModel {
    public var reelMode: ReelMode { previewOptions.reel }
    /// Reel guides only mean something on a portrait canvas (9:16, 4:5); landscape and square hide the control.
    public var reelPreviewAvailable: Bool { previewAspect < 1 }
    public func setReelMode(_ m: ReelMode) { var o = previewOptions; o.reel = m; setPreviewOptions(o) }
}
