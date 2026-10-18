import XCTest
@testable import YapcamEditor

@MainActor final class PlaceSwitchingTests: XCTestCase {
    override func tearDown() { EditorWindows.onRecordRequested = nil; EditorWindows.onShowProjects = nil }

    func testHooksAreCalledAndGateCommands() {
        let model = EditorModel(project: FakeProject(durationNs: 20_000_000_000), player: FakePlayer())
        XCTAssertFalse(model.canRecordFromEditor)
        XCTAssertFalse(model.placeCommands.contains { $0.enabled })
        var recorded = 0, shown = 0
        EditorWindows.onRecordRequested = { recorded += 1 }
        EditorWindows.onShowProjects = { shown += 1 }
        XCTAssertTrue(model.placeCommands.allSatisfy { $0.enabled })
        model.placeCommands.first { $0.title == "New Recording" }?.run()
        model.placeCommands.first { $0.title == "Show Projects" }?.run()
        XCTAssertEqual([recorded, shown], [1, 1])
        XCTAssertTrue(model.filteredCommands("new rec").contains { $0.title == "New Recording" })
    }
}
