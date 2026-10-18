import Foundation

/// MKT-145: undo/redo keeps the playhead on the same moment of the recording, even when the edit moved it on the timeline.
enum SourceMoment {
    static func source(atTimelineNs t: Int64, in clips: [(clip: TimelineClip, startNs: Int64)]) -> Int64? {
        guard let e = clips.last(where: { $0.startNs <= t }), t <= e.startNs + e.clip.timelineDurationNs else { return nil }
        return e.clip.srcStartNs + Int64(Double(t - e.startNs) * e.clip.speed)
    }
    static func timeline(forSourceNs s: Int64, in clips: [(clip: TimelineClip, startNs: Int64)]) -> Int64? {
        guard let e = clips.first(where: { s >= $0.clip.srcStartNs && s <= $0.clip.srcEndNs }) else { return nil }
        return e.startNs + Int64(Double(s - e.clip.srcStartNs) / max(e.clip.speed, 0.0001))
    }
}

extension EditorModel {
    func followSourceMoment(_ moment: Int64?) {
        guard let moment, let t = SourceMoment.timeline(forSourceNs: moment, in: clipStarts()), t != playheadNs else { return }
        seek(toNs: t)
    }
}

enum Toast {
    static let duration = 2.5
    static func appliedToAll(speed: Double, count: Int) -> String {
        "Applied \(clipSpeedLabel(speed)) to \(count) \(count == 1 ? "clip" : "clips")"
    }
    static func appliedToAll(zoomLevel: Double, count: Int) -> String {
        "Applied \(String(format: "%.1f", zoomLevel))× to \(count) other \(count == 1 ? "zoom" : "zooms")"
    }
}
