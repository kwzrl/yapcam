import Darwin
import Foundation

/// Advisory lock released by the OS on process death. Paused sessions retain it,
/// so recovery cannot rewrite a package that still belongs to a live session.
final class RecordingPackageLease: @unchecked Sendable {
    private let descriptor: Int32
    private let path: String

    init(package: URL) throws {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let recording = package.appendingPathComponent("recording")
        guard recording.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else {
            throw CaptureError.writerFailed("Recording directory leaves the package")
        }
        let path = recording.appendingPathComponent(".capture.lock").path
        // A closing owner unlinks while holding its lock. A contender might have
        // opened that inode just before unlink, then locked it after close. Never
        // use such a detached inode: reopen the current path instead.
        for _ in 0..<4 {
            let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw CaptureError.writerFailed("Cannot lock recording package") }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw CaptureError.writerFailed("Recording package is still in use")
            }
            if Self.matchesPath(descriptor, path) {
                self.descriptor = descriptor
                self.path = path
                return
            }
            _ = close(descriptor)
        }
        throw CaptureError.writerFailed("Recording package lock changed during acquisition")
    }

    deinit {
        // Remove only our own inode, before unlocking. Do not remove a replacement
        // file or leave completed/recovered/transcribed packages with a stale lock.
        if Self.matchesPath(descriptor, path) { _ = unlink(path) }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private static func matchesPath(_ descriptor: Int32, _ path: String) -> Bool {
        var held = stat(), current = stat()
        return fstat(descriptor, &held) == 0 && lstat(path, &current) == 0
            && held.st_dev == current.st_dev && held.st_ino == current.st_ino
    }

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
