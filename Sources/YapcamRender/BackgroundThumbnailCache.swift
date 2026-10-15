import CoreGraphics

/// A separate actor serializes bounded CPU generation, so duplicate queued requests
/// hit the cache without spawning a worker for every SwiftUI cell. There is no await
/// during generation: a key is rendered once even when many cells request it together.
actor BackgroundThumbnailCache {
    private struct Key: Hashable {
        let id: String
        let width: Int
        let height: Int
    }
    private var images: [Key: CGImage] = [:]
    private var recency: [Key] = []
    private var bytes = 0
    private let byteLimit: Int
    private let countLimit: Int

    init(byteLimit: Int = 8 * 1024 * 1024, countLimit: Int = 48) {
        precondition(byteLimit > 0 && countLimit > 0)
        self.byteLimit = byteLimit
        self.countLimit = countLimit
    }

    func image(for preset: BackgroundPreset, width: Int, height: Int) throws -> CGImage {
        try Task.checkCancellation()
        let key = Key(id: preset.id, width: width, height: height)
        if let image = images[key] {
            recency.removeAll { $0 == key }
            recency.append(key)
            return image
        }
        let image = try BackgroundLibrary.image(for: preset, width: width, height: height)
        try Task.checkCancellation()
        let cost = image.bytesPerRow * image.height
        guard cost <= byteLimit else { return image }
        images[key] = image
        recency.append(key)
        bytes += cost
        while bytes > byteLimit || images.count > countLimit {
            let oldest = recency.removeFirst()
            if let removed = images.removeValue(forKey: oldest) {
                bytes -= removed.bytesPerRow * removed.height
            }
        }
        return image
    }
}
