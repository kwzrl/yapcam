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
    public func setReelMode(_ m: ReelMode) { var o = previewOptions; o.reel = m; setPreviewOptions(o) }
}
