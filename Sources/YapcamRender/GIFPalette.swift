import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Our bounded global palette pass: 5-bit histogram, weighted median-cut, then
/// a cached nearest-color map. No external optimizer, subprocess or frame archive.
struct GIFPaletteHistogram {
    private struct Bin {
        var r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0, count: UInt64 = 0
    }
    private var bins: [Int: Bin] = [:]
    mutating func add(_ image: CGImage) throws {
        let pixels = try GIFPalette.rgba(image)
        let stride = max(1, (image.width * image.height + 65_535) / 65_536)
        for p in Swift.stride(from: 0, to: image.width * image.height, by: stride) {
            if p % (stride * 1024) == 0 { try Task.checkCancellation() }
            let i = p * 4, r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            var bin = bins[key] ?? Bin()
            bin.r += UInt64(r); bin.g += UInt64(g); bin.b += UInt64(b); bin.count += 1
            bins[key] = bin
        }
    }
    func palette() throws -> GIFPalette {
        struct Color { let rgb: SIMD3<Double>; let count: UInt64 }
        let colors = bins.sorted { $0.key < $1.key }.map { _, b in Color(rgb: SIMD3(Double(b.r),Double(b.g),Double(b.b))/Double(b.count),count: b.count) }
        guard !colors.isEmpty else { throw RenderError.write("Cannot build a palette without image samples") }
        struct Box {
            let indices: [Int]
            let axis: Int
            let spread: Double
            init(_ indices: [Int], _ colors: [Color]) {
                self.indices = indices
                var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
                for i in indices { for c in 0..<3 { lo[c] = min(lo[c], colors[i].rgb[c]); hi[c] = max(hi[c], colors[i].rgb[c]) } }
                let ranges = hi-lo
                axis = ranges.x >= ranges.y && ranges.x >= ranges.z ? 0 : (ranges.y >= ranges.z ? 1 : 2)
                spread = ranges[axis]
            }
        }
        var boxes = [Box(Array(colors.indices), colors)]
        while boxes.count < 256 {
            try Task.checkCancellation()
            guard let index = boxes.indices.filter({ boxes[$0].indices.count > 1 }).max(by: { boxes[$0].spread < boxes[$1].spread }) else { break }
            let box = boxes.remove(at: index), axis = box.axis
            let sorted = box.indices.sorted { a,b in colors[a].rgb[axis] == colors[b].rgb[axis] ? a < b : colors[a].rgb[axis] < colors[b].rgb[axis] }
            let half = sorted.reduce(UInt64(0)) { $0+colors[$1].count }/2
            var weight: UInt64 = 0, cut = 1
            for i in 0..<sorted.count-1 {
                weight += colors[sorted[i]].count; cut = i+1
                if weight >= half { break }
            }
            boxes.append(Box(Array(sorted[..<cut]), colors)); boxes.append(Box(Array(sorted[cut...]), colors))
        }
        let palette = boxes.map { box -> SIMD3<Double> in
            var sum = SIMD3<Double>.zero, count: UInt64 = 0
            for i in box.indices { sum += colors[i].rgb*Double(colors[i].count); count += colors[i].count }
            return sum/Double(count)
        }
        return GIFPalette(colors: palette)
    }
}

final class GIFPalette {
    private let colors: [SIMD3<Double>]
    private var lookup = [Int16](repeating: -1, count: 32*32*32)
    init(colors: [SIMD3<Double>]) { precondition(!colors.isEmpty && colors.count <= 256); self.colors = colors }
    static func fast() -> GIFPalette {
        var colors: [SIMD3<Double>] = []
        for r in 0..<8 { for g in 0..<8 { for b in 0..<4 { colors.append(SIMD3(Double(r)*255/7,Double(g)*255/7,Double(b)*255/3)) } } }
        return GIFPalette(colors: colors)
    }
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width*image.height*4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress,width: image.width,height: image.height,bitsPerComponent: 8,bytesPerRow: image.width*4,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height)); return true
        }
        guard success else { throw RenderError.write("Cannot read image colors for GIF") }
        return bytes
    }
    func indexed(_ image: CGImage) throws -> CGImage {
        let rgba = try Self.rgba(image)
        var indices = [UInt8](repeating: 0, count: image.width*image.height)
        for p in indices.indices {
            if p % (image.width*32) == 0 { try Task.checkCancellation() }
            let i = p*4, r = Int(rgba[i])>>3, g = Int(rgba[i+1])>>3, b = Int(rgba[i+2])>>3
            let key = r<<10 | g<<5 | b
            if lookup[key] < 0 {
                let rgb = SIMD3(Double(r*8+4),Double(g*8+4),Double(b*8+4))
                var best = 0, error = Double.infinity
                for (j,c) in colors.enumerated() {
                    let d = rgb-c, distance = d.x*d.x+d.y*d.y+d.z*d.z
                    if distance < error { error = distance; best = j }
                }
                lookup[key] = Int16(best)
            }
            indices[p] = UInt8(lookup[key])
        }
        var table = colors.flatMap { c in (0..<3).map { UInt8(min(255,max(0,c[$0].rounded()))) } }
        while table.count < 256*3 { table.append(contentsOf: Array(table.prefix(3))) }
        guard let base = CGColorSpace(name: CGColorSpace.sRGB),
              let space = CGColorSpace(indexedBaseSpace: base,last: 255,colorTable: table),
              let provider = CGDataProvider(data: Data(indices) as CFData),
              let result = CGImage(width: image.width,height: image.height,bitsPerComponent: 8,bitsPerPixel: 8,bytesPerRow: image.width,space: space,bitmapInfo: [],provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent) else { throw RenderError.write("Cannot create indexed GIF frame") }
        return result
    }
}

final class GIFFrameDestination {
    private let destination: CGImageDestination
    private let url: URL
    private let count: Int
    static func containerProperties(disableLoop: Bool,loopCount: Int?) -> CFDictionary? {
        // Omitting the repeat extension means one playback. A count of 1 would
        // request a repeat and is not equivalent to disabling looping.
        guard !disableLoop else { return nil }
        return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount ?? 0]] as CFDictionary
    }
    init(url: URL, count: Int, disableLoop: Bool,loopCount: Int? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw RenderError.write("Cannot create GIF") }
        self.destination = destination; self.url = url; self.count = count
        if let properties=Self.containerProperties(disableLoop: disableLoop,loopCount: loopCount) {
            CGImageDestinationSetProperties(destination,properties)
        }
    }
    func add(_ image: CGImage, delay: Double) {
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
    }
    func finish() throws -> CGImageSource {
        guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == count else { throw RenderError.verification("GIF finalization or frame count verification failed") }
        return source
    }
}
