import XCTest
@testable import YapcamRender

final class LivePreviewAccessTests: XCTestCase {
    private var root: URL!
    private var lockURL: URL { root.appendingPathComponent(".app-lock") }
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-app-lock-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testUnlockedSessionAllowsPreviewInBothModesWithoutCreatingLock() throws {
        try requireLivePreviewAccess(lockURL: lockURL,strict: false)
        try requireLivePreviewAccess(lockURL: lockURL,strict: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testQALockSkipsNormalPreviewWithoutMutatingOwnership() throws {
        let owner=Data("QA owns this synthetic test lock".utf8)
        try owner.write(to: lockURL)
        XCTAssertThrowsError(try requireLivePreviewAccess(lockURL: lockURL,strict: false)) { error in
            XCTAssertTrue(error is XCTSkip)
        }
        XCTAssertEqual(try Data(contentsOf: lockURL),owner)
    }

    func testStrictBenchmarkFailsExplicitlyUntilQAReleasesLock() throws {
        let owner=Data("QA owns this synthetic test lock".utf8)
        try owner.write(to: lockURL)
        XCTAssertThrowsError(try requireLivePreviewAccess(lockURL: lockURL,strict: true)) { error in
            guard let renderError=error as? RenderError,case .unavailable(let reason)=renderError else {
                XCTFail("Expected an explicit QA ownership blocker"); return
            }
            XCTAssertTrue(reason.contains(".app-lock"))
        }
        XCTAssertEqual(try Data(contentsOf: lockURL),owner)
        // Only remove our synthetic lock, modelling QA releasing its session.
        try FileManager.default.removeItem(at: lockURL)
        try requireLivePreviewAccess(lockURL: lockURL,strict: true)
    }
}
