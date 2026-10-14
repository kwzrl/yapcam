import Foundation

/// Core has already removed pauses/cuts and applied speed and track-start offsets.
/// Gain endpoints are linear amplitudes of a ramp that is linear in decibels.
public struct RenderAudioRange: Sendable, Decodable {
    public enum Track: String, Sendable, Decodable { case mic, systemAudio = "system_audio" }
    public var track: Track
    public var path: String
    public var fileStartNs: Int64
    public var fileEndNs: Int64
    public var tlStartNs: Int64
    public var tlEndNs: Int64
    public var gainStart: Float
    public var gainEnd: Float
    public init(track: Track,path: String,fileStartNs: Int64,fileEndNs: Int64,tlStartNs: Int64,tlEndNs: Int64,gainStart: Float = 1,gainEnd: Float = 1) {
        self.track=track; self.path=path; self.fileStartNs=fileStartNs; self.fileEndNs=fileEndNs
        self.tlStartNs=tlStartNs; self.tlEndNs=tlEndNs; self.gainStart=gainStart; self.gainEnd=gainEnd
    }
    func validate() throws {
        guard fileStartNs>=0, fileEndNs>=fileStartNs, tlStartNs>=0, tlEndNs>tlStartNs,
              gainStart.isFinite, gainEnd.isFinite, gainStart>=0, gainEnd>=0 else {
            throw RenderError.invalidSettings("Invalid evaluated audio interval")
        }
    }
    func fileNs(atTimelineNs ns: Int64) -> Int64 {
        fileStartNs+Self.scaledOffset(ns-tlStartNs,from: tlEndNs-tlStartNs,to: fileEndNs-fileStartNs)
    }
    func timelineNs(atFileNs ns: Int64) -> Int64 {
        tlStartNs+Self.scaledOffset(ns-fileStartNs,from: fileEndNs-fileStartNs,to: tlEndNs-tlStartNs)
    }
    private static func scaledOffset(_ offset: Int64,from length: Int64,to outputLength: Int64) -> Int64 {
        // Full-width integer multiplication preserves clocks beyond Double's exact range.
        let product=UInt64(offset).multipliedFullWidth(by: UInt64(outputLength))
        let divisor=UInt64(length)
        let (quotient,remainder)=divisor.dividingFullWidth(product)
        return Int64(quotient+(remainder>=divisor-remainder ? 1 : 0))
    }
    func gain(atTimelineNs ns: Int64) -> Float {
        let fraction=min(1,max(0,Double(ns-tlStartNs)/Double(tlEndNs-tlStartNs)))
        if gainStart>0 && gainEnd>0 {
            return Float(exp(log(Double(gainStart))+(log(Double(gainEnd))-log(Double(gainStart)))*fraction))
        }
        return gainStart+(gainEnd-gainStart)*Float(fraction)
    }
}
