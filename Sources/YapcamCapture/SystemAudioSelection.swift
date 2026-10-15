import Foundation
import ScreenCaptureKit

public struct CaptureApplication: Identifiable, Sendable, Equatable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

public enum SystemAudioSelection: Sendable, Codable, Equatable {
    case off
    case allApplications
    /// Stable bundle identifiers; resolved to the current processes on each start/resume.
    case applications(bundleIDs: [String])
}

enum SystemAudioPolicy {
    static func applications(_ values: [CaptureApplication], ownBundleID: String? = Bundle.main.bundleIdentifier) -> [CaptureApplication] {
        var seen = Set<String>()
        return values.filter { !$0.bundleID.isEmpty && $0.bundleID != ownBundleID && seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Never broaden an empty or stale checklist into all-app capture.
    static func selectedBundleIDs(_ selection: SystemAudioSelection, available: Set<String>) throws -> Set<String>? {
        switch selection {
        case .off: return []
        case .allApplications: return nil
        case .applications(let ids):
            let requested = Set(ids.filter { !$0.isEmpty })
            guard !requested.isEmpty, requested.isSubset(of: available) else {
                throw CaptureError.writerFailed("Select at least one running application for system audio; a selected application may have closed.")
            }
            return requested
        }
    }

    @MainActor static func filter(selection: SystemAudioSelection, display: SCDisplay,
                                  content: SCShareableContent) throws -> SCContentFilter {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = content.applications.filter { $0.processID != ownPID }
        if let ids = try selectedBundleIDs(selection, available: Set(candidates.map(\.bundleIdentifier))) {
            return SCContentFilter(display: display, including: candidates.filter { ids.contains($0.bundleIdentifier) }, exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ownPID }, exceptingWindows: [])
    }
}

/// Audio has its own content filter: selecting its apps never changes the picture,
/// and window/area capture can still record audio from all selected applications.
@MainActor final class CaptureStreamGroup: CaptureSessionStream {
    private let video: any CaptureSessionStream
    private let audio: (any CaptureSessionStream)?
    private var videoStarted = false
    private var audioStarted = false
    init(video: any CaptureSessionStream, audio: (any CaptureSessionStream)?) {
        self.video = video; self.audio = audio
    }
    func startCapture() async throws {
        do {
            if let audio { audioStarted = true; try await audio.startCapture() }
            videoStarted = true
            try await video.startCapture()
        } catch {
            try? await stopCapture()
            throw error
        }
    }
    func stopCapture() async throws {
        var failure: Error?
        if videoStarted {
            videoStarted = false
            do { try await video.stopCapture() } catch { failure = error }
        }
        if audioStarted, let audio {
            audioStarted = false
            do { try await audio.stopCapture() } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
    func updateContentFilter(_ filter: SCContentFilter) async throws {
        try await video.updateContentFilter(filter)
    }
}
