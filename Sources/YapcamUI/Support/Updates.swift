import AppKit
import Sparkle

/// What the toolbar shows about updates, kept apart from Sparkle so it can be tested.
struct UpdateReminder: Equatable {
    /// Version of an update that is known and not installed; nil when there is none.
    private(set) var version: String?
    /// The user hid the reminder for this version.
    private(set) var hidden = false

    var shows: Bool { version != nil && !hidden }

    /// A check (manual or automatic) found this update. A newer version shows again even after Hide.
    mutating func found(_ v: String) { if v != version { hidden = false }; version = v }
    mutating func noUpdate() { version = nil; hidden = false }
    mutating func installing() { version = nil; hidden = false }
    mutating func hide() { hidden = true }
}

/// Sparkle updates from https://yapcam.app/appcast.xml (Info.plist SUFeedURL, EdDSA-signed, no system profile).
/// Automatic checks are on without Sparkle's permission prompt (SUEnableAutomaticChecks); Settings has the switch,
/// the app menu "Check for Updates…". With the switch on, every launch checks in the background right away.
/// Any update a check finds puts a quiet "Update" + "Hide" on the toolbar; background checks never open a window.
@MainActor final class Updates: NSObject, ObservableObject {
    static let shared = Updates()
    @Published private(set) var reminder = UpdateReminder()
    private var controller: SPUStandardUpdaterController?

    /// Hidden test switch: `defaults write mov.yapcam.Yapcam YapcamUpdateFeedOverride http://127.0.0.1:8765/appcast-test.xml`.
    static let feedOverrideKey = "YapcamUpdateFeedOverride"

    func start() {
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        if c.updater.automaticallyChecksForUpdates { c.updater.checkForUpdatesInBackground() }
    }

    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }
    func checkForUpdates() { controller?.checkForUpdates(nil) }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { objectWillChange.send(); controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var showsReminder: Bool { reminder.shows }
    var waitingVersion: String? { reminder.version }
    func hideReminder() { reminder.hide() }
}

extension Updates: @preconcurrency SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        AppDefaults.store.string(forKey: Self.feedOverrideKey).flatMap { $0.isEmpty ? nil : $0 }
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { reminder.found(item.displayVersionString) }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { reminder.noUpdate() }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { reminder.installing() }
}

extension Updates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Background checks never open Sparkle's window; the toolbar reminder carries them. "Update" opens it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        reminder.found(update.displayVersionString)
    }
}
