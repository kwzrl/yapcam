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

@Suite struct Release907UpdateReminderTests {
    // #25: any known update shows on the toolbar until it is installed, hidden or gone.
    @Test func reminderFollowsChecksHideAndInstall() {
        var r = UpdateReminder()
        #expect(!r.shows)
        r.found("0.11.1"); #expect(r.shows && r.version == "0.11.1")
        r.hide(); #expect(!r.shows)
        r.found("0.11.1"); #expect(!r.shows)          // the same version stays hidden
        r.found("0.11.2"); #expect(r.shows)           // a newer one shows again
        r.installing(); #expect(!r.shows && r.version == nil)
        r.found("0.11.3"); r.noUpdate(); #expect(!r.shows)
    }
}

@MainActor @Suite struct RC2DeviceDefaultsTests {
    // RC2 (1): a new user records with the system camera and microphone once access is granted.
    @Test func onboardingPicksTheSystemDefaultOnlyWhenNothingIsSelected() {
        #expect(DeviceDefaults.pick(current: nil, onboarding: true, granted: true, systemDefault: "cam") == "cam")
        #expect(DeviceDefaults.pick(current: nil, onboarding: true, granted: false, systemDefault: "cam") == nil)
        #expect(DeviceDefaults.pick(current: "other", onboarding: true, granted: true, systemDefault: "cam") == "other")
        // After onboarding a missing device is a choice ("Don't record camera") and stays.
        #expect(DeviceDefaults.pick(current: nil, onboarding: false, granted: true, systemDefault: "cam") == nil)
    }
}

@MainActor @Suite struct DevelopmentUpdateTests {
    @Test func developmentBundleCannotStartProductionUpdater() {
        #expect(!Updates.allowsUpdates(info: ["YapcamDevelopmentBuild": true]))
        #expect(Updates.allowsUpdates(info: [:]))
        #expect(Updates.allowsUpdates(info: ["YapcamDevelopmentBuild": false]))
    }
}
