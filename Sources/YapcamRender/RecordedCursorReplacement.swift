import CoreGraphics

/// Never guess a custom app cursor's type from its id or bitmap. Capture must
/// positively identify a standard shape before its recorded art can be replaced.
struct RecordedCursorReplacement {
    let style: VectorCursorStyle
    let heightPoints: CGFloat
    let displayHeight: CGFloat
    let rasterScale: Int

    init?(shape: String?, sizePoints: CGSize, bitmapSize: CGSize,
          pixelsPerPoint: CGFloat, enabled: Bool) {
        guard enabled, let shape, let style = VectorCursorStyle(shapeID: shape), style != .touch,
              [sizePoints.width,sizePoints.height,bitmapSize.width,bitmapSize.height,pixelsPerPoint]
                .allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let recordedDensity = min(bitmapSize.width/sizePoints.width,bitmapSize.height/sizePoints.height)
        // Ignore rounding at a native-sized bitmap; replace once it is enlarged.
        guard pixelsPerPoint > recordedDensity * 1.05 else { return nil }
        self.style = style
        displayHeight = sizePoints.height
        heightPoints = min(128,max(16,sizePoints.height))
        rasterScale = Int(ceil(min(8,max(2,pixelsPerPoint * (displayHeight/heightPoints)))))
    }

    func geometry(artworkSize: CGSize, hotspot: CGPoint) -> (size: CGSize, hotspot: CGPoint) {
        let factor = displayHeight/artworkSize.height
        return (CGSize(width: artworkSize.width*factor,height: displayHeight),
                CGPoint(x: hotspot.x*factor,y: hotspot.y*factor))
    }
}
