import Foundation
import CryptoKit

/// Bounded 3D .cube reader. Red varies fastest, then green, then blue; values
/// remain encoded color values. DOMAIN_MIN/MAX are respected by CPU and GPU.
public struct CubeLUT: Sendable {
    public let dimension: Int
    public let domainMinimum: SIMD3<Float>
    public let domainMaximum: SIMD3<Float>
    public let rgba: [Float]
    private static let byteLimit = 16*1024*1024
    private init(dimension: Int, minimum: SIMD3<Float>, maximum: SIMD3<Float>, rgba: [Float]) {
        self.dimension = dimension; self.domainMinimum = minimum; self.domainMaximum = maximum; self.rgba = rgba
    }
    public init(data: Data) throws {
        guard data.count <= Self.byteLimit, let text = String(data: data,encoding: .utf8) else { throw RenderError.invalidSettings("LUT must be UTF-8 and at most 16MiB") }
        var size: Int?, minimum = SIMD3<Float>.zero, maximum = SIMD3<Float>(repeating: 1), samples: [Float] = []
        var seen = Set<String>()
        for (index,line) in text.split(separator: "\n",omittingEmptySubsequences: false).enumerated() {
            if index%1024 == 0 { try Task.checkCancellation() }
            let words = line.split(separator: "#",maxSplits: 1,omittingEmptySubsequences: false)[0].split(whereSeparator: \.isWhitespace)
            guard let first = words.first else { continue }
            let key = String(first)
            if key == "TITLE" { continue }
            if key == "LUT_1D_SIZE" { throw RenderError.invalidSettings("This importer supports 3D LUTs, not 1D tables") }
            if key == "LUT_3D_SIZE" {
                guard seen.insert(key).inserted, words.count == 2, let n = Int(words[1]), (2...65).contains(n) else { throw RenderError.invalidSettings("3D LUT size must be 2…65") }
                size = n; samples.reserveCapacity(n*n*n*4); continue
            }
            func vector() throws -> SIMD3<Float> {
                guard words.count == 3, let r = Float(words[0]), let g = Float(words[1]), let b = Float(words[2]), r.isFinite, g.isFinite, b.isFinite else { throw RenderError.invalidSettings("Invalid LUT color at line \(index+1)") }
                return SIMD3(r,g,b)
            }
            if key == "DOMAIN_MIN" || key == "DOMAIN_MAX" {
                guard seen.insert(key).inserted, words.count == 4 else { throw RenderError.invalidSettings("Invalid or duplicate LUT domain") }
                let values = words.dropFirst().compactMap { Float($0) }
                guard values.count == 3, values.allSatisfy(\.isFinite) else { throw RenderError.invalidSettings("Invalid LUT domain") }
                if key == "DOMAIN_MIN" { minimum = SIMD3(values[0],values[1],values[2]) }
                else { maximum = SIMD3(values[0],values[1],values[2]) }
                continue
            }
            guard let n = size, samples.count < n*n*n*4 else { throw RenderError.invalidSettings("Missing LUT size or too many color rows") }
            let v = try vector(); samples.append(contentsOf: [v.x,v.y,v.z,1])
        }
        guard let n = size, samples.count == n*n*n*4,
              (0..<3).allSatisfy({ let span = maximum[$0]-minimum[$0]; return span.isFinite && span > 0 }) else { throw RenderError.invalidSettings("Incomplete LUT or invalid input domain") }
        self.init(dimension: n,minimum: minimum,maximum: maximum,rgba: samples)
    }
    public init(contentsOf url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey,.isRegularFileKey])
        guard url.isFileURL, values.isRegularFile == true, (values.fileSize ?? .max) <= Self.byteLimit else { throw RenderError.invalidSettings("LUT must be a local regular file of at most 16MiB") }
        try self.init(data: Data(contentsOf: url,options: .mappedIfSafe))
    }
    public static func identity(dimension: Int = 2) throws -> CubeLUT {
        guard (2...65).contains(dimension) else { throw RenderError.invalidSettings("3D LUT size must be 2…65") }
        var data: [Float] = []
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension { data.append(contentsOf: [Float(r)/Float(dimension-1),Float(g)/Float(dimension-1),Float(b)/Float(dimension-1),1]) } } }
        return CubeLUT(dimension: dimension,minimum: .zero,maximum: SIMD3(repeating: 1),rgba: data)
    }
    public func sample(_ color: SIMD3<Float>) throws -> SIMD3<Float> {
        guard (0..<3).allSatisfy({ color[$0].isFinite }) else { throw RenderError.invalidSettings("Invalid LUT input color") }
        var coordinate = (color-domainMinimum)/(domainMaximum-domainMinimum)*Float(dimension-1)
        for i in 0..<3 { coordinate[i] = min(Float(dimension-1),max(0,coordinate[i])) }
        let lo = SIMD3<Int>(Int(floor(coordinate.x)),Int(floor(coordinate.y)),Int(floor(coordinate.z)))
        let hi = SIMD3<Int>(min(dimension-1,lo.x+1),min(dimension-1,lo.y+1),min(dimension-1,lo.z+1))
        let t = coordinate-SIMD3(Float(lo.x),Float(lo.y),Float(lo.z))
        func value(_ r: Int,_ g: Int,_ b: Int) -> SIMD3<Float> { let i = ((b*dimension+g)*dimension+r)*4; return SIMD3(rgba[i],rgba[i+1],rgba[i+2]) }
        func mix(_ a: SIMD3<Float>,_ b: SIMD3<Float>,_ t: Float) -> SIMD3<Float> { a+(b-a)*t }
        let a = mix(mix(value(lo.x,lo.y,lo.z),value(hi.x,lo.y,lo.z),t.x),mix(value(lo.x,hi.y,lo.z),value(hi.x,hi.y,lo.z),t.x),t.y)
        let b = mix(mix(value(lo.x,lo.y,hi.z),value(hi.x,lo.y,hi.z),t.x),mix(value(lo.x,hi.y,hi.z),value(hi.x,hi.y,hi.z),t.x),t.y)
        return mix(a,b,t.z)
    }
    /// Validate before importing; copy immutable content into the package and return
    /// a package-relative path for Core persistence. Never edit the selected source.
    public static func importFile(_ source: URL, into package: URL) throws -> String {
        guard package.isFileURL else { throw RenderError.invalidSettings("LUT destination must be a local project") }
        let parsed = try CubeLUT(contentsOf: source)
        _ = parsed
        let bytes = try Data(contentsOf: source)
        _ = try CubeLUT(data: bytes) // Protect against replacement between metadata/read.
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined()
        let relative = "assets/luts/\(digest).cube"
        let root = package.standardizedFileURL.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("assets/luts",isDirectory: true)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(root.path+"/") else { throw RenderError.invalidSettings("LUT assets escape the project") }
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let target = root.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try Data(contentsOf: target) == bytes else { throw RenderError.write("Existing LUT fingerprint has different content") }
            return relative
        }
        let staged = directory.appendingPathComponent(".lut-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try bytes.write(to: staged,options: .withoutOverwriting)
        do { try FileManager.default.moveItem(at: staged,to: target) }
        catch {
            guard FileManager.default.fileExists(atPath: target.path), try Data(contentsOf: target) == bytes else { throw error }
        }
        return relative
    }
}
