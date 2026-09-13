import Foundation

protocol MediaResolving {
    func resolve(_ reference: MediaReference) throws -> URL
    func release(_ url: URL)
}

extension MediaResolving {
    func release(_ url: URL) {}
}

enum MediaStoreError: Error, Equatable {
    case invalidStableID
    case invalidFileExtension
    case unsafeRelativePath
    case verificationFailed
    case migrationRequired(trackID: String)
    case unavailable(trackID: String)
    case invalidBookmark
    case staleBookmark
    case securityScopedAccessDenied
}

final class MediaStore: MediaResolving {
    private final class ImportGate {
        let lock = NSLock()
        var references = 0
    }

    private static let gatesLock = NSLock()
    private static var gates: [String: ImportGate] = [:]
    let mediaRoot: URL
    let incomingRoot: URL
    let documentsRoot: URL
    let documentsMusicRoot: URL
    let documentsIncomingRoot: URL
    let importedDocumentsRoot: URL
    let migratedRoot: URL
    let migrationIncomingRoot: URL

    private let fileManager: FileManager
    private let bookmarkResolver: (Data) throws -> (URL, Bool)
    private let beginScopedAccess: (URL) -> Bool
    private let endScopedAccess: (URL) -> Void
    private let commitImport: (URL, URL) throws -> Void
    private let accessLock = NSLock()
    private var activeScopedURLs: [URL: Int] = [:]

    convenience init(fileManager: FileManager = .default) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try self.init(baseURL: applicationSupport, documentsRoot: documents, fileManager: fileManager)
    }

    init(
        baseURL: URL,
        documentsRoot: URL? = nil,
        fileManager: FileManager = .default,
        bookmarkResolver: ((Data) throws -> (URL, Bool))? = nil,
        beginScopedAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        endScopedAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        commitImport: ((URL, URL) throws -> Void)? = nil,
        now: @escaping () -> Date = Date.init,
        stalePartialInterval: TimeInterval = 24 * 60 * 60
    ) throws {
        self.fileManager = fileManager
        self.bookmarkResolver = bookmarkResolver ?? Self.resolveBookmark
        self.beginScopedAccess = beginScopedAccess
        self.endScopedAccess = endScopedAccess
        self.commitImport = commitImport ?? { partial, destination in
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: partial, backupItemName: nil, options: [])
            } else {
                try fileManager.moveItem(at: partial, to: destination)
            }
        }
        let aeonRoot = baseURL.appendingPathComponent("Aeon", isDirectory: true)
        mediaRoot = aeonRoot.appendingPathComponent("Media", isDirectory: true)
        incomingRoot = aeonRoot.appendingPathComponent(".incoming", isDirectory: true)
        self.documentsRoot = documentsRoot ?? baseURL.appendingPathComponent("Documents", isDirectory: true)
        documentsMusicRoot = self.documentsRoot.appendingPathComponent("Music", isDirectory: true)
        documentsIncomingRoot = documentsMusicRoot.appendingPathComponent(".incoming", isDirectory: true)
        importedDocumentsRoot = documentsMusicRoot.appendingPathComponent("_Imported", isDirectory: true)
        migratedRoot = documentsMusicRoot.appendingPathComponent("_Migrated", isDirectory: true)
        migrationIncomingRoot = migratedRoot.appendingPathComponent(".incoming", isDirectory: true)
        try fileManager.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: incomingRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documentsIncomingRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: importedDocumentsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: migrationIncomingRoot, withIntermediateDirectories: true)
        for item in try fileManager.contentsOfDirectory(
            at: incomingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) where item.lastPathComponent.contains(".partial") {
            let stableID = item.deletingPathExtension().lastPathComponent
            guard Self.isSafeStableID(stableID) else { continue }
            let gateKey = incomingRoot.standardizedFileURL.resolvingSymlinksInPath().path + "\u{0}" + stableID
            let gate = Self.acquireGate(key: gateKey)
            defer { Self.releaseGate(gate, key: gateKey) }
            if fileManager.fileExists(atPath: item.path) {
                let values = try? item.resourceValues(forKeys: [.contentModificationDateKey])
                if let modified = values?.contentModificationDate,
                   now().timeIntervalSince(modified) >= stalePartialInterval {
                    try? fileManager.removeItem(at: item)
                }
            }
        }
        try removeStalePartials(at: documentsIncomingRoot, now: now, stalePartialInterval: stalePartialInterval)
    }

    func mediaURL(stableID: String, fileExtension: String? = nil) -> URL {
        let name = fileExtension.map { "\(stableID).\($0)" } ?? stableID
        return mediaRoot.appendingPathComponent(name, isDirectory: false)
    }

    @discardableResult
    func importFile(
        sourceURL: URL,
        stableID: String,
        verifier: (URL) throws -> Bool
    ) throws -> URL {
        guard Self.isSafeStableID(stableID) else { throw MediaStoreError.invalidStableID }
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.isSafeExtension(ext) else { throw MediaStoreError.invalidFileExtension }

        let normalizedSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let normalizedIncoming = incomingRoot.standardizedFileURL.resolvingSymlinksInPath()
        let incomingPrefix = normalizedIncoming.path.hasSuffix("/") ? normalizedIncoming.path : normalizedIncoming.path + "/"
        guard !normalizedSource.path.hasPrefix(incomingPrefix) else { throw MediaStoreError.unsafeRelativePath }

        let gateKey = incomingRoot.standardizedFileURL.resolvingSymlinksInPath().path + "\u{0}" + stableID
        let importGate = Self.acquireGate(key: gateKey)
        defer { Self.releaseGate(importGate, key: gateKey) }

        let partial = incomingRoot.appendingPathComponent("\(stableID).partial", isDirectory: false)
        let destination = mediaURL(stableID: stableID, fileExtension: ext)
        try? fileManager.removeItem(at: partial)

        do {
            try fileManager.copyItem(at: sourceURL, to: partial)
            let handle = try FileHandle(forWritingTo: partial)
            handle.synchronizeFile()
            handle.closeFile()
            guard try verifier(partial) else { throw MediaStoreError.verificationFailed }

            try commitImport(partial, destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private static func acquireGate(key: String) -> ImportGate {
        gatesLock.lock()
        let gate = gates[key] ?? ImportGate()
        gate.references += 1
        gates[key] = gate
        gatesLock.unlock()
        gate.lock.lock()
        return gate
    }

    private static func releaseGate(_ gate: ImportGate, key: String) {
        gate.lock.unlock()
        gatesLock.lock()
        gate.references -= 1
        if gate.references == 0, gates[key] === gate { gates.removeValue(forKey: key) }
        gatesLock.unlock()
    }

    static var activeImportGateCountForTesting: Int {
        gatesLock.lock()
        defer { gatesLock.unlock() }
        return gates.count
    }

    func resolve(_ reference: MediaReference) throws -> URL {
        switch reference {
        case .native(let relativePath):
            return try resolve(relativePath, beneath: mediaRoot)
        case .documents(let relativePath):
            return try resolve(relativePath, beneath: documentsRoot)
        case .externalBookmark(let data):
            let (url, stale): (URL, Bool)
            do { (url, stale) = try bookmarkResolver(data) }
            catch { throw MediaStoreError.invalidBookmark }
            guard !stale else { throw MediaStoreError.staleBookmark }

            accessLock.lock()
            if let count = activeScopedURLs[url] {
                activeScopedURLs[url] = count + 1
                accessLock.unlock()
                return url
            }
            accessLock.unlock()
            guard beginScopedAccess(url) else { throw MediaStoreError.securityScopedAccessDenied }

            accessLock.lock()
            if let count = activeScopedURLs[url] {
                activeScopedURLs[url] = count + 1
                accessLock.unlock()
                endScopedAccess(url)
                return url
            }
            activeScopedURLs[url] = 1
            accessLock.unlock()
            return url
        case .legacyBlob(let trackID):
            throw MediaStoreError.migrationRequired(trackID: trackID)
        case .unavailable(let trackID):
            throw MediaStoreError.unavailable(trackID: trackID)
        }
    }

    func release(_ url: URL) {
        accessLock.lock()
        guard let count = activeScopedURLs[url] else {
            accessLock.unlock()
            return
        }
        if count > 1 {
            activeScopedURLs[url] = count - 1
            accessLock.unlock()
        } else {
            activeScopedURLs.removeValue(forKey: url)
            accessLock.unlock()
            endScopedAccess(url)
        }
    }

    func releaseAll() {
        accessLock.lock()
        let urls = Array(activeScopedURLs.keys)
        activeScopedURLs.removeAll()
        accessLock.unlock()
        urls.forEach(endScopedAccess)
    }

    deinit { releaseAll() }

    func migrationPartialURL(artifactKey: String) throws -> URL {
        guard Self.isSafeStableID(artifactKey) else { throw MediaStoreError.invalidStableID }
        return migrationIncomingRoot.appendingPathComponent("\(artifactKey).partial", isDirectory: false)
    }

    func adoptedDocumentReference(for sourceURL: URL) -> MediaReference? {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let documents = documentsRoot.standardizedFileURL.resolvingSymlinksInPath()
        let music = documentsMusicRoot.standardizedFileURL.resolvingSymlinksInPath()
        let musicPrefix = music.path.hasSuffix("/") ? music.path : music.path + "/"
        let incomingPrefix = documentsIncomingRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard source.path.hasPrefix(musicPrefix), !source.path.hasPrefix(incomingPrefix) else { return nil }
        let documentsPrefix = documents.path.hasSuffix("/") ? documents.path : documents.path + "/"
        guard source.path.hasPrefix(documentsPrefix) else { return nil }
        return .documents(relativePath: String(source.path.dropFirst(documentsPrefix.count)))
    }

    func importIntoDocuments(
        sourceURL: URL,
        albumID: String,
        trackID: String,
        verifier: (URL) throws -> Bool
    ) throws -> MediaReference {
        guard Self.isSafeStableID(albumID), Self.isSafeStableID(trackID) else {
            throw MediaStoreError.invalidStableID
        }
        let ext = sourceURL.pathExtension.lowercased()
        guard Self.isSafeExtension(ext) else { throw MediaStoreError.invalidFileExtension }
        if let adopted = adoptedDocumentReference(for: sourceURL) { return adopted }

        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let incoming = documentsIncomingRoot.standardizedFileURL.resolvingSymlinksInPath()
        let incomingPrefix = incoming.path.hasSuffix("/") ? incoming.path : incoming.path + "/"
        guard !source.path.hasPrefix(incomingPrefix) else { throw MediaStoreError.unsafeRelativePath }

        let gateKey = incoming.path + "\u{0}" + trackID
        let importGate = Self.acquireGate(key: gateKey)
        defer { Self.releaseGate(importGate, key: gateKey) }

        let partial = documentsIncomingRoot.appendingPathComponent("\(trackID).partial.\(ext)", isDirectory: false)
        let albumRoot = importedDocumentsRoot.appendingPathComponent(albumID, isDirectory: true)
        let filename = "\(trackID).\(ext)"
        let destination = albumRoot.appendingPathComponent(filename, isDirectory: false)
        try? fileManager.removeItem(at: partial)
        do {
            try fileManager.copyItem(at: sourceURL, to: partial)
            let handle = try FileHandle(forWritingTo: partial)
            try handle.synchronize()
            try handle.close()
            let sourceSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let copySize = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard sourceSize == copySize, try verifier(partial) else { throw MediaStoreError.verificationFailed }
            try fileManager.createDirectory(at: albumRoot, withIntermediateDirectories: true)
            try commitImport(partial, destination)
            return .documents(relativePath: "Music/_Imported/\(albumID)/\(filename)")
        } catch {
            try? fileManager.removeItem(at: partial)
            if (try? fileManager.contentsOfDirectory(at: albumRoot, includingPropertiesForKeys: nil).isEmpty) == true {
                try? fileManager.removeItem(at: albumRoot)
            }
            throw error
        }
    }

    func removeImportedDocument(_ reference: MediaReference) {
        guard case .documents(let relativePath) = reference,
              relativePath.hasPrefix("Music/_Imported/") else { return }
        guard let url = try? resolve(relativePath, beneath: documentsRoot) else { return }
        try? fileManager.removeItem(at: url)
        let parent = url.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).isEmpty) == true {
            try? fileManager.removeItem(at: parent)
        }
    }

    func commitMigratedAudio(
        partialURL: URL,
        trackID: String,
        fileExtension: String,
        verifier: (URL) throws -> Bool
    ) throws -> MediaReference {
        guard Self.isSafeStableID(trackID) else { throw MediaStoreError.invalidStableID }
        let ext = fileExtension.lowercased()
        guard Self.isSafeExtension(ext) else { throw MediaStoreError.invalidFileExtension }
        let expectedParent = migrationIncomingRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard partialURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == expectedParent,
              try verifier(partialURL) else { throw MediaStoreError.verificationFailed }
        let filename = "\(trackID).\(ext)"
        let destination = migratedRoot.appendingPathComponent(filename, isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: destination)
        }
        return .documents(relativePath: "Music/_Migrated/\(filename)")
    }

    private func resolve(_ relativePath: String, beneath rootURL: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            throw MediaStoreError.unsafeRelativePath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MediaStoreError.unsafeRelativePath
        }

        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else { throw MediaStoreError.unsafeRelativePath }
        return candidate
    }

    private static func isSafeStableID(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private static func isSafeExtension(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private static func resolveBookmark(_ data: Data) throws -> (URL, Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    private func removeStalePartials(
        at root: URL,
        now: () -> Date,
        stalePartialInterval: TimeInterval
    ) throws {
        for item in try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) where item.lastPathComponent.contains(".partial.") {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate,
               now().timeIntervalSince(modified) >= stalePartialInterval {
                try? fileManager.removeItem(at: item)
            }
        }
    }
}
