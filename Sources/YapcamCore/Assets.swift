import Foundation
import ImageIO

extension Project {
    /// The package owns the copied image; encoded image data never crosses C ABI.
    @discardableResult public func importBackgroundImage(_ image: URL) throws -> ChangeSet {
        let relative = try stageBackgroundImage(data: Data(contentsOf: image))
        do { return try apply(.addMedia(path: relative, asBackground: true)) }
        catch { try? FileManager.default.removeItem(at: packageURL.appendingPathComponent(relative)); throw error }
    }
    private func stageBackgroundImage(data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw CoreError.status(1, "Background file is not a supported image") }
        let directory = packageURL.appendingPathComponent("assets")
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw CoreError.status(1, "Asset directory escapes package") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        // ImageIO detects encoding from bytes; this package-local filename is stable
        // even when the imported file has an unusual or absent extension.
        let relative = "assets/background-\(UUID().uuidString).image"
        try data.write(to: packageURL.appendingPathComponent(relative), options: .atomic)
        return relative
    }
    public func exportPreset(to url: URL) throws {
        let snapshot = try snapshot()
        var settings = try snapshot.query("{\"q\":\"preset\"}", as: [String: JSONValue].self)
        if case .object(let canvas)? = settings["canvas"], case .object(let background)? = canvas["background"],
           case .string("image")? = background["kind"], let index = background["asset"]?.integerValue {
            struct Media: Decodable { var path: String }
            let media = try snapshot.query("{\"q\":\"media\"}", as: [Media].self)
            guard index >= 0 && index < media.count else { throw CoreError.status(1, "Background asset is unavailable") }
            let data = try Data(contentsOf: packageURL.appendingPathComponent(media[Int(index)].path))
            settings["_background_image"] = .string(data.base64EncodedString())
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
    @discardableResult public func importPreset(from url: URL) throws -> ChangeSet {
        let data = try Data(contentsOf: url)
        var preset = try JSONDecoder().decode([String: JSONValue].self, from: data)
        var staged: String?
        if let image = preset.removeValue(forKey: "_background_image") {
            guard case .string(let encoded) = image, let data = Data(base64Encoded: encoded) else { throw CoreError.status(2, "Invalid embedded preset image") }
            staged = try stageBackgroundImage(data: data)
        }
        do {
            var commands: [EditCommand] = [.applyPreset(preset)]
            if let staged { commands.append(.addMedia(path: staged, asBackground: true)) }
            return try apply(.batch(commands))
        } catch {
            if let staged { try? FileManager.default.removeItem(at: packageURL.appendingPathComponent(staged)) }
            throw error
        }
    }
}

extension Project {
    /// Cold-path asset lookup for compositor setup; cache decoded images/textures.
    public func mediaURL(atIndex index: UInt32) throws -> URL {
        struct Media: Decodable { var path: String }
        let media = try query("{\"q\":\"media\"}", as: [Media].self)
        guard Int(index) < media.count else { throw CoreError.status(1, "Asset index is unavailable") }
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let url = packageURL.appendingPathComponent(media[Int(index)].path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root) else { throw CoreError.status(1, "Asset path escapes package") }
        guard FileManager.default.fileExists(atPath: url.path) else { throw CoreError.missingMedia([media[Int(index)].path]) }
        return url
    }
}
