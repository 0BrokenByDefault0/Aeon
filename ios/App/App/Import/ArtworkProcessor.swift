import Foundation
import ImageIO

final class ArtworkProcessor {
    private let store: ArtworkStore
    private let maximumInputBytes: Int
    private let maximumPixelSize: Int
    private let gate = NSLock()

    init(
        store: ArtworkStore,
        maximumInputBytes: Int = 32 * 1_024 * 1_024,
        maximumPixelSize: Int = 1_600
    ) {
        self.store = store
        self.maximumInputBytes = maximumInputBytes
        self.maximumPixelSize = maximumPixelSize
    }

    func process(_ data: Data?, key: String) -> String? {
        guard let data, !data.isEmpty, data.count <= maximumInputBytes else { return nil }
        gate.lock()
        defer { gate.unlock() }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return try? store.storeDecoded(image, key: key)
    }

    func remove(key: String) throws {
        try store.remove(key: key)
    }
}
