import Foundation

/// Persists the security-scoped bookmarks Aeon is granted when the user picks a folder.
///
/// The picker's grant dies with the URL object, so a folder chosen in one launch is
/// unreachable in the next unless its bookmark is stored. Keeping them lets a later
/// import of the same folder resume against the same grant instead of asking the user
/// to re-pick, and lets Aeon say plainly when a remembered folder has gone away.
struct ImportedFolder: Codable, Equatable {
    let path: String
    let name: String
    var bookmark: Data
}

enum ImportedFolderError: Error, Equatable {
    case accessDenied
    case unavailable
}

final class ImportedFolderStore {
    static let settingKey = "library.import.folders"
    static let maximumRemembered = 32

    private let repository: CatalogRepository
    private let makeBookmark: (URL) throws -> Data
    private let resolveBookmark: (Data) throws -> (URL, Bool)
    private let beginScopedAccess: (URL) -> Bool
    private let endScopedAccess: (URL) -> Void
    private let now: () -> Date
    private let lock = NSLock()

    init(
        repository: CatalogRepository,
        makeBookmark: ((URL) throws -> Data)? = nil,
        resolveBookmark: ((Data) throws -> (URL, Bool))? = nil,
        beginScopedAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        endScopedAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.makeBookmark = makeBookmark ?? Self.defaultBookmark
        self.resolveBookmark = resolveBookmark ?? Self.defaultResolve
        self.beginScopedAccess = beginScopedAccess
        self.endScopedAccess = endScopedAccess
        self.now = now
    }

    func folders() -> [ImportedFolder] {
        (try? repository.setting([ImportedFolder].self, forKey: Self.settingKey)) ?? []
    }

    /// Stores the grant for `url`. The caller must already hold scoped access — bookmark
    /// creation reads the file system through that grant.
    @discardableResult
    func remember(_ url: URL) throws -> ImportedFolder {
        let standardized = url.standardizedFileURL
        let data: Data
        do {
            data = try makeBookmark(standardized)
        } catch {
            throw ImportedFolderError.accessDenied
        }
        let folder = ImportedFolder(
            path: standardized.path,
            name: standardized.lastPathComponent,
            bookmark: data
        )
        lock.lock()
        defer { lock.unlock() }
        var stored = folders().filter { $0.path != folder.path }
        stored.insert(folder, at: 0)
        if stored.count > Self.maximumRemembered { stored.removeLast(stored.count - Self.maximumRemembered) }
        try repository.setSetting(stored, forKey: Self.settingKey, at: now())
        return folder
    }

    /// Resolves a remembered folder and begins scoped access on it. The caller owns the
    /// returned access and must pass it to `endAccess` when the import finishes.
    func resolve(path: String) throws -> URL {
        guard let folder = folders().first(where: { $0.path == path }) else {
            throw ImportedFolderError.unavailable
        }
        let resolved: URL
        var stale = false
        do {
            (resolved, stale) = try resolveBookmark(folder.bookmark)
        } catch {
            throw ImportedFolderError.unavailable
        }
        guard beginScopedAccess(resolved) else { throw ImportedFolderError.accessDenied }
        if stale, let refreshed = try? makeBookmark(resolved) {
            var updated = folder
            updated.bookmark = refreshed
            lock.lock()
            var stored = folders().filter { $0.path != updated.path }
            stored.insert(updated, at: 0)
            try? repository.setSetting(stored, forKey: Self.settingKey, at: now())
            lock.unlock()
        }
        return resolved
    }

    func endAccess(_ url: URL) {
        endScopedAccess(url)
    }

    func forget(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let stored = folders().filter { $0.path != path }
        try? repository.setSetting(stored, forKey: Self.settingKey, at: now())
    }

    private static func defaultBookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func defaultResolve(_ data: Data) throws -> (URL, Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }
}
