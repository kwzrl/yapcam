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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // ImageIO detects encoding from bytes; this package-local filename is stable
        // even when the imported file has an unusual or absent extension.
        let relative = "assets/background-\(UUID().uuidString).image"
        try data.write(to: packageURL.appendingPathComponent(relative), options: .atomic)
        return relative
    }
    public func exportPreset(to url: URL) throws {
        let snapshot = try snapshot()
        var settings = try snapshot.query("{\"q\":\"preset\"}", as: [String: JSONValue].self)
        // The portable query omits recording-local media indices. Read the
        // original reference only to package the image bytes alongside the look.
        struct BackgroundReference: Decodable {
            struct Canvas: Decodable {
                struct Background: Decodable { var kind: String; var asset: Int }
                var background: Background
            }
            var canvas: Canvas
        }
        let background = try JSONDecoder().decode(BackgroundReference.self, from: snapshot.toJSON()).canvas.background
        if background.kind == "image" {
            let index = background.asset
            struct Media: Decodable { var path: String }
            let media = try snapshot.query("{\"q\":\"media\"}", as: [Media].self)
            guard index >= 0 && index < media.count else { throw CoreError.status(1, "Background asset is unavailable") }
            let data = try Data(contentsOf: packageURL.appendingPathComponent(media[Int(index)].path))
            settings["_background_image"] = .string(data.base64EncodedString())
        }
        let camera = try snapshot.cameraStyle()
        if camera.preset == "lut", let path = camera.lutPath {
            settings["_camera_lut"] = .string(try snapshot.cameraLUTData(path: path).base64EncodedString())
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
    @discardableResult public func importPreset(from url: URL) throws -> ChangeSet {
        let data = try Data(contentsOf: url)
        var preset = try JSONDecoder().decode([String: JSONValue].self, from: data)
        var staged: [String] = []
        do {
            var commands: [EditCommand] = [.applyPreset(preset.filter { $0.key != "_background_image" && $0.key != "_camera_lut" })]
            if let image = preset.removeValue(forKey: "_background_image") {
                guard case .string(let encoded) = image, let data = Data(base64Encoded: encoded) else { throw CoreError.status(2, "Invalid embedded preset image") }
                let path = try stageBackgroundImage(data: data); staged.append(path)
                commands.append(.addMedia(path: path, asBackground: true))
            }
            if let lut = preset.removeValue(forKey: "_camera_lut") {
                guard case .string(let encoded) = lut, let data = Data(base64Encoded: encoded) else { throw CoreError.status(2, "Invalid embedded camera LUT") }
                let path = try stageCameraLUT(data: data); staged.append(path)
                commands.append(contentsOf: Self.cameraLUTCommands(path: path))
            }
            return try apply(.batch(commands))
        } catch {
            for path in staged { try? FileManager.default.removeItem(at: packageURL.appendingPathComponent(path)) }
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
