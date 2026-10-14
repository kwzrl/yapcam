import CoreGraphics
import Testing
@testable import YapcamCapture

@Test(arguments: [1.0, 2.0]) func areaGeometryKeepsDisplayLocalPointsSeparateFromNativePixels(scale: Double) throws {
    let displays = [CGRect(x: 0, y: 0, width: 1680, height: 1050),
                    CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                    CGRect(x: 1680, y: -1200, width: 1920, height: 1200)]
    let local = CGRect(x: 120, y: 80, width: 800, height: 600)
    let expectedOrigins = [CGPoint(x: 120, y: 80), CGPoint(x: -1800, y: 80), CGPoint(x: 1800, y: -1120)]
    let expectedPixels = scale == 1 ? [800, 600] : [1600, 1200]
    for (display, origin) in zip(displays, expectedOrigins) {
        let geometry = try CaptureGeometry.area(displayBounds: display, localRect: local, scale: scale)
        #expect(geometry.rect == CGRect(origin: origin, size: local.size))
        #expect([geometry.pixelWidth, geometry.pixelHeight] == expectedPixels)
        let pointer = CGPoint(x: origin.x + 400, y: origin.y + 300)
        #expect(geometry.local(pointer) == CGPoint(x: 400, y: 300))
        let mapping = CaptureCoordinateMapping.fitted(source: geometry.rect, outputSize: local.size)
        #expect(mapping.local(pointer) == CGPoint(x: 400, y: 300))
        // The pointer may leave the selected area without being clamped or scaled.
        #expect(mapping.local(CGPoint(x: origin.x - 20, y: origin.y - 30)) == CGPoint(x: -20, y: -30))
    }
}

@Test(arguments: [1.0, 2.0]) func windowGeometryRetainsGlobalFrameOnAnyDisplayAtBothScales(scale: Double) throws {
    let frames = [CGRect(x: 30, y: 40, width: 900, height: 600),
                  CGRect(x: -1560, y: -900, width: 900, height: 600),
                  CGRect(x: 2100, y: 200, width: 900, height: 600)]
    let expectedPixels = scale == 1 ? [900, 600] : [1800, 1200]
    for frame in frames {
        let geometry = try CaptureGeometry(rect: frame, scale: scale)
        #expect(geometry.rect == frame)
        #expect([geometry.pixelWidth, geometry.pixelHeight] == expectedPixels)
        #expect(geometry.local(CGPoint(x: frame.midX, y: frame.midY)) == CGPoint(x: 450, y: 300))
        #expect(geometry.local(frame.origin) == .zero)
    }
}

@Test(arguments: [1.0, 2.0]) func movedAndResizedWindowAcrossDisplaysFitsInitialSurface(scale: Double) throws {
    let initial = try CaptureGeometry(rect: CGRect(x: -1400, y: -200, width: 800, height: 600), scale: scale)
    let moved = try CaptureGeometry(rect: CGRect(x: 1780, y: 100, width: 400, height: 400), scale: scale == 1 ? 2 : 1)
    let mapping = CaptureCoordinateMapping.fitted(source: moved.rect, outputSize: initial.rect.size)
    #expect(mapping.destination == CGRect(x: 100, y: 0, width: 600, height: 600))
    #expect(mapping.local(moved.rect.origin) == CGPoint(x: 100, y: 0))
    #expect(mapping.local(CGPoint(x: moved.rect.midX, y: moved.rect.midY)) == CGPoint(x: 400, y: 300))
    #expect(mapping.local(CGPoint(x: moved.rect.maxX, y: moved.rect.maxY)) == CGPoint(x: 700, y: 600))
    #expect(mapping.cursorScale == 1.5)
    // Encoded output keeps initial pixels, even when the window moves between scales.
    let expectedPixels = scale == 1 ? [800, 600] : [1600, 1200]
    #expect([initial.pixelWidth, initial.pixelHeight] == expectedPixels)
}

@Test func areaGeometryRejectsGlobalOrPixelCoordinatesAndInvalidSelections() throws {
    let display = CGRect(x: -1920, y: -1080, width: 1680, height: 1050)
    let invalid = [CGRect(x: -1800, y: -1000, width: 800, height: 600), // already-global points
                   CGRect(x: 240, y: 160, width: 1600, height: 1200), // Retina pixels, not points
                   CGRect(x: 1500, y: 900, width: 400, height: 400), // straddles the display edge
                   CGRect.zero,
                   CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                   CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)]
    for rect in invalid {
        #expect(throws: CaptureError.sourceUnavailable) {
            try CaptureGeometry.area(displayBounds: display, localRect: rect, scale: 2)
        }
    }
    #expect(throws: CaptureError.sourceUnavailable) {
        try CaptureGeometry.area(displayBounds: .zero, localRect: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1)
    }
}
