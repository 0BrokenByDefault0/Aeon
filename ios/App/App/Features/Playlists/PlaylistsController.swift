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
            selectedPlaylist = try repository.playlists().first { $0.id == id }
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
    @discardableResult
    func importPlaylistFiles(at date: Date = Date()) -> Int {
        guard let folder = playlistsFolder else { return 0 }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { PlaylistM3U.fileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else {
            message = "Place .m3u files in Files \u{2192} ISOLATION \u{2192} Playlists, then import."
            return 0
        }
        var existingNames = Set(((try? repository.playlists()) ?? []).map { $0.name.lowercased() })
        var imported = 0
        var missing = 0
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            let document = PlaylistM3U.decode(text)
            let fallbackName = file.deletingPathExtension().lastPathComponent
            let name = (document.name?.isEmpty == false ? document.name : nil) ?? fallbackName
            guard !existingNames.contains(name.lowercased()) else { continue }
            var ids: [String] = []
            for entry in document.entries {
                if let id = resolve(entry) { ids.append(id) } else { missing += 1 }
            }
            guard !ids.isEmpty else { continue }
            if (try? repository.createPlaylist(name: name, trackIDs: ids, id: UUID().uuidString.lowercased(), at: date)) != nil {
                existingNames.insert(name.lowercased())
                imported += 1
            }
        }
        reload()
        if imported == 0 {
            message = missing > 0 ? "No tracks in those playlists matched this library." : "Those playlists are already here."
        } else {
            let noun = imported == 1 ? "playlist" : "playlists"
            message = missing > 0
                ? "\(imported) \(noun) imported. \(missing) tracks were not found in this library."
                : "\(imported) \(noun) imported."
        }
        return imported
    }

    private func resolve(_ entry: PlaylistM3UEntry) -> String? {
        if let id = entry.trackID, (try? repository.track(id: id)) != nil { return id }
        if let path = entry.documentsRelativePath, let id = try? repository.trackID(documentsRelativePath: path) { return id }
        return try? repository.trackID(title: entry.title, artist: entry.artist)
    }

    func play(startingAt position: Int = 0) {
        guard !selectedItems.isEmpty else {
            message = "This route has no tracks yet."
            return
        }
        guard !selectedItems.contains(where: \.unavailable) else {
            message = "A missing track kept this route from starting."
            return
        }
        let tracks = selectedItems.compactMap { try? repository.track(id: $0.item.trackID) }
        guard tracks.count == selectedItems.count else {
            message = "A missing track kept this route from starting."
            return
        }
        let index = min(max(0, position), tracks.count - 1)
        let queue = tracks.map { QueueItem(trackID: $0.id, albumID: $0.albumID, mediaRef: $0.mediaReference) }
        playback.loadAndPlay(track: tracks[index], queue: queue, index: index)
        message = "Route loaded into the queue."
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
            let all = try repository.playlists()
            playlists = try all.filter { $0.id != CatalogRepository.favouritesPlaylistID }.map { playlist in
                PlaylistOverview(playlist: playlist, itemCount: try repository.allPlaylistItems(playlistID: playlist.id).count)
            }
            let hasFavourites = all.contains { $0.id == CatalogRepository.favouritesPlaylistID }
            smartRoutes = try SmartRoute.allCases.compactMap { route -> SmartRouteOverview? in
                var count = 0
                if let order = route.listeningOrder {
                    count = try repository.listeningRouteItems(order, limit: Self.smartRouteLimit).count
                } else if hasFavourites {
                    count = try repository.allPlaylistItems(playlistID: CatalogRepository.favouritesPlaylistID).count
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
