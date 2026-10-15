import Foundation

public struct CameraStyle: Decodable, Sendable, Equatable {
    public var preset: String
    public var intensity: Double
    public var warmth: Double
    public var backgroundPop: Double
    public var contrast: Double
    public var colorIntensity: Double
    public var sharpen: Double
    public var grain: Double
    public var backgroundBlur: Double
    public var crop: [Double]
    public var lutPath: String?
}
public struct CameraStyleRecipe: Decodable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var warmth: Double
    public var backgroundPop: Double
    public var contrast: Double
    public var colorIntensity: Double
}
/// Parsed 3D CUBE values in file order (red changes fastest).
public struct CubeLUT: Sendable, Equatable {
    public var dimension: Int
    public var domainMin: [Float]
    public var domainMax: [Float]
    public var values: [Float]
    public init(data: Data) throws {
        func invalid() -> CoreError { .status(2, "Invalid 3D CUBE LUT") }
        guard data.count <= 32 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw invalid() }
        var dimension: Int?
        var minimum: [Float]?, maximum: [Float]?
        var values: [Float] = []
        func rgb(_ fields: ArraySlice<Substring>) throws -> [Float] {
            let row = fields.compactMap { Float($0) }
            guard row.count == 3, row.allSatisfy(\.isFinite) else { throw invalid() }
            return row
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let fields = content.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first else { continue }
            switch first {
            case "TITLE": continue
            case "LUT_3D_SIZE":
                guard dimension == nil, values.isEmpty, fields.count == 2,
                      let size = Int(fields[1]), (2...64).contains(size) else { throw invalid() }
                dimension = size; values.reserveCapacity(size * size * size * 3)
            case "DOMAIN_MIN":
                guard minimum == nil, fields.count == 4 else { throw invalid() }
                minimum = try rgb(fields.dropFirst())
            case "DOMAIN_MAX":
                guard maximum == nil, fields.count == 4 else { throw invalid() }
                maximum = try rgb(fields.dropFirst())
            default:
                guard let dimension, fields.count == 3,
                      values.count < dimension * dimension * dimension * 3 else { throw invalid() }
                values.append(contentsOf: try rgb(fields[...]))
            }
        }
        guard let dimension, values.count == dimension * dimension * dimension * 3 else { throw invalid() }
        let lo = minimum ?? [0,0,0], hi = maximum ?? [1,1,1]
        guard zip(lo, hi).allSatisfy({ $0 < $1 }) else { throw invalid() }
        self.dimension = dimension; domainMin = lo; domainMax = hi; self.values = values
    }
}
extension Project {
    public func cameraStyle() throws -> CameraStyle { try query("{\"q\":\"camera_style\"}", as: CameraStyle.self) }
    public func cameraStyleLibrary() throws -> [CameraStyleRecipe] { try query("{\"q\":\"camera_style_library\"}", as: [CameraStyleRecipe].self) }
    public func cameraLUT() throws -> CubeLUT? {
        let style = try cameraStyle()
        guard style.preset == "lut", let path = style.lutPath else { return nil }
        return try CubeLUT(data: cameraLUTData(path: path))
    }
    func cameraLUTData(path: String) throws -> Data {
        struct Media: Decodable { var path: String }
        let media = try query("{\"q\":\"media\"}", as: [Media].self)
        guard let index = media.firstIndex(where: { $0.path == path }) else { throw CoreError.status(1, "Camera LUT is unavailable") }
        return try Self.readCameraLUT(at: mediaURL(atIndex: UInt32(index)))
    }
    static func readCameraLUT(at url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
        _ = try CubeLUT(data: data)
        return data
    }
    func stageCameraLUT(data: Data) throws -> String {
        _ = try CubeLUT(data: data)
        let assets = packageURL.appendingPathComponent("assets")
        let root = packageURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard assets.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw CoreError.status(1, "Asset directory escapes package") }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let relative = "assets/camera-\(UUID().uuidString).cube"
        try data.write(to: packageURL.appendingPathComponent(relative), options: .atomic)
        return relative
    }
    static func cameraLUTCommands(path: String) -> [EditCommand] {
        [.addMedia(path: path, asBackground: false), .set(path: "camera.style.lut_path", value: .string(path)), .set(path: "camera.style.preset", value: .string("lut"))]
    }
    @discardableResult public func importCameraLUT(from url: URL) throws -> ChangeSet {
        let relative = try stageCameraLUT(data: Self.readCameraLUT(at: url))
        do { return try apply(.batch(Self.cameraLUTCommands(path: relative))) }
        catch { try? FileManager.default.removeItem(at: packageURL.appendingPathComponent(relative)); throw error }
    }
}
