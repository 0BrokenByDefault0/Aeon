import Combine
import Foundation

struct PlaylistOverview: Equatable, Identifiable {
    let playlist: CatalogPlaylist
    let itemCount: Int
    var id: String { playlist.id }
}

/// Routes Aeon keeps for the collector rather than ones they chart by hand.
enum SmartRoute: String, CaseIterable, Identifiable {
    case favourites
    case recentlyPlayed
    case mostPlayed
    var id: String { rawValue }

    var title: String {
        switch self {
        case .favourites: return "Favourites"
        case .recentlyPlayed: return "Recently played"
        case .mostPlayed: return "Most played"
        }
    }

    var listeningOrder: CatalogListeningOrder? {
        switch self {
        case .favourites: return nil
        case .recentlyPlayed: return .recentlyPlayed
        case .mostPlayed: return .mostPlayed
        }
    }
}

struct SmartRouteOverview: Equatable, Identifiable {
    let route: SmartRoute
    let itemCount: Int
    var id: String { route.rawValue }
}

struct PlaylistRouteItem: Equatable, Identifiable {
    let item: CatalogPlaylistItem
    let unavailable: Bool
    var id: String { item.id }
}

@MainActor
final class PlaylistsController: ObservableObject {
    @Published private(set) var playlists: [PlaylistOverview] = []
    @Published private(set) var smartRoutes: [SmartRouteOverview] = []
    @Published private(set) var selectedPlaylist: CatalogPlaylist?
    @Published private(set) var selectedSmartRoute: SmartRoute?
    @Published private(set) var selectedItems: [PlaylistRouteItem] = []
    @Published private(set) var message: String?

    let repository: CatalogRepository
    let playback: PlaybackController
    /// Files -> ISOLATION -> Playlists. Nil keeps M3U import and export unavailable.
    let playlistsFolder: URL?
    private let fileManager: FileManager
    private var observation: CatalogObservation?

    static let smartRouteLimit = 100

    init(
        repository: CatalogRepository,
        playback: PlaybackController,
        playlistsFolder: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.playback = playback
        self.playlistsFolder = playlistsFolder
        self.fileManager = fileManager
        observation = repository.observeLibrary { [weak self] _ in self?.reload() }
        reload()
    }

    deinit { observation?.cancel() }

    @discardableResult
    func create(name: String, id: String = UUID().uuidString.lowercased(), at date: Date = Date()) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Give the playlist a name first."
            return false
        }
        do {
            try repository.createPlaylist(CatalogPlaylist(id: id, name: trimmed, createdAt: date, updatedAt: date))
            message = "Playlist \u{201c}\(trimmed)\u{201d} charted."
            reload()
            return true
        } catch {
            message = "The playlist could not be created."
            return false
        }
    }

    var selectionTitle: String { selectedSmartRoute?.title ?? selectedPlaylist?.name ?? "Route" }

    /// Hand-charted playlists can be renamed, reordered and deleted; smart routes cannot.
    var selectionIsEditable: Bool { selectedPlaylist != nil && selectedSmartRoute == nil }

    func select(id: String) {
        selectedSmartRoute = nil
        do {
            selectedPlaylist = try repository.allPlaylists().first { $0.id == id }
            try reloadSelection()
        } catch {
            selectedPlaylist = nil
            selectedItems = []
            message = "That playlist could not be opened."
        }
    }

    func select(smart route: SmartRoute) {
        selectedPlaylist = nil
        selectedSmartRoute = route
        do { try reloadSelection() } catch {
            selectedSmartRoute = nil
            selectedItems = []
            message = "That route could not be opened."
        }
    }

    func dismissSelection() {
        selectedPlaylist = nil
        selectedSmartRoute = nil
        selectedItems = []
    }

    @discardableResult
    func renameSelected(to name: String) -> Bool {
        guard let playlist = selectedPlaylist, selectionIsEditable else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Give the playlist a name first."
            return false
        }
        do {
            try repository.renamePlaylist(id: playlist.id, name: trimmed)
            selectedPlaylist?.name = trimmed
            reload()
            message = "Playlist renamed."
            return true
        } catch {
            message = "The playlist kept its name because the update failed."
            return false
        }
    }

    func moveItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let playlist = selectedPlaylist, selectionIsEditable else { return }
        let ids = Self.moving(selectedItems.map { $0.item.trackID }, fromOffsets: source, toOffset: destination)
        do {
            try repository.replacePlaylistItems(playlistID: playlist.id, trackIDs: ids)
            try reloadSelection()
            reload()
        } catch {
            message = "The order stayed as it was because the update failed."
        }
    }

    /// List-move semantics: `destination` is an index in the original array, as `onMove` reports it.
    static func moving<Element>(_ values: [Element], fromOffsets source: IndexSet, toOffset destination: Int) -> [Element] {
        let valid = source.filter { values.indices.contains($0) }
        let moved = valid.map { values[$0] }
        var remaining = values.enumerated().filter { !valid.contains($0.offset) }.map(\.element)
        let insertion = destination - valid.filter { $0 < destination }.count
        remaining.insert(contentsOf: moved, at: max(0, min(insertion, remaining.count)))
        return remaining
    }

    /// Writes the open route as extended M3U into Files -> ISOLATION -> Playlists.
    @discardableResult
    func exportSelected() -> URL? {
        guard let folder = playlistsFolder, selectedPlaylist != nil || selectedSmartRoute != nil else { return nil }
        guard !selectedItems.isEmpty else {
            message = "This route has no tracks to export."
            return nil
        }
        let entries: [PlaylistM3UEntry] = selectedItems.map { route in
            let track = try? repository.track(id: route.item.trackID)
            var path: String?
            if case .documents(let relativePath)? = track?.mediaReference { path = relativePath }
            return PlaylistM3UEntry(
                trackID: route.item.trackID,
                title: route.item.trackTitle,
                artist: route.item.artist,
                duration: track?.duration,
                documentsRelativePath: path
            )
        }
        let name = selectionTitle
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(PlaylistM3U.fileName(for: name), isDirectory: false)
            try Data(PlaylistM3U.encode(PlaylistM3UDocument(name: name, entries: entries)).utf8).write(to: url, options: .atomic)
            message = "Exported to Files \u{2192} ISOLATION \u{2192} Playlists."
            return url
        } catch {
            message = "The playlist could not be exported."
            return nil
        }
    }

    /// Reads every .m3u/.m3u8 in Files -> ISOLATION -> Playlists. A file whose name matches
    /// an existing playlist is treated as already imported, so re-running is harmless.
    @Published private(set) var isImporting = false

    @discardableResult
    func importPlaylistFiles(at date: Date = Date()) async -> Int {
        guard let folder = playlistsFolder, !isImporting else { return 0 }
        isImporting = true
        defer { isImporting = false }
        message = "Reading playlists…"
        do {
            let repository = repository
            let fileManager = fileManager
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.readPlaylistFiles(folder: folder, repository: repository, fileManager: fileManager, date: date)
            }.value
            reload()
            if result.imported == 0 {
                message = result.missing > 0 ? "No tracks in those playlists matched this library." : "No new playlists found. Place .m3u files in Files → ISOLATION → Playlists."
            } else {
                message = "\(result.imported) playlists imported."
            }
            if result.missing > 0 { message = (message ?? "") + " \(result.missing) tracks were not found." }
            if result.rejected > 0 { message = (message ?? "") + " \(result.rejected) files could not be imported within the size limits." }
            return result.imported
        } catch {
            message = "Playlist import could not finish. Wait for other library operations to finish, then try again."
            return 0
        }
    }

    private nonisolated static func readPlaylistFiles(folder: URL, repository: CatalogRepository, fileManager: FileManager, date: Date) throws -> (imported: Int, missing: Int, rejected: Int) {
        guard repository.beginFileOperation() else { throw ArchiveReaderError.operationInProgress }
        defer { repository.endFileOperation() }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { PlaylistM3U.fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var names = Set(try repository.allPlaylists().map { $0.name.lowercased() })
        var imported = 0, missing = 0, rejected = max(0, files.count - 256)
        var remainingBytes = 32 * 1_024 * 1_024
        var remainingEntries = 50_000
        for file in files.prefix(256) {
            try Task.checkCancellation()
            guard remainingBytes > 0, remainingEntries > 0,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { rejected += 1; continue }
            do {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let limit = min(4 * 1_024 * 1_024, remainingBytes)
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit,
                      let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { rejected += 1; continue }
                remainingBytes -= data.count
                let document = PlaylistM3U.decode(text)
                guard document.entries.count <= min(10_000, remainingEntries) else { rejected += 1; continue }
                remainingEntries -= document.entries.count
                let name = document.name.flatMap { $0.isEmpty ? nil : $0 } ?? file.deletingPathExtension().lastPathComponent
                guard !names.contains(name.lowercased()) else { continue }
                var ids: [String] = []
                for entry in document.entries {
                    try Task.checkCancellation()
                    if let id = entry.trackID, try repository.track(id: id) != nil { ids.append(id) }
                    else if let path = entry.documentsRelativePath, let id = try repository.trackID(documentsRelativePath: path) { ids.append(id) }
                    else if let id = try repository.trackID(title: entry.title, artist: entry.artist) { ids.append(id) }
                    else { missing += 1 }
                }
                guard !ids.isEmpty else { continue }
                try repository.createPlaylist(name: name, trackIDs: ids, id: UUID().uuidString.lowercased(), at: date)
                names.insert(name.lowercased())
                imported += 1
            } catch is CancellationError { throw CancellationError() }
            catch { rejected += 1 }
        }
        return (imported, missing, rejected)
    }

    func play(startingAt position: Int = 0) {
        guard !selectedItems.isEmpty else {
            message = "This route has no tracks yet."
            return
        }
        let available = selectedItems.enumerated().compactMap { offset, value -> (Int, CatalogTrack)? in
            guard !value.unavailable, let track = try? repository.track(id: value.item.trackID) else { return nil }
            return (offset, track)
        }
        let requested = min(max(0, position), selectedItems.count - 1)
        guard let index = available.firstIndex(where: { $0.0 >= requested }) else {
            message = "No available tracks remain here. Choose another track or check Library Health."
            return
        }
        let tracks = available.map { $0.1 }
        let queue = tracks.map { QueueItem(trackID: $0.id, albumID: $0.albumID, mediaRef: $0.mediaReference) }
        playback.loadAndPlay(track: tracks[index], queue: queue, index: index)
        message = available.count < selectedItems.count ? "Route loaded. Missing tracks were skipped." : "Route loaded into the queue."
    }

    func remove(position: Int) {
        guard selectedItems.indices.contains(position) else { return }
        if selectedSmartRoute == .favourites {
            do {
                try repository.setFavourite(trackID: selectedItems[position].item.trackID, false)
                try reloadSelection()
                reload()
            } catch {
                message = "The track stayed in Favourites because the update failed."
            }
            return
        }
        guard let playlist = selectedPlaylist, selectionIsEditable else { return }
        var ids = selectedItems.map { $0.item.trackID }
        ids.remove(at: position)
        do {
            try repository.replacePlaylistItems(playlistID: playlist.id, trackIDs: ids)
            try reloadSelection()
            reload()
        } catch {
            message = "The track stayed in the playlist because the update failed."
        }
    }

    @discardableResult
    func deleteSelected() -> Bool {
        guard let playlist = selectedPlaylist, selectionIsEditable else { return false }
        do {
            guard try repository.deletePlaylist(id: playlist.id) else { return false }
            dismissSelection()
            reload()
            message = "Playlist deleted. Tracks stay in the library."
            return true
        } catch {
            message = "The playlist could not be deleted."
            return false
        }
    }

    func clearMessage() { message = nil }

    private func reload() {
        do {
            let all = try repository.allPlaylists()
            playlists = try all.filter { $0.id != CatalogRepository.favouritesPlaylistID }.map { playlist in
                PlaylistOverview(playlist: playlist, itemCount: try repository.playlistItemCount(playlistID: playlist.id))
            }
            let hasFavourites = all.contains { $0.id == CatalogRepository.favouritesPlaylistID }
            smartRoutes = try SmartRoute.allCases.compactMap { route -> SmartRouteOverview? in
                var count = 0
                if let order = route.listeningOrder {
                    count = try repository.listeningRouteItems(order, limit: Self.smartRouteLimit).count
                } else if hasFavourites {
                    count = try repository.playlistItemCount(playlistID: CatalogRepository.favouritesPlaylistID)
                }
                return count > 0 ? SmartRouteOverview(route: route, itemCount: count) : nil
            }
            if selectedPlaylist != nil || selectedSmartRoute != nil { try reloadSelection() }
        } catch {
            playlists = []
            smartRoutes = []
            message = "Playlists could not be read."
        }
    }

    private func reloadSelection() throws {
        let items: [CatalogPlaylistItem]
        switch selectedSmartRoute {
        case .favourites?:
            items = (try? repository.allPlaylistItems(playlistID: CatalogRepository.favouritesPlaylistID)) ?? []
        case let route?:
            items = try repository.listeningRouteItems(route.listeningOrder ?? .recentlyPlayed, limit: Self.smartRouteLimit)
        case nil:
            guard let playlist = selectedPlaylist else { return }
            items = try repository.allPlaylistItems(playlistID: playlist.id)
        }
        selectedItems = try items.map { item in
            let track = try repository.track(id: item.trackID)
            let unavailable: Bool
            switch track?.mediaReference {
            case .unavailable, .legacyBlob, .none: unavailable = true
            case .native, .documents, .externalBookmark: unavailable = false
            }
            return PlaylistRouteItem(item: item, unavailable: unavailable)
        }
    }
}
