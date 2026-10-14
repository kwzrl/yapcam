import Darwin
import Foundation

/// Advisory lock released by the OS on process death. Paused sessions retain it,
/// so recovery cannot rewrite a package that still belongs to a live session.
final class RecordingPackageLease: @unchecked Sendable {
    private let descriptor: Int32

    init(package: URL) throws {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let recording = package.appendingPathComponent("recording")
        guard recording.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else {
            throw CaptureError.writerFailed("Recording directory leaves the package")
        }
        let path = recording.appendingPathComponent(".capture.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CaptureError.writerFailed("Cannot lock recording package") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CaptureError.writerFailed("Recording package is still in use")
        }
        self.descriptor = descriptor
    }

    deinit { _ = flock(descriptor, LOCK_UN); _ = close(descriptor) }

    static func isAvailable(_ package: URL) -> Bool {
        let path = package.appendingPathComponent("recording/.capture.lock").path
        guard FileManager.default.fileExists(atPath: path) else { return true }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        _ = flock(descriptor, LOCK_UN)
        return true
    }
}
