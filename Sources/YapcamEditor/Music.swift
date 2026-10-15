import Foundation
import YapcamCore

public struct MusicSourceInfo: Equatable, Identifiable, Sendable { public var id: String; public var name: String; public var durationNs: Int64 }
public let builtInMusic = [MusicSourceInfo(id: "calm", name: "Calm", durationNs: 8_000_000_000),
                           MusicSourceInfo(id: "bright", name: "Bright", durationNs: 8_000_000_000)]

public struct MusicItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var startNs: Int64, endNs: Int64
    public var source: String            // file | calm | bright
    public var path: String
    public var fileStartNs: Int64, fileDurationNs: Int64
    public var gainDb: Double
    public var loop: Bool
    public var fadeInNs: Int64, fadeOutNs: Int64
    public var duckEnabled: Bool
    public var duckGainDb: Double
    public var span: TimeSpan { TimeSpan(startNs: startNs, endNs: endNs) }
    public var title: String { source == "file" ? (path as NSString).lastPathComponent : (builtInMusic.first { $0.id == source }?.name ?? source) }
}

extension EditorModel {
    private func num(_ v: JSONValue?, _ d: Double) -> Double { if case .number(let x)? = v { x } else { d } }
    public var music: [MusicItem] {
        guard case .array(let rows)? = value("audio.music") else { return [] }
        return rows.compactMap { row in
            guard case .object(let o) = row, case .string(let id)? = o["id"], case .number(let a)? = o["tl_start_ns"], case .number(let b)? = o["tl_end_ns"] else { return nil }
            var source = "file", path = ""
            if case .string(let s)? = o["source"] { source = s }
            if case .string(let p)? = o["path"] { path = p }
            var loop = true; if case .bool(let l)? = o["loop"] { loop = l }
            var duck = false, duckGain = -12.0
            if case .object(let d)? = o["ducking"] { if case .bool(let e)? = d["enabled"] { duck = e }; duckGain = num(d["gain_db"], -12) }
            return MusicItem(id: id, startNs: Int64(a), endNs: Int64(b), source: source, path: path,
                             fileStartNs: Int64(num(o["file_start_ns"], 0)), fileDurationNs: Int64(num(o["file_duration_ns"], 0)),
                             gainDb: num(o["gain_db"], -18), loop: loop, fadeInNs: Int64(num(o["fade_in_ns"], 500_000_000)),
                             fadeOutNs: Int64(num(o["fade_out_ns"], 500_000_000)), duckEnabled: duck, duckGainDb: duckGain)
        }
    }

    private func rawMusicRows() -> [JSONValue] { if case .array(let r)? = value("audio.music") { r } else { [] } }

    /// Patches one record in place, preserving fields the editor doesn't model (e.g. duck ranges).
    private func patchMusic(id: String, _ patch: [String: JSONValue]) {
        let rows = rawMusicRows().map { row -> JSONValue in
            guard case .object(var o) = row, case .string(id)? = o["id"] else { return row }
            for (k, v) in patch { o[k] = v }
            return .object(o)
        }
        set("audio.music", .array(rows))
    }

    @discardableResult
    public func addBuiltInMusic(_ source: MusicSourceInfo) -> String? {
        let end = durationNs
        guard end - playheadNs >= minZoomDurationNs else { lastError = "Not enough room here."; return nil }
        let id = "music-" + UUID().uuidString.prefix(8).lowercased()
        let row: JSONValue = .object(["id": .string(id), "tl_start_ns": .number(Double(playheadNs)), "tl_end_ns": .number(Double(end)),
                                      "source": .string(source.id), "file_duration_ns": .number(Double(source.durationNs)),
                                      "gain_db": .number(-18), "loop": .bool(true),
                                      "fade_in_ns": .number(500_000_000), "fade_out_ns": .number(500_000_000)])
        set("audio.music", .array(rawMusicRows() + [row]))
        guard lastError == nil else { return nil }
        selection = .music(id); return id
    }

    public func importMusicFile(_ url: URL) {
        guard !isClosed else { return }
        let start = playheadNs
        musicTask = Task { [weak self] in
            guard let self, !isClosed else { return }
            do {
                try Task.checkCancellation()
                try await project.importMusic(url, startNs: start)
                if !isClosed { noteExternalEdit() }
            } catch is CancellationError {
            } catch { if !isClosed { lastError = "Couldn't add music: \(error.localizedDescription)" } }
        }
    }
    public func waitForMusicImport() async { await musicTask?.value }

    public func setMusicGain(id: String, _ db: Double) { patchMusic(id: id, ["gain_db": .number(min(max(db, -96), 24))]) }
    public func setMusicLoop(id: String, _ on: Bool) { patchMusic(id: id, ["loop": .bool(on)]) }
    public func setMusicFades(id: String, inNs: Int64, outNs: Int64) {
        patchMusic(id: id, ["fade_in_ns": .number(Double(max(0, inNs))), "fade_out_ns": .number(Double(max(0, outNs)))])
    }
    public func setMusicDucking(id: String, enabled: Bool, gainDb: Double) {
        guard let row = rawMusicRows().first(where: { if case .object(let o) = $0, case .string(id)? = o["id"] { true } else { false } }),
              case .object(let o) = row else { return }
        var d: [String: JSONValue] = [:]
        if case .object(let cur)? = o["ducking"] { d = cur }
        d["enabled"] = .bool(enabled); d["gain_db"] = .number(min(max(gainDb, -60), 0))
        patchMusic(id: id, ["ducking": .object(d)])
    }
    public func removeMusic(id: String) {
        set("audio.music", .array(rawMusicRows().filter { if case .object(let o) = $0, case .string(id)? = o["id"] { false } else { true } }))
    }
    func commitMusicSpan(id: String, start: Int64, end: Int64) {
        patchMusic(id: id, ["tl_start_ns": .number(Double(start)), "tl_end_ns": .number(Double(end))])
    }
}
