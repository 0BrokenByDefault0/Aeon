import Combine
import Foundation

struct PlaylistOverview: Equatable, Identifiable {
    let playlist: CatalogPlaylist
    let itemCount: Int
    var id: String { playlist.id }
}

struct PlaylistRouteItem: Equatable, Identifiable {
    let item: CatalogPlaylistItem
    let unavailable: Bool
    var id: String { item.id }
}

@MainActor
final class PlaylistsController: ObservableObject {
    @Published private(set) var playlists: [PlaylistOverview] = []
    @Published private(set) var selectedPlaylist: CatalogPlaylist?
    @Published private(set) var selectedItems: [PlaylistRouteItem] = []
    @Published private(set) var message: String?

    private let repository: CatalogRepository
    private let playback: PlaybackController
    private var observation: CatalogObservation?

    init(repository: CatalogRepository, playback: PlaybackController) {
        self.repository = repository
        self.playback = playback
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

    func select(id: String) {
        do {
            selectedPlaylist = try repository.playlists().first { $0.id == id }
            try reloadSelection()
        } catch {
            selectedPlaylist = nil
            selectedItems = []
            message = "That playlist could not be opened."
        }
    }

    func dismissSelection() {
        selectedPlaylist = nil
        selectedItems = []
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
        playback.load(track: tracks[index], queue: queue, index: index, autoplay: true)
        message = "Route loaded into the queue."
    }

    func remove(position: Int) {
        guard let playlist = selectedPlaylist, selectedItems.indices.contains(position) else { return }
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
        guard let playlist = selectedPlaylist else { return false }
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
            playlists = try repository.playlists().map { playlist in
                PlaylistOverview(playlist: playlist, itemCount: try repository.playlistItems(playlistID: playlist.id).count)
            }
            if selectedPlaylist != nil { try reloadSelection() }
        } catch {
            playlists = []
            message = "Playlists could not be read."
        }
    }

    private func reloadSelection() throws {
        guard let playlist = selectedPlaylist else { return }
        selectedItems = try repository.playlistItems(playlistID: playlist.id).map { item in
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
