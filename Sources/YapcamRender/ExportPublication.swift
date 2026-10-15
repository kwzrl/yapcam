import Foundation

/// Publish a verified pair without replacing existing files. Rollback can only
/// unlink the same file identity that this operation moved, never a replacement.
enum ExportPublication {
    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        init(_ url: URL) throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let device = attrs[.systemNumber] as? NSNumber,
                  let inode = attrs[.systemFileNumber] as? NSNumber else { throw RenderError.write("Export output is not a regular local file") }
            self.device = device.uint64Value; self.inode = inode.uint64Value
        }
    }
    static func publish(_ files: [(source: URL, destination: URL)]) throws {
        var owned: [(URL,Identity)] = []
        do {
            for file in files {
                let identity = try Identity(file.source)
                try FileManager.default.moveItem(at: file.source, to: file.destination)
                owned.append((file.destination,identity))
            }
        } catch {
            for (url,identity) in owned.reversed() where (try? Identity(url)) == identity { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}
