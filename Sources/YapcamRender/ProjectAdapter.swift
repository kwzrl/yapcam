// This guard is temporary until Lead rebases the render worktree onto integrated core.
// Integration validation defines it against the real Core implementation, never a production fake.
#if YAPCAM_CORE_PROJECT_AVAILABLE
import YapcamCore
import Metal
import Foundation

extension Project: RenderProjectSource {
    public func renderSnapshot() throws -> any RenderProjectSource { try snapshot() }
    public func renderClips() throws -> [RenderClip] {
        struct Row: Decodable { let srcStartNs: Int64; let srcEndNs: Int64; let speed: Double }
        return try query("{\"q\":\"clips\"}",as: [Row].self).map { RenderClip(srcStartNs: $0.srcStartNs,srcEndNs: $0.srcEndNs,speed: $0.speed) }
    }
    public func renderBackgroundAsset(index: UInt32) throws -> URL {
        struct Asset: Decodable { let path: String }
        let assets=try query("{\"q\":\"assets\"}",as: [Asset].self)
        guard Int(index)<assets.count else { throw RenderError.missingMedia("Background asset index \(index) is unavailable") }
        return try packageMediaURL(assets[Int(index)].path,root: packageURL)
    }
}

public extension FrameCompositor {
    convenience init(device: MTLDevice,project: Project) throws { try self.init(device: device,project: project as any RenderProjectSource) }
}

@MainActor public extension PreviewPlayer {
    convenience init(project: Project) throws {
        try self.init(project: project as any RenderProjectSource)
        observeChanges(name: Project.didChange,object: project)
    }
}

public extension Exporter {
    convenience init(project: Project,settings: ExportSettings,destination: URL) throws { try self.init(project: project as any RenderProjectSource,settings: settings,destination: destination) }
}
#endif
