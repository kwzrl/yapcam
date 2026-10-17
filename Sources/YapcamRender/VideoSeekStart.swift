@preconcurrency import AVFoundation

/// Preserve the preceding VFR neighbour without emitting a second of decoded
/// BGRA preroll. AVAssetReader still handles compressed GOP dependencies itself.
enum VideoSeekStart {
    static func time(asset: AVAsset,track: AVAssetTrack,requested: CMTime) -> CMTime {
        if let range=neighbours(asset: asset,track: track,requested: requested) { return range.start }
        let probe=min(requested,max(.zero,track.timeRange.end-CMTime(value: 1,timescale: 1_000_000_000)))
        return max(.zero,probe-CMTime(value: 1,timescale: 1))
    }
    /// Finite range containing the predecessor and successor, including long VFR
    /// holds. Fully draining it permits AVAssetReaderOutput.reset() legally.
    static func neighbours(asset: AVAsset,track: AVAssetTrack,requested: CMTime) -> CMTimeRange? {
        // B-frame files may have unpresented decode samples beyond the edit's
        // media end. A cold seek into a held tail must select its last real PTS.
        let end=track.timeRange.end
        let probe=end.isNumeric ? min(requested,max(.zero,end-CMTime(value: 1,timescale: 1_000_000_000))) : requested
        if asset.providesPreciseDurationAndTiming,
           let segment=track.segment(forTrackTime: probe), !segment.isEmpty,
           segment.timeMapping.source.duration > .zero, segment.timeMapping.target.duration > .zero {
            // Cursors use sample media time, while AVAssetReader.timeRange uses
            // track time. B-frame edit lists commonly offset these clocks.
            let mapping=segment.timeMapping
            let mediaTime=CMTimeMapTimeFromRangeToRange(probe,fromRange: mapping.target,toRange: mapping.source)
            guard let cursor=track.makeSampleCursor(presentationTimeStamp: mediaTime) else {
                return nil
            }
            let sample=CMTimeMapTimeFromRangeToRange(cursor.presentationTimeStamp,fromRange: mapping.source,toRange: mapping.target)
            if sample.isNumeric, sample >= .zero, sample<=probe {
                var limit=end
                if cursor.stepInPresentationOrder(byCount: 1)==1 {
                    let next=CMTimeMapTimeFromRangeToRange(cursor.presentationTimeStamp,fromRange: mapping.source,toRange: mapping.target)
                    if next.isNumeric,next>sample,next<end {
                        limit=min(end,next+CMTime(value: 1,timescale: 1_000_000_000))
                    }
                }
                if limit>sample { return CMTimeRange(start: sample,end: limit) }
            }
        }
        // Some containers do not offer precise sample cursors. Keep the previous
        // conservative selection path for those assets.
        return nil
    }
}
