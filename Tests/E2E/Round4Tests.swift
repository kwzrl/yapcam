import XCTest
import AVFoundation
import YapcamCore
@testable import YapcamRender

/// Round 4 programmatic export checks on the synthetic fixture (real core project -> real render exporter ->
/// ffprobe / frame diff). NOT a user-interaction test: nothing here goes through a window or a menu.
@MainActor
final class Round4Tests: XCTestCase {
    var work: URL!
    var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam") }
    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-e2e-r4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: work) }

    func newProject() throws -> Project {
        let pkg = work.appendingPathComponent("p-\(UUID().uuidString).yapcam"); try FileManager.default.copyItem(at: fixture, to: pkg)
        return try Project.create(package: pkg)
    }
    func export(_ p: Project, _ name: String, vfr: Bool = false, fps: Int = 30) async throws -> URL {
        let out = work.appendingPathComponent(name)
        var s = ExportSettings(outputHeight: 720, fps: fps); s.variableFrameRate = vfr
        _ = try await Exporter(project: p, settings: s, destination: out).run { _ in }
        return out
    }
    func gray(_ url: URL, atSeconds t: Double) throws -> (w: Int, h: Int, px: [UInt8]) {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try g.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
        let w = img.width, h = img.height; var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)); return (w, h, px)
    }
    func stats(_ f: (w: Int, h: Int, px: [UInt8]), _ r: (x0: Double, y0: Double, x1: Double, y1: Double)) -> (mean: Double, std: Double) {
        var v: [Double] = []
        for y in Int(r.y0 * Double(f.h))..<Int(r.y1 * Double(f.h)) { for x in Int(r.x0 * Double(f.w))..<Int(r.x1 * Double(f.w)) { v.append(Double(f.px[y * f.w + x])) } }
        let m = v.reduce(0, +) / Double(v.count); return (m, (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot())
    }
    func meanAbsDiff(_ a: (w: Int, h: Int, px: [UInt8]), _ b: (w: Int, h: Int, px: [UInt8]), _ r: (x0: Double, y0: Double, x1: Double, y1: Double)) -> Double {
        var s = 0.0, n = 0.0
        for y in Int(r.y0 * Double(a.h))..<Int(r.y1 * Double(a.h)) { for x in Int(r.x0 * Double(a.w))..<Int(r.x1 * Double(a.w)) { s += abs(Double(a.px[y * a.w + x]) - Double(b.px[y * b.w + x])); n += 1 } }
        return s / n
    }
    func ffprobe(_ args: [String]) throws -> String {
        let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
        p.arguments = args; p.standardOutput = pipe; try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(decoding: d, as: UTF8.self)
    }

    /// The masked region is blurred (changed, smoother than the unmasked frame, still textured), not an opaque cover.
    func testBlurMaskIsBlurNotOpaque() async throws {
        let base = try newProject(), masked = try newProject()
        _ = try masked.apply(.insertTimelineItem(.mask, startNs: 1_000_000_000, durationNs: 2_000_000_000, patch: ["kind": .string("blur")]))
        let a = try gray(try await export(base, "base.mp4"), atSeconds: 1.5), b = try gray(try await export(masked, "masked.mp4"), atSeconds: 1.5)
        let inside = (x0: 0.30, y0: 0.30, x1: 0.70, y1: 0.70), outside = (x0: 0.02, y0: 0.02, x1: 0.18, y1: 0.18)
        let sa = stats(a, inside), sb = stats(b, inside)
        let dIn = meanAbsDiff(a, b, inside), dOut = meanAbsDiff(a, b, outside)
        print("R4 blur inside std base=\(sa.std) masked=\(sb.std) meanAbsDiff inside=\(dIn) outside=\(dOut)")
        XCTAssertGreaterThan(dIn, 1.0, "masked region must differ from the unmasked export")
        XCTAssertLessThan(dOut, 2.0, "pixels outside the mask must be unchanged")
        XCTAssertLessThan(sb.std, sa.std, "blur removes detail")
        XCTAssertGreaterThan(sb.std, 1.0, "an opaque cover would be flat (std ~ 0)")
        // before the mask starts the frame must be unmasked
        let pre = try gray(try await export(masked, "masked2.mp4"), atSeconds: 0.3), preBase = try gray(try await export(base, "base2.mp4"), atSeconds: 0.3)
        XCTAssertLessThan(meanAbsDiff(pre, preBase, inside), 2.0)
    }

    /// Cursor sets as the editor stores them (`cursor.set_id`: unset = Original, "touch", an authored set): the exported
    /// pixels differ per set, and every variant still draws a cursor (differs from a cursor-less export).
    func testCursorSetsOriginalAndTouchInExport() async throws {
        func project(_ set: String?) throws -> Project {
            let p = try newProject(); try p.apply(.set(path: "cursor.set_id", value: set.map(JSONValue.string) ?? .null)); return p
        }
        let hidden = try newProject(); try hidden.apply(.set(path: "cursor.visible", value: .bool(false)))
        var urls: [String: URL] = ["hidden": try await export(hidden, "hidden.mp4")]
        for (name, set) in [("original", nil), ("touch", "touch"), ("coral", "coral")] as [(String, String?)] { urls[name] = try await export(project(set), "\(name).mp4") }
        func diff(_ x: String, _ y: String, _ t: Double) throws -> Int {
            let a = try gray(urls[x]!, atSeconds: t), b = try gray(urls[y]!, atSeconds: t)
            var c = 0; for i in 0..<a.px.count where abs(Int(a.px[i]) - Int(b.px[i])) > 12 { c += 1 }; return c
        }
        for t in [1.0, 2.0] {
            let r = ["original", "touch", "coral"].map { ($0, try! diff($0, "hidden", t)) }
            print("R4 cursor t=\(t): px differing from cursor-less export \(r); original-vs-touch \(try diff("original", "touch", t)) original-vs-coral \(try diff("original", "coral", t))")
            for (n, c) in r { XCTAssertGreaterThan(c, 20, "\(n) cursor must be drawn") }
            XCTAssertGreaterThan(try diff("original", "touch", t), 20, "Touch must look different from the recorded cursor")
            XCTAssertGreaterThan(try diff("touch", "coral", t), 20)
        }
    }

    /// Variable-frame-rate export: container times are valid (monotonic, no duplicates), duration and frame count sane vs constant rate.
    func testVariableFrameRateTimestamps() async throws {
        let p = try newProject()
        let cfr = try await export(p, "cfr.mp4"), vfr = try await export(p, "vfr.mp4", vfr: true)
        func pts(_ u: URL) throws -> [Double] {
            try ffprobe(["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time", "-of", "csv=p=0", u.path])
                .split(separator: "\n").compactMap { Double($0.split(separator: ",")[0]) }.sorted()
        }
        let c = try pts(cfr), v = try pts(vfr)
        let dc = Set(zip(c.dropFirst(), c).map { (($0 - $1) * 1000).rounded() }).count   // distinct rounded deltas (ms)
        let dv = zip(v.dropFirst(), v).map { $0 - $1 }
        print("R4 vfr frames cfr=\(c.count) vfr=\(v.count) last cfr=\(c.last ?? 0) vfr=\(v.last ?? 0) vfr delta min=\(dv.min() ?? 0) max=\(dv.max() ?? 0) distinct=\(Set(dv.map { ($0 * 1000).rounded() }).count) cfrDistinct=\(dc)")
        XCTAssertFalse(v.isEmpty)
        XCTAssertTrue(dv.allSatisfy { $0 > 0 }, "PTS strictly increasing")
        XCTAssertEqual(v.last ?? 0, c.last ?? 0, accuracy: 0.2)
        XCTAssertLessThanOrEqual(v.count, c.count + 1, "VFR never writes more frames than constant rate")
    }
}
