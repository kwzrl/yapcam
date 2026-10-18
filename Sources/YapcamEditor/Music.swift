import Foundation
import YapcamCore
import AVFoundation
import AppKit

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
        guard end - playheadNs >= minItemNs else { lastError = "Not enough room here."; return nil }
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
        let start = music.isEmpty ? 0 : playheadNs          // the first background audio covers the whole video
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

// MARK: background audio library (own authored tracks), volume, mute, user folder, preview

extension EditorModel {
    /// Reference default: background audio at 5 % (linear) = −26.02 dB.
    public static let defaultMusicVolume = 0.05
    public static let defaultMusicGainDb = 20 * log10(defaultMusicVolume)
    public static func musicGainDb(forVolume v: Double) -> Double { v <= 0.0001 ? -96 : max(20 * log10(min(v, 1)), -96) }
    public static func musicVolume(forGainDb db: Double) -> Double { db <= -95 ? 0 : min(pow(10, db / 20), 1) }

    /// Library categories in the reference's order, then the tracks of the user's own folder.
    public var musicCategories: [(id: String, title: String)] {
        var seen: [String] = [], out: [(String, String)] = []
        for t in project.musicLibrary where !seen.contains(t.category) { seen.append(t.category); out.append((t.category, t.categoryTitle)) }
        return out
    }
    public func musicTracks(in category: String) -> [LibraryTrack] { project.musicLibrary.filter { $0.category == category } }

    /// Picks a library track as the one background track: it covers the whole timeline (looping, 5 % volume) and replaces any
    /// earlier library track (CAM-37). Own files stay. Replacing is a separate undo step from adding.
    public func addLibraryMusic(trackID: String) {
        guard !isClosed else { return }
        let start: Int64 = 0
        guard durationNs - start >= minItemNs else { lastError = "Not enough room here."; return }
        if music.contains(where: { $0.source == trackID }) { return }       // already the active track
        if music.contains(where: { $0.source != "file" }) {
            let keep = rawMusicRowsForPatch().filter { if case .object(let o) = $0, case .string(let s)? = o["source"] { s == "file" } else { true } }
            set("audio.music", .array(keep))
        }
        musicTask = Task { [weak self] in
            guard let self, !isClosed else { return }
            do {
                try await project.addLibraryMusic(trackID: trackID, startNs: start)
                if !isClosed { noteExternalEdit() }
            } catch is CancellationError {
            } catch { if !isClosed { lastError = "Couldn't add music: \(error.localizedDescription)" } }
        }
    }

    // Volume of all background audio (linear 0…1; each track keeps its own fades/ducking/loop).
    public var musicVolume: Double { music.map { Self.musicVolume(forGainDb: $0.gainDb) }.max() ?? Self.defaultMusicVolume }
    public func setMusicVolume(_ v: Double) {
        let db = Self.musicGainDb(forVolume: v)
        patchAllMusic(["gain_db": .number(db)])
        mutedMusicGains = [:]
    }
    public var isMusicMuted: Bool { !music.isEmpty && music.allSatisfy { $0.gainDb <= -95 } }
    /// Mute keeps each track's volume to come back to (for this session); unmuting without it restores the default 5 %.
    public func setMusicMuted(_ on: Bool) {
        if on {
            mutedMusicGains = Dictionary(uniqueKeysWithValues: music.map { ($0.id, $0.gainDb) })
            patchAllMusic(["gain_db": .number(-96)])
        } else {
            let saved = mutedMusicGains; mutedMusicGains = [:]
            patchEachMusic { saved[$0.id] ?? Self.defaultMusicGainDb }
        }
    }
    public func removeAllMusic() { set("audio.music", .array([])); stopMusicPreview() }

    private func patchAllMusic(_ patch: [String: JSONValue]) {
        let rows = rawMusicRowsForPatch().map { row -> JSONValue in
            guard case .object(var o) = row else { return row }
            for (k, v) in patch { o[k] = v }
            return .object(o)
        }
        set("audio.music", .array(rows))
    }
    private func patchEachMusic(_ gain: (MusicItem) -> Double) {
        let gains = Dictionary(uniqueKeysWithValues: music.map { ($0.id, gain($0)) })
        let rows = rawMusicRowsForPatch().map { row -> JSONValue in
            guard case .object(var o) = row, case .string(let id)? = o["id"], let g = gains[id] else { return row }
            o["gain_db"] = .number(g); return .object(o)
        }
        set("audio.music", .array(rows))
    }
    private func rawMusicRowsForPatch() -> [JSONValue] { if case .array(let r)? = value("audio.music") { r } else { [] } }

    // The user's own audio folder (the reference's "audio library folder"): files in it are listed and added from the panel.
    public static var defaultMusicFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Yapcam/Audio Library", isDirectory: true) }
    public static let musicFileExtensions: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac", "mp4", "mov", "m4v"]
    public func userMusicFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: userMusicFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.filter { Self.musicFileExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    /// Creates the folder if needed and shows it in Finder.
    public func revealUserMusicFolder() {
        try? FileManager.default.createDirectory(at: userMusicFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(userMusicFolder)
    }
    /// Files dropped on the audio section: the first audio file is added at the playhead (like "Add file…").
    @discardableResult public func dropMusic(urls: [URL]) -> Bool {
        guard let first = urls.first(where: { $0.isFileURL && Self.musicFileExtensions.contains($0.pathExtension.lowercased()) }) else { return false }
        importMusicFile(first); return true
    }

    // Preview: the track is generated into a temporary WAV and played locally; one at a time.
    public func toggleMusicPreview(trackID: String) {
        if previewingMusicID == trackID { stopMusicPreview(); return }
        stopMusicPreview()
        previewingMusicID = trackID
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yapcam-music-preview-\(UUID().uuidString).wav")
        musicPreviewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await project.writeLibraryTrack(trackID: trackID, to: url)
                guard previewingMusicID == trackID, !Task.isCancelled else { try? FileManager.default.removeItem(at: url); return }
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = 0.6; player.numberOfLoops = 0; player.play()
                musicPlayer = player; musicPreviewFile = url
            } catch {
                try? FileManager.default.removeItem(at: url)
                if previewingMusicID == trackID { previewingMusicID = nil; lastError = "Couldn't preview the track: \(error.localizedDescription)" }
            }
        }
    }
    public func stopMusicPreview() {
        musicPreviewTask?.cancel(); musicPreviewTask = nil
        musicPlayer?.stop(); musicPlayer = nil
        if let f = musicPreviewFile { try? FileManager.default.removeItem(at: f); musicPreviewFile = nil }
        previewingMusicID = nil
    }
}
