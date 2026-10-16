import SwiftUI

/// One spacing scale and the shared geometry of inspector rows, so every slider row lines up.
enum EditorMetrics {
    /// Spacing scale: 4 / 8 / 12 / 16 / 24.
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
    /// Width of the right-aligned value label next to a slider ("48 pt", "0.30", "1.5 s").
    static let valueWidth: CGFloat = 62
    /// Room kept for the "reset to default" button, even when a row has none, so slider tracks have equal length.
    static let resetSlot: CGFloat = 20
}

extension View {
    /// Right-aligned, tabular-digit value label of a slider row.
    func sliderValueLabel() -> some View {
        monospacedDigit().foregroundStyle(.secondary).frame(width: EditorMetrics.valueWidth, alignment: .trailing).accessibilityHidden(true)
    }
}
