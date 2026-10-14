import Foundation

extension Project {
    /// Repair selected missing/changed files while preserving all edit state and
    /// IDs. Replacements must match the recorded duration/geometry; this operation
    /// does not rescale the captured event coordinates or change segment timing.
    public static func relink(package: URL, replacements: [String: URL]) throws -> Project {
        guard package.isFileURL, !replacements.isEmpty else { throw CoreError.status(1, "Relink requires a local package and replacement files") }
        let primary = package.appendingPathComponent("project.json")
        let previous = package.appendingPathComponent("project.json.prev")
        let primaryBytes = try? Data(contentsOf: primary)
        let originalPreviousBytes = try? Data(contentsOf: previous)
        let journalURL = package.appendingPathComponent("autosave/project.json")
        let journalBytes = try? Data(contentsOf: journalURL)
        var originalBytes: Data
        if let bytes = primaryBytes, (try? JSONSerialization.jsonObject(with: bytes)) != nil { originalBytes = bytes }
        else { originalBytes = try Data(contentsOf: previous) }
        if let journalBytes,
           let saved = try? JSONSerialization.jsonObject(with: originalBytes) as? [String: Any],
           let journal = try? JSONSerialization.jsonObject(with: journalBytes) as? [String: Any],
           saved["id"] as? String == journal["id"] as? String {
            originalBytes = journalBytes
        }
        let original = try JSONDecoder().decode(JSONValue.self, from: originalBytes)
        guard case .object(let fields) = original, case .array(let media)? = fields["media"] else { throw CoreError.status(2, "Invalid project media manifest") }
        if let version = fields["schema_version"]?.integerValue, version > 1 { throw CoreError.unsupportedVersion(Int(version)) }
        let references = Set(media.compactMap { item -> String? in
            guard case .object(let fields) = item, case .string(let path)? = fields["path"] else { return nil }; return path
        })
        let packagePath = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var destinations: [String: URL] = [:]
        for (path, source) in replacements {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let destination = package.appendingPathComponent(path)
            guard references.contains(path), !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  destination.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(packagePath),
                  source.isFileURL, try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CoreError.status(1, "Unsafe or unreferenced relink path: \(path)") }
            destinations[path] = destination
        }
        let staging = package.appendingPathComponent(".relink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        var keepStaging = false
        defer { if !keepStaging { try? FileManager.default.removeItem(at: staging) } }
        var backups: [URL: URL] = [:]
        var installed: [URL] = []
        do {
            for (index, path) in replacements.keys.sorted().enumerated() {
                let destination = destinations[path]!
                let staged = staging.appendingPathComponent("new-\(index)")
                try FileManager.default.copyItem(at: replacements[path]!, to: staged)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let backup = staging.appendingPathComponent("old-\(index)")
                    try FileManager.default.moveItem(at: destination, to: backup); backups[destination] = backup
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: staged, to: destination); installed.append(destination)
            }
            let recovered = try Project.create(package: package)
            try recovered.apply(.relinkProject(project: original, paths: replacements.keys.sorted()))
            try recovered.save()
            return try Project.open(package: package)
        } catch {
            var rollbackFailed = false
            for destination in installed { do { try FileManager.default.removeItem(at: destination) } catch { rollbackFailed = true } }
            for (destination, backup) in backups { do { try FileManager.default.moveItem(at: backup, to: destination) } catch { rollbackFailed = true } }
            for (url, bytes) in [(primary, primaryBytes), (previous, originalPreviousBytes), (journalURL, journalBytes)] {
                do {
                    if let bytes { try bytes.write(to: url, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed {
                keepStaging = true
                throw CoreError.status(4, "Relink failed; recovery files retained in \(staging.lastPathComponent): \(error.localizedDescription)")
            }
            throw error
        }
    }
}
