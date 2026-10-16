import AppKit

/// The licences of bundled third-party software, shipped inside the app.
enum ThirdPartyNotices {
    static let resource = "THIRD_PARTY_NOTICES"

    static func url(in bundle: Bundle = .main) -> URL? { bundle.url(forResource: resource, withExtension: "txt") }

    @MainActor static func open(bundle: Bundle = .main, opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        guard let url = url(in: bundle), opener(url) else {
            let a = NSAlert()
            a.messageText = "The notices file could not be opened"
            a.informativeText = "Third-party licences are listed in THIRD_PARTY_NOTICES in the Yapcam repository."
            a.runModal()
            return
        }
    }
}
