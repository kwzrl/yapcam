import XCTest
import YapcamCapture
import YapcamCore

/// Runs RecordingSession.recover on an interrupted package (e.g. app killed with kill -9).
/// env YAPCAM_INTERRUPTED_PACKAGE=/path/Recording.yapcam ; the package is copied, never modified.
final class RecoverCheckTests: XCTestCase {
    func testRecoverInterruptedPackage() async throws {
        guard let p = ProcessInfo.processInfo.environment["YAPCAM_INTERRUPTED_PACKAGE"] else { throw XCTSkip("YAPCAM_INTERRUPTED_PACKAGE not set") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-e2e-recover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("r.yapcam")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: p), to: pkg)
        let found = RecordingSession.interruptedPackages(in: dir)
        print("RECOVER found interrupted: \(found.map(\.lastPathComponent))")
        XCTAssertEqual(found.count, 1, "package with status=recording must be listed as interrupted")
        let out = try RecordingSession.recover(pkg)
        let data = try Data(contentsOf: out.appendingPathComponent("recording/session.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segs = try XCTUnwrap(json["segments"] as? [[String: Any]])
        let dur = segs.reduce(0.0) { $0 + (($1["duration_ns"] as? Double) ?? 0) } / 1e9
        print("RECOVER status=\(json["status"] ?? "?") segments=\(segs.count) duration_s=\(dur)")
        XCTAssertEqual(json["status"] as? String, "complete", "recover finalizes the package")
        XCTAssertGreaterThan(dur, 5)
        // The recovered package must open in core.
        let project = try Project.create(package: out)
        print("RECOVER core duration_s=\(Double(project.durationNs) / 1e9)")
        XCTAssertGreaterThan(project.durationNs, 5_000_000_000)
        // The recovered screen track must decode.
        let ff = Process(); ff.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ff.arguments = ["-v", "error", "-i", out.appendingPathComponent("recording/\(segs[0]["files"].flatMap { ($0 as? [String: String])?["screen"] } ?? "seg-000/screen.mov")").path, "-f", "null", "-"]
        try ff.run(); ff.waitUntilExit()
        XCTAssertEqual(ff.terminationStatus, 0)
    }
}
