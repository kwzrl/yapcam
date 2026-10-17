import XCTest
import AVFoundation
import CryptoKit
import YapcamCore
@testable import YapcamRender

final class MusicLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-render-music-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        return url
    }
    private func cleanup(_ url: URL) {
        print("Cleanup render music tests: \(url.path)")
        try? FileManager.default.removeItem(at: url)
    }
    func testLibraryHasFourGenresEighteenStableScoresAndExactDurations() throws {
        XCTAssertEqual(MusicLibrary.Category.allCases.map(\.title),["Commercial","Electronic","Instrumental","Lo-fi"])
        XCTAssertEqual(MusicLibrary.catalog().count,18)
        XCTAssertEqual(MusicLibrary.Category.allCases.map { MusicLibrary.catalog(category: $0).count },[5,5,4,4])
        XCTAssertEqual(Set(MusicLibrary.tracks.map(\.id)).count,18)
        XCTAssertEqual(try JSONDecoder().decode([MusicLibrary.Track].self,from: JSONEncoder().encode(MusicLibrary.tracks)),MusicLibrary.tracks)
        var hashes=Set<SHA256.Digest>()
        for track in MusicLibrary.tracks {
            XCTAssertEqual(MusicLibrary.track(id: track.id),track)
            let pcm=try MusicLibrary.samples(track)
            XCTAssertEqual(pcm.count,Int((Double(track.durationNs)/1e9*48_000).rounded()))
            XCTAssertEqual(pcm.first,0); XCTAssertEqual(pcm.last,0)
            let rms=sqrt(pcm.reduce(0.0) { $0+pow(Double($1)/32767,2) }/Double(pcm.count))
            XCTAssertGreaterThan(rms,0.04); XCTAssertLessThan(rms,0.4)
            XCTAssertLessThan(pcm.map { abs(Int($0)) }.max()!,31_129,"No clipped track: \(track.id)")
            XCTAssertTrue(hashes.insert(SHA256.hash(data: ProceduralAudio.wav(pcm))).inserted,"Each score is distinct")
        }
        let track=try XCTUnwrap(MusicLibrary.track(id: "open-road"))
        XCTAssertEqual(try MusicLibrary.samples(track),try MusicLibrary.samples(track),"Synthesis is deterministic")
        XCTAssertNil(MusicLibrary.track(id: "../outside"))
    }
    func testEveryGenreWritesAPlayablePCMFileAndProtectsExistingFiles() async throws {
        let root=try directory(); defer { cleanup(root) }
        for category in MusicLibrary.Category.allCases {
            let track=try XCTUnwrap(MusicLibrary.catalog(category: category).first)
            let url=root.appendingPathComponent(track.id).appendingPathExtension("wav")
            try await MusicLibrary.write(trackID: track.id,to: url)
            let file=try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate,48_000)
            XCTAssertEqual(file.fileFormat.channelCount,1)
            XCTAssertEqual(file.length,Int64((Double(track.durationNs)/1e9*48_000).rounded()))
            let buffer=try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,frameCapacity: 4096))
            try file.read(into: buffer)
            let samples=try XCTUnwrap(buffer.floatChannelData)[0]
            XCTAssertTrue((0..<Int(buffer.frameLength)).contains { abs(samples[$0])>0.01 })
            let original=try Data(contentsOf: url)
            do { try await MusicLibrary.write(trackID: track.id,to: url); XCTFail("Existing file was overwritten") }
            catch { XCTAssertEqual(try Data(contentsOf: url),original) }
        }
        for id in ["unknown","../outside"] {
            do { try await MusicLibrary.write(trackID: id,to: root.appendingPathComponent("invalid.wav")); XCTFail("Invalid selection") }
            catch { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("invalid.wav").path)) }
        }
        let cancelled=Task {
            while !Task.isCancelled { await Task.yield() }
            try await MusicLibrary.write(trackID: "open-road",to: root.appendingPathComponent("cancelled.wav"))
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Cancellation ignored") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.wav").path))
    }
    func testSelectedTrackBecomesPortableProjectMediaWithOneUndoStep() async throws {
        let root=try directory(); defer { cleanup(root) }
        let fixture=URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/synthetic/basic.yapcam")
        let package=root.appendingPathComponent("music.yapcam")
        try FileManager.default.copyItem(at: fixture,to: package)
        let project=try Project.create(package: package)
        let before=try project.renderSnapshot()
        try await MusicLibrary.apply(trackID: "felt-lines",to: project)
        let frozen=try project.renderSnapshot()
        let music=try frozen.renderAudioOverlays()
        XCTAssertEqual(music.count,1)
        let overlay=try XCTUnwrap(music.first)
        guard case .media(let path)=overlay.source else { return XCTFail("Import must use portable file media") }
        XCTAssertTrue(path.hasPrefix("assets/")); XCTAssertFalse(path.contains(".."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent(path).path))
        XCTAssertEqual(overlay.gain,0.05,accuracy: 0.00001)
        XCTAssertTrue(overlay.loops)
        XCTAssertEqual(overlay.sourceDurationNs,MusicLibrary.track(id: "felt-lines")?.durationNs)
        XCTAssertTrue(try before.renderAudioOverlays().isEmpty)
        try project.save()
        XCTAssertEqual(try Project.open(package: package).renderAudioOverlays(),music)
        try project.undo()
        XCTAssertTrue(try project.renderAudioOverlays().isEmpty,"One undo removes the import and music record")
        XCTAssertEqual(try frozen.renderAudioOverlays(),music)
    }
}
