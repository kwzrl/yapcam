import Foundation

/// Internal release-harness measurements. Durations overlap when CPU, GPU and
/// hardware encoding run together; they are not additive wall-clock phases.
struct ExportVideoDiagnostics: Sendable, Encodable {
    var pipelineDepth: Int
    var renderedFrames=0
    var peakPendingFrames=0
    var encodedFrames=0
    var cpuRenderSeconds=0.0
    var gpuWaitSeconds=0.0
    var gpuExecutionSeconds=0.0
    var gpuTimedFrames=0
    var writerReadySeconds=0.0
    var appendSeconds=0.0
    var audioPreparationSeconds=0.0
    var finishSeconds=0.0
    var wallSeconds=0.0
}
