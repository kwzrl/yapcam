import AppKit
import Sparkle

/// Sparkle updates from https://yapcam.app/appcast.xml (Info.plist SUFeedURL, EdDSA-signed, no system profile).
/// Sparkle asks on the second launch whether to check automatically; Settings has the switch, the app menu
/// "Check for Updates…". A scheduled update found while Yapcam is in the background does not pop a window: the
/// toolbar shows a quiet "Update" with "Hide" (Sparkle's gentle reminders).
@MainActor final class Updates: NSObject, ObservableObject {
    static let shared = Updates()
    /// Version of an update waiting behind the toolbar's "Update" button; nil when there is none.
    @Published private(set) var waitingVersion: String?
    /// The user hid the toolbar reminder for this update.
    @Published var reminderHidden = false
    private var controller: SPUStandardUpdaterController?

    /// Hidden test switch: `defaults write mov.yapcam.Yapcam YapcamUpdateFeedOverride http://127.0.0.1:8765/appcast-test.xml`.
    static let feedOverrideKey = "YapcamUpdateFeedOverride"

    func start() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var showsReminder: Bool { waitingVersion != nil && !reminderHidden }
}

extension Updates: @preconcurrency SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        AppDefaults.store.string(forKey: Self.feedOverrideKey).flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// In front: Sparkle shows its window as usual. In the background: the toolbar reminder instead.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        waitingVersion = update.displayVersionString
        reminderHidden = false
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { waitingVersion = nil }
    func standardUserDriverWillFinishUpdateSession() { waitingVersion = nil }
}
