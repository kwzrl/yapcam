import XCTest
import CoreGraphics
@testable import YapcamRender

final class BackgroundThumbnailTests: XCTestCase {
    func testCatalogIsStableFilterableAndEncodesPickerMetadata() throws {
        let entries = BackgroundLibrary.catalog()
        XCTAssertEqual(entries.count, 12)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        for entry in entries {
            let preset = try XCTUnwrap(BackgroundLibrary.preset(id: entry.id))
            XCTAssertFalse(entry.name.isEmpty)
            XCTAssertEqual(entry.name, preset.title)
            XCTAssertEqual(entry.category, preset.category)
        }
        for category in BackgroundPreset.Category.allCases {
            XCTAssertEqual(BackgroundLibrary.catalog(category: category), entries.filter { $0.category == category })
            XCTAssertFalse(BackgroundLibrary.catalog(category: category).isEmpty)
        }
        let data = try JSONEncoder().encode(entries)
        XCTAssertEqual(try JSONDecoder().decode([BackgroundLibrary.Entry].self, from: data), entries)
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(objects.first).keys), Set(["id", "category", "name"]))
    }

    func testDefaultThumbnailsMatchOriginalArtworkAndRetinaHasItsOwnCacheKey() async throws {
        var signatures = Set<Data>()
        for entry in BackgroundLibrary.catalog() {
            let image = try await BackgroundLibrary.thumbnail(id: entry.id)
            let repeated = try await BackgroundLibrary.thumbnail(id: entry.id)
            XCTAssertTrue(image === repeated, "Warm grid cells reuse the original CGImage")
            XCTAssertEqual(image.width, 160)
            XCTAssertEqual(image.height, 100)
            XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
            let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            let direct = try BackgroundLibrary.image(for: XCTUnwrap(BackgroundLibrary.preset(id: entry.id)), width: 160, height: 100)
            XCTAssertEqual(pixels, direct.dataProvider?.data as Data?)
            XCTAssertTrue(signatures.insert(pixels).inserted)
        }
        let id = "blue-hills"
        let standard = try await BackgroundLibrary.thumbnail(id: id)
        let retina = try await BackgroundLibrary.thumbnail(id: id, width: 320, height: 200)
        XCTAssertEqual(retina.width, 320)
        XCTAssertEqual(retina.height, 200)
        XCTAssertFalse(standard === retina)
        let repeated = try await BackgroundLibrary.thumbnail(id: id, width: 320, height: 200)
        XCTAssertTrue(retina === repeated)
    }

    func testConcurrentGridRequestsForTheSameKeyShareOneImage() async throws {
        let images = try await withThrowingTaskGroup(of: CGImage.self, returning: [CGImage].self) { group in
            for _ in 0..<32 {
                group.addTask { try await BackgroundLibrary.thumbnail(id: "cool-rings", width: 161, height: 101) }
            }
            var results: [CGImage] = []
            for try await image in group { results.append(image) }
            return results
        }
        let first = try XCTUnwrap(images.first)
        XCTAssertEqual(images.count, 32)
        XCTAssertTrue(images.allSatisfy { $0 === first })
    }

    func testByteAndCountLimitsEvictLeastRecentlyUsedThumbnails() async throws {
        // Independently exercise the byte budget and entry count, with capacity
        // for exactly two 64KB thumbnails. Holding a cell's CGImage stays valid.
        for cache in [BackgroundThumbnailCache(byteLimit: 128_000), BackgroundThumbnailCache(countLimit: 2)] {
            let presets = Array(BackgroundLibrary.presets.prefix(3))
            let a = try await cache.image(for: presets[0], width: 160, height: 100)
            let b = try await cache.image(for: presets[1], width: 160, height: 100)
            _ = try await cache.image(for: presets[0], width: 160, height: 100)
            _ = try await cache.image(for: presets[2], width: 160, height: 100)
            let retained = try await cache.image(for: presets[0], width: 160, height: 100)
            let regenerated = try await cache.image(for: presets[1], width: 160, height: 100)
            XCTAssertTrue(a === retained)
            XCTAssertFalse(b === regenerated)
            XCTAssertEqual(b.dataProvider?.data as Data?, regenerated.dataProvider?.data as Data?)
        }
    }

    func testInvalidRequestsFailAndCancelledCellsDoNotPoisonOtherRequests() async throws {
        for (width, height) in [(0,100),(15,100),(513,100),(Int.max,100),(160,-1),(160,15),(160,513)] {
            do {
                _ = try await BackgroundLibrary.thumbnail(id: "blue-hills", width: width, height: height)
                XCTFail("Invalid thumbnail dimensions accepted: \(width)x\(height)")
            } catch RenderError.invalidSettings { } catch { XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await BackgroundLibrary.thumbnail(id: "not-in-our-library")
            XCTFail("Unknown ids must be explicit errors")
        } catch RenderError.invalidSettings { } catch { XCTFail("Unexpected error: \(error)") }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BackgroundLibrary.thumbnail(id: "blue-hills")
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled cell request returned an image") }
        catch is CancellationError { }
        let valid = try await BackgroundLibrary.thumbnail(id: "blue-hills")
        XCTAssertEqual(valid.width, 160)
    }

    @MainActor func testColdAndWarmWholeGridTimingsFromMainActor() async throws {
        let cache = BackgroundThumbnailCache()
        let start = ProcessInfo.processInfo.systemUptime
        var images: [CGImage] = []
        for preset in BackgroundLibrary.presets {
            images.append(try await cache.image(for: preset, width: 160, height: 100))
        }
        let generated = ProcessInfo.processInfo.systemUptime
        for (index, preset) in BackgroundLibrary.presets.enumerated() {
            let image = try await cache.image(for: preset, width: 160, height: 100)
            XCTAssertTrue(image === images[index])
        }
        let warmed = ProcessInfo.processInfo.systemUptime
        let bytes = images.reduce(0) { $0 + $1.bytesPerRow * $1.height }
        print("RENDER_WALLPAPER_GRID entries=\(images.count) size=160x100 cold_ms=\((generated-start)*1000) warm_ms=\((warmed-generated)*1000) pixel_bytes=\(bytes)")
    }
}
