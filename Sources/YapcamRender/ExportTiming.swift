import CoreMedia

/// Integer frame-grid arithmetic: every timestamp rounds once, independently of previous frames.
enum ExportTiming {
    static func frameCount(durationNs: Int64,fps: Int) -> Int {
        Int(durationNs/1_000_000_000)*fps + (Int(durationNs%1_000_000_000)*fps+999_999_999)/1_000_000_000
    }
    static func offsetNs(index: Int,fps: Int) -> Int64 {
        CMTimeConvertScale(CMTime(value: Int64(index),timescale: Int32(fps)),timescale: 1_000_000_000,method: .roundHalfAwayFromZero).value
    }
    static func gifDelay(index: Int,count: Int,durationNs: Int64) -> Double {
        let centiseconds=max(count,Int((Double(durationNs)/1e9*100).rounded()))
        let next=Int((Double(index+1)*Double(centiseconds)/Double(count)).rounded())
        let previous=Int((Double(index)*Double(centiseconds)/Double(count)).rounded())
        return Double(next-previous)/100
    }
}
