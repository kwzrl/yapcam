import XCTest
import YapcamCore
import ImageIO
@testable import YapcamRender

final class BackgroundLibraryTests: XCTestCase {
    func testOriginalLibraryRastersAreDistinctAndDeterministic() throws {
        var signatures=Set<Data>()
        for preset in BackgroundLibrary.presets {
            let image=try BackgroundLibrary.image(for: preset,width: 64,height: 40)
            let data=try XCTUnwrap(image.dataProvider?.data) as Data
            XCTAssertEqual(image.width,64); XCTAssertEqual(image.height,40)
            XCTAssertEqual(data,try BackgroundLibrary.image(for: preset,width: 64,height: 40).dataProvider?.data as Data?)
            XCTAssertTrue(signatures.insert(data).inserted,"Duplicate artwork")
        }
        XCTAssertEqual(Set(BackgroundLibrary.presets.map(\.category)),Set(BackgroundPreset.Category.allCases))
    }
    func testWallpaperAndGradientPersistAndEachUndoInOneStep() async throws {
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-wallpaper-project-\(UUID().uuidString).yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        let project=try Project.create(package: package), original=try project.frame(atNs: 0)
        let wallpaper=try XCTUnwrap(BackgroundLibrary.preset(id: "blue-hills"))
        _ = try await BackgroundLibrary.apply(wallpaper,to: project,width: 120,height: 80)
        let frame=try project.frame(atNs: 0)
        XCTAssertEqual(frame.background_kind,2)
        let url=try project.renderBackgroundAsset(index: frame.background_asset)
        let source=try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,nil))
        let image=try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        XCTAssertEqual(image.width,120); XCTAssertEqual(image.height,80)
        try project.save()
        XCTAssertEqual(try Project.open(package: package).frame(atNs: 0).background_kind,2)
        try project.undo()
        XCTAssertEqual(try project.frame(atNs: 0).background_kind,original.background_kind)
        _ = try await BackgroundLibrary.apply(try XCTUnwrap(BackgroundLibrary.preset(id: "soft-sage")),to: project)
        XCTAssertEqual(try project.frame(atNs: 0).background_kind,1)
        try project.undo()
        XCTAssertEqual(try project.frame(atNs: 0).background_kind,original.background_kind)
    }
}
