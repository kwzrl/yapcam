import Foundation

/// Decodes Core's evaluated, split music/click instructions without importing model types.
struct EvaluatedAudioOverlay: Decodable {
    let source: String
    let path: String
    let tlStartNs: Int64
    let tlEndNs: Int64
    let fileStartNs: Int64
    let fileDurationNs: Int64
    let loop: Bool
    let gain: Float
    let gainStart: Float
    let gainEnd: Float
    let fadeInNs: Int64
    let fadeOutNs: Int64
    let envelopeStartNs: Int64
    let envelopeEndNs: Int64
    func overlay() throws -> AudioOverlay {
        let content: AudioOverlay.Source
        switch source {
        case "file": content = .media(relativePath: path)
        case "calm": content = .music(.calm)
        case "bright": content = .music(.bright)
        case "soft": content = .click(.soft)
        case "crisp": content = .click(.crisp)
        default: throw RenderError.unavailable("Unsupported Core audio source: \(source)")
        }
        let result=AudioOverlay(source: content,startNs: tlStartNs,endNs: tlEndNs,sourceStartNs: fileStartNs,gain: gain,loops: loop,fadeInNs: fadeInNs,fadeOutNs: fadeOutNs,gainStart: gainStart,gainEnd: gainEnd,envelopeStartNs: envelopeStartNs,envelopeEndNs: envelopeEndNs,sourceDurationNs: fileDurationNs,multiplyFades: true)
        try result.validate()
        return result
    }
}
