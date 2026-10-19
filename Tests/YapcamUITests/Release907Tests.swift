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
