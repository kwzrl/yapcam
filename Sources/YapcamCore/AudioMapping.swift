import Foundation

private struct AudioRangeQuery: Encodable {
    let q = "map_audio_ranges"
    let track: String
    let path: String
    let ranges: [FileRange]
    struct FileRange: Encodable {
        let fileStartNs: Int64
        let fileEndNs: Int64
        enum CodingKeys: String, CodingKey {
            case fileStartNs = "file_start_ns", fileEndNs = "file_end_ns"
        }
    }
}
private struct TimelineRangeRow: Decodable {
    let tlStartNs: Int64
    let tlEndNs: Int64
}
extension Project {
    /// Map file-local decoder intervals onto the current edited timeline. The
    /// package-relative mediaPath comes from audio_ranges (recording/seg-.../...).
    /// Cuts/speeds, repeated source clips and track starts use Rust's exact clock;
    /// overlapping/adjacent results merge. Call after decoding to use current edits,
    /// or call on a snapshot to keep an analysis tied to one frozen timeline.
    public func mapAudioRanges(_ ranges: [SilenceRange], track: String, mediaPath: String) throws -> [SilenceRange] {
        let request = AudioRangeQuery(track: track, path: mediaPath, ranges: ranges.map {
            AudioRangeQuery.FileRange(fileStartNs: $0.startNs, fileEndNs: $0.endNs)
        })
        let data = try JSONEncoder().encode(request)
        let rows = try query(String(decoding: data, as: UTF8.self), as: [TimelineRangeRow].self)
        return rows.map { SilenceRange(startNs: $0.tlStartNs, endNs: $0.tlEndNs) }
    }
}
