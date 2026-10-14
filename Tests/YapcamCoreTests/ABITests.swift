import Testing
import YapcamCore

@Test func abiVersionMatchesHeader() {
    #expect(YapcamCore.abiVersion == 3)
    #expect(YapcamCore.abiVersion == UInt32(YC_ABI_VERSION))
    #expect(MemoryLayout<YcFrame>.size == 328)
    #expect(MemoryLayout<YcFrameHighlight>.size == 80)
    #expect(MemoryLayout<YcFrameExtras>.size == 2600)
    #expect(MemoryLayout<YcFrameExtras>.alignment == 8)
    #expect(MemoryLayout<YcFrameExtras>.offset(of: \.cursor_style) == 8)
    #expect(MemoryLayout<YcFrameExtras>.offset(of: \.window_chrome) == 24)
    #expect(MemoryLayout<YcFrameExtras>.offset(of: \.fade_opacity) == 32)
    #expect(MemoryLayout<YcFrameExtras>.offset(of: \.highlight_count) == 36)
    #expect(MemoryLayout<YcFrameExtras>.offset(of: \.highlights) == 40)
}

@Test func additiveMotionABILayoutMatchesHeader() {
    #expect(MemoryLayout<YcFrameMotion>.size == 24)
    #expect(MemoryLayout<YcFrameMotion>.alignment == 8)
    #expect(MemoryLayout<YcFrameMotion>.offset(of: \.tl_ns) == 0)
    #expect(MemoryLayout<YcFrameMotion>.offset(of: \.cursor_rotation_rad) == 8)
    #expect(MemoryLayout<YcFrameMotion>.offset(of: \.cursor_motion_blur) == 12)
    #expect(MemoryLayout<YcFrameMotion>.offset(of: \.zoom_motion_blur) == 16)
    #expect(MemoryLayout<YcFrameMotion>.offset(of: \.pan_motion_blur) == 20)
}
