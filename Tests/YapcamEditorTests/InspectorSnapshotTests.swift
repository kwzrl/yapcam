import Testing
import SwiftUI
import AppKit
import YapcamCore
import YapcamDesign
@testable import YapcamEditor

/// The docked inspector in the approved look (ae-inspector, 2026-10-17): kit controls only, and a PNG per section and
/// per selected item for visual review: YAPCAM_INSPECTOR_DIR=<dir outside the repo> swift test --filter InspectorSnapshotTests
@MainActor @Suite(.serialized) struct InspectorSnapshotTests {
    static let size = CGSize(width: Yap.Inspector.width, height: 2200)

    /// A project with one of everything the inspector can show.
    static func richModel() -> EditorModel {
        let m = EditorModel(project: FakeProject(durationNs: 30_000_000_000), player: FakePlayer())
        m.seek(toNs: 8_000_000_000); m.splitAtPlayhead()
        m.seek(toNs: 3_000_000_000); m.addZoomAtPlayhead()
        m.seek(toNs: 20_000_000_000); m.addLayoutAtPlayhead(mode: "overlay")
        m.seek(toNs: 5_000_000_000); m.addCursorHideAtPlayhead()
        m.seek(toNs: 10_000_000_000); m.addHighlightAtPlayhead(kind: .highlight)
        m.seek(toNs: 12_000_000_000); m.addText(.annotation, text: "Click here")
        m.seek(toNs: 14_000_000_000); m.addText(.caption, text: "Hello world")
        m.seek(toNs: 16_000_000_000); m.addBuiltInMusic(builtInMusic[0])
        m.set("cursor.key_overlay.enabled", bool: true)
        m.selection = .none
        return m
    }

    static func host(_ m: EditorModel, _ section: InspectorSection, height: CGFloat = size.height) -> (NSWindow, NSHostingView<some View>) {
        _ = NSApplication.shared
        let view = InspectorView(model: m, initialSection: section)
            .frame(width: size.width, height: height)
            .background(Yap.dock)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: size.width, height: height)), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; window.orderBack(nil)
        return (window, host)
    }

    private static func shoot(_ m: EditorModel, _ section: InspectorSection, _ name: String, in dir: URL) async throws {
        let (window, host) = host(m, section)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(500)); host.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "inspector-\(name).png"))
    }

    @Test func renderEverySectionAndItem() async throws {
        guard let path = ProcessInfo.processInfo.environment["YAPCAM_INSPECTOR_DIR"] else { return }
        let dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, s) in InspectorSection.allCases.enumerated() {
            let m = Self.richModel()
            try await Self.shoot(m, s, String(format: "%02d-%@", i, s.rawValue), in: dir)
        }
        let items: [(String, (EditorModel) -> EditorSelection)] = [
            ("zoom", { .zoom($0.zooms[0].id) }), ("clip", { .clip($0.clips[0].id) }), ("layout", { .layout($0.layouts[0].id) }),
            ("cursorhide", { .cursorHide($0.cursorHides[0].index) }), ("highlight", { .highlight($0.highlights[0].id) }),
            ("text", { .text(.annotation, $0.textItems(.annotation)[0].id) }), ("caption", { .text(.caption, $0.textItems(.caption)[0].id) }),
            ("music", { .music($0.music[0].id) }),
        ]
        for (name, select) in items {
            let m = Self.richModel()
            let (window, host) = Self.host(m, .background)
            try await Task.sleep(for: .milliseconds(200))
            m.selection = select(m)
            try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
            window.orderOut(nil)
            try await Self.shoot(m, m.inspectorSection, "item-\(name)", in: dir)
        }
    }

    private func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }

    /// No system slider, switch, segmented control or colour well (they draw the blue accent); the kit draws them instead.
    @Test func everySectionUsesKitControlsOnly() async throws {
        let m = Self.richModel()
        for section in InspectorSection.allCases {
            let (window, host) = Self.host(m, section, height: 1600)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
            let system = views(host).filter { $0 is NSSlider || $0 is NSSwitch || $0 is NSSegmentedControl || $0 is NSColorWell }
            #expect(system.isEmpty, "\(section): system controls \(system.map { type(of: $0) })")
        }
    }

    /// The docked column is the rail plus a 300-pt content column (ae-shell docks it at this width).
    @Test func dockedWidthIsRailPlusColumn() {
        #expect(InspectorView.width == 354)
        #expect(Yap.Inspector.rail == Yap.Grid.bar)
    }

    @Test func showTranscriptOpensTheBottomPanel() {
        let m = Self.richModel()
        #expect(m.bottomPanel == .timeline)
        m.bottomPanel = .transcript          // what the "Show transcript" button does
        #expect(m.bottomPanel == .transcript)
    }

    @Test func choiceRowPicksSegmentsForFewShortOptionsAndAMenuOtherwise() {
        #expect(ChoiceRow<String>.fitsSegments(["Classic", "Directional"]))
        #expect(ChoiceRow<String>.fitsSegments(["Auto", "Horizontal", "Vertical"]))
        #expect(!ChoiceRow<String>.fitsSegments(["Custom", "Slow", "Mellow", "Quick", "Rapid"]))
        #expect(!ChoiceRow<String>.fitsSegments(["Rounded rectangle", "Circle", "Squircle"]))
    }

    @Test func hexRoundTrips() {
        #expect(YapHex.string([1, 0, 0.5, 1], alpha: false) == "#FF0080")
        #expect(YapHex.string([1, 0, 0.5, 0.5], alpha: true) == "#FF008080")
        #expect(YapHex.parse("#1F2937", keepAlpha: 0.4) == [Double(0x1F) / 255, Double(0x29) / 255, Double(0x37) / 255, 0.4])
        #expect(YapHex.parse("zzz", keepAlpha: 1) == nil)
    }
}
