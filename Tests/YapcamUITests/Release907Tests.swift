import Foundation
import Testing
@testable import YapcamUI

@MainActor @Suite struct Release907OnboardingTests {
    @Test func firstRunAsksForScreenMicCameraThenAccessibility() {
        #expect(OnboardingFlow.firstRun == [.screen, .microphone, .camera, .accessibility])
        #expect(OnboardingFlow.readyChecks == [.screen, .microphone, .camera])
    }

    @Test func screenStageFollowsAskSwitchOnRestartReset() {
        typealias F = OnboardingFlow
        #expect(F.screenStage(granted: false, requested: false, restartedSinceRequest: false) == .ask)
        #expect(F.screenStage(granted: false, requested: true, restartedSinceRequest: false) == .switchOn)
        // A restart that still sees no access: an entry macOS kept for another copy.
        #expect(F.screenStage(granted: false, requested: true, restartedSinceRequest: true) == .notSeenAfterRestart)
        for requested in [false, true] { for restarted in [false, true] {
            #expect(F.screenStage(granted: true, requested: requested, restartedSinceRequest: restarted) == .granted)
        } }
    }

    @Test func allSetNeedsScreenMicrophoneAndCamera() {
        #expect(OnboardingFlow.allSet { _ in true })
        #expect(!OnboardingFlow.allSet { $0 != .camera })
        #expect(!OnboardingFlow.allSet { $0 != .screen })
        // Accessibility is not part of "all set".
        #expect(OnboardingFlow.allSet { $0 != .accessibility })
    }
}

@MainActor @Suite struct Release907TrashTests {
    // #22: deleting a recording only ever moves it to the Trash, complete.
    @Test func trashMovesTheWholePackageToTheTrashAndNeverDeletesIt() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "yapcam-trash-\(UUID().uuidString)", directoryHint: .isDirectory)
        let package = dir.appending(path: "Trash Test.yapcam", directoryHint: .isDirectory)
        try fm.createDirectory(at: package.appending(path: "recording/seg-000"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appending(path: "project.json"))
        try Data(repeating: 7, count: 4096).write(to: package.appending(path: "recording/seg-000/screen.mov"))
        defer { try? fm.removeItem(at: dir) }

        let trashed = try #require(try ProjectActions.trash(package))
        defer { try? fm.removeItem(at: trashed) }
        #expect(!fm.fileExists(atPath: package.path))
        #expect(trashed.path.contains("/.Trash/"))
        #expect(try Data(contentsOf: trashed.appending(path: "recording/seg-000/screen.mov")).count == 4096)
        #expect(fm.fileExists(atPath: trashed.appending(path: "project.json").path))
    }
}
