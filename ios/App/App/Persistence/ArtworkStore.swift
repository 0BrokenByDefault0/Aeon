import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ArtworkStoreError: Error, Equatable {
    case invalidKey
    case unsupportedImage
    case imageTooLarge
    case decodeFailed
    case encodeFailed
    case unsafeStoredKey
}

final class ArtworkStore {
    let rootURL: URL

    private let fileManager: FileManager
    private let maximumInputBytes: Int
    private let maximumPixelSize: Int

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        maximumInputBytes: Int = 64 * 1_024 * 1_024,
        maximumPixelSize: Int = 1_600
    ) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.maximumInputBytes = maximumInputBytes
        self.maximumPixelSize = maximumPixelSize
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try removeAbandonedPartials()
    }

    @discardableResult
    func store(_ data: Data, key: String) throws -> String {
        guard Self.isSafeBaseKey(key) else { throw ArtworkStoreError.invalidKey }
        guard data.count <= maximumInputBytes else { throw ArtworkStoreError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?,
              Self.isSupported(typeIdentifier: sourceType) else {
            throw ArtworkStoreError.unsupportedImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ArtworkStoreError.decodeFailed
        }

        let useHEIC = Self.isHEIF(typeIdentifier: sourceType)
        let encoded = NSMutableData()
        let destinationType = useHEIC ? UTType.heic.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(encoded, destinationType as CFString, 1, nil) else {
            throw ArtworkStoreError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ArtworkStoreError.encodeFailed }

        let storedKey = key + (useHEIC ? ".heic" : ".jpg")
        let finalURL = rootURL.appendingPathComponent(storedKey, isDirectory: false)
        let partialURL = rootURL.appendingPathComponent(".\(key)-\(UUID().uuidString).partial", isDirectory: false)
        do {
            try (encoded as Data).write(to: partialURL, options: [])
            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.synchronize()
            try handle.close()
            guard let verificationSource = CGImageSourceCreateWithURL(partialURL as CFURL, nil),
                  CGImageSourceCreateImageAtIndex(verificationSource, 0, nil) != nil else {
                throw ArtworkStoreError.decodeFailed
            }
            if fileManager.fileExists(atPath: finalURL.path) {
                _ = try fileManager.replaceItemAt(finalURL, withItemAt: partialURL)
            } else {
                try fileManager.moveItem(at: partialURL, to: finalURL)
            }
            return storedKey
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }
    }

    func url(forKey key: String) throws -> URL {
        guard Self.isSafeStoredKey(key) else { throw ArtworkStoreError.unsafeStoredKey }
        let candidate = rootURL.appendingPathComponent(key, isDirectory: false).standardizedFileURL
        let root = rootURL.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else { throw ArtworkStoreError.unsafeStoredKey }
        return candidate
    }

    func remove(key: String) throws {
        let fileURL = try url(forKey: key)
        if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
    }

    private func removeAbandonedPartials() throws {
        for url in try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "partial" {
            try fileManager.removeItem(at: url)
        }
    }

    private static func isSafeBaseKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 128 else { return false }
        return key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func isSafeStoredKey(_ key: String) -> Bool {
        let extensionValue = (key as NSString).pathExtension.lowercased()
        guard extensionValue == "jpg" || extensionValue == "heic" else { return false }
        return isSafeBaseKey((key as NSString).deletingPathExtension)
    }

    private static func isSupported(typeIdentifier: String) -> Bool {
        typeIdentifier == UTType.jpeg.identifier || isHEIF(typeIdentifier: typeIdentifier)
    }

    private static func isHEIF(typeIdentifier: String) -> Bool {
        typeIdentifier == UTType.heic.identifier || typeIdentifier == "public.heif"
    }
}
