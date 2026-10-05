import Combine
import Foundation
import ImageIO
import UIKit

@MainActor
final class LibraryController: ObservableObject {
    enum Sort: String, CaseIterable, Identifiable {
        case recent
        case artist
        case title
        case year
        case played

        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
        var repositorySort: CatalogAlbumSort {
            switch self {
            case .recent: return .recentlyAdded
            case .artist: return .artist
            case .title: return .title
            case .year: return .year
            case .played: return .mostPlayed
            }
        }
    }

    enum Density: String, CaseIterable, Identifiable {
        case grid
        case list

        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    static let pageSize = 48
    static let thumbnailLimit = pageSize * 3
    private static let thumbnailConcurrency = 4
    private static let sortKey = "library.sort.v1"
    private static let densityKey = "library.density.v1"

    @Published private(set) var albums: [CatalogAlbumSummary] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var searchResults = CatalogSearchResults(albums: [], artists: [], tracks: [])
    @Published private(set) var selectedAlbum: CatalogAlbum?
    @Published private(set) var selectedTracks: [CatalogTrack] = []
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var message: String?
    @Published var sort: Sort = .recent
    @Published var density: Density = .grid
    @Published var query = ""

    let repository: CatalogRepository
    let artworkStore: ArtworkStore
    let mediaStore: MediaStore
    let playback: PlaybackController
    let skyRepository: SkyRepository
    let skyController: SkySceneController
    let metadataEnricher: MetadataEnricher

    private struct PlaybackMarker: Equatable {
        let trackID: String?
        let isPlaying: Bool
    }

    private var observation: CatalogObservation?
    private var playbackObservation: AnyCancellable?
    private var thumbnailTasks: [String: Task<Void, Never>] = [:]
    private var thumbnailRequests: [String: UUID] = [:]
    private var pendingThumbnailKeys: [String] = []
    private var thumbnailRecency: [String] = []
    private var visibleArtworkReferences: [String: Int] = [:]
    private var refreshTask: Task<Void, Never>?
    private var playbackMarker = PlaybackMarker(trackID: nil, isPlaying: false)
    private var playingAlbumID: String?

    init(
        repository: CatalogRepository,
        artworkStore: ArtworkStore,
        mediaStore: MediaStore,
        playback: PlaybackController,
        skyRepository: SkyRepository,
        skyController: SkySceneController,
        metadataEnricher: MetadataEnricher
    ) {
        self.repository = repository
        self.artworkStore = artworkStore
        self.mediaStore = mediaStore
        self.playback = playback
        self.skyRepository = skyRepository
        self.skyController = skyController
        self.metadataEnricher = metadataEnricher
        sort = (try? repository.setting(String.self, forKey: Self.sortKey)).flatMap(Sort.init(rawValue:)) ?? .recent
        density = (try? repository.setting(String.self, forKey: Self.densityKey)).flatMap(Density.init(rawValue:)) ?? .grid
        seedFixtureIfNeeded()
        observation = repository.observeLibrary { [weak self] _ in self?.scheduleRefresh() }
        // The position timer publishes twice a second while music plays. The Library only
        // shows which album is in the player and whether it is playing, so it redraws on
        // those changes alone.
        playbackObservation = playback.$snapshot
            .map { PlaybackMarker(trackID: $0?.trackID, isPlaying: $0?.intent == .playing) }
            .removeDuplicates()
            .sink { [weak self] marker in self?.acceptPlayback(marker) }
        reload(reset: true)
    }

    deinit {
        observation?.cancel()
        refreshTask?.cancel()
        thumbnailTasks.values.forEach { $0.cancel() }
    }

    var hasMore: Bool { albums.count < totalCount }
    var isSearching: Bool { !CatalogRepository.normalize(query).isEmpty }
    var pendingThumbnailCount: Int { thumbnailTasks.count + pendingThumbnailKeys.count }

    var continueAlbum: CatalogAlbumSummary? {
        guard let albumID = playingAlbumID else { return nil }
        return albums.first { $0.id == albumID }
            ?? (try? repository.albumSummary(id: albumID)) ?? nil
    }

    func setSort(_ value: Sort) {
        guard sort != value else { return }
        sort = value
        try? repository.setSetting(value.rawValue, forKey: Self.sortKey)
        reload(reset: true)
    }

    func setDensity(_ value: Density) {
        guard density != value else { return }
        density = value
        try? repository.setSetting(value.rawValue, forKey: Self.densityKey)
    }

    func setQuery(_ value: String) {
        query = value
        performSearch()
    }

    func reload(reset: Bool) {
        do {
            if reset { albums = [] }
            totalCount = try repository.albumCount()
            let offset = reset ? 0 : albums.count
            let page = try repository.albumPage(offset: offset, limit: Self.pageSize, sort: sort.repositorySort)
            let loadedIDs = Set(albums.map(\.id))
            albums.append(contentsOf: page.filter { !loadedIDs.contains($0.id) })
            loadState = .ready
            prefetchArtwork(for: page)
            if isSearching { performSearch() }
            if let id = selectedAlbum?.id { selectAlbum(id: id) }
        } catch {
            loadState = .failed("The library could not be read. Your catalogue was not changed.")
        }
    }

    func loadNextPage() {
        guard hasMore, loadState == .ready else { return }
        reload(reset: false)
    }

    func selectAlbum(id: String) {
        do {
            selectedAlbum = try repository.album(id: id)
            selectedTracks = try repository.allTracks(albumID: id)
            requestArtwork(key: selectedAlbum?.artworkKey)
        } catch {
            selectedAlbum = nil
            selectedTracks = []
            message = "That album could not be opened."
        }
    }

    func dismissAlbum() {
        selectedAlbum = nil
        selectedTracks = []
    }

    func status(for albumID: String) -> String? {
        guard let playingAlbumID, playingAlbumID == albumID else { return nil }
        return playbackMarker.isPlaying ? "PLAYING" : "IN THE PLAYER"
    }

    func playAlbum(id: String, startingTrackID: String? = nil) {
        do {
            let tracks = try repository.allTracks(albumID: id)
            guard !tracks.isEmpty else {
                message = "This album has no playable tracks."
                return
            }
            let index = startingTrackID.flatMap { requested in tracks.firstIndex { $0.id == requested } } ?? 0
            let queue = tracks.map { QueueItem(trackID: $0.id, albumID: $0.albumID, mediaRef: $0.mediaReference) }
            playback.loadAndPlay(track: tracks[index], queue: queue, index: index)
        } catch {
            message = "Playback could not start because the album is unavailable."
        }
    }

    func findInSky(id: String, reduceMotion: Bool) {
        skyController.locate(id: id, reduceMotion: reduceMotion)
    }

    func addSelectedAlbum(to playlistID: String) {
        guard let album = selectedAlbum else { return }
        do {
            let additions = try repository.allTracks(albumID: album.id).map(\.id)
            try repository.appendPlaylistItems(playlistID: playlistID, trackIDs: additions)
            message = "Added to playlist."
        } catch {
            message = "The playlist could not be updated."
        }
    }

    func movementCount(for draft: CatalogAlbum) -> Int {
        guard let original = try? repository.album(id: draft.id),
              original.artist != draft.artist || original.genre != draft.genre else { return 0 }
        return (try? skyRepository.affectedAlbumCount(for: draft)) ?? 1
    }

    func saveAlbum(_ draft: CatalogAlbum, artworkData: Data?) -> Bool {
        guard repository.beginFileOperation() else { message = "Another library operation is running."; return false }
        defer { repository.endFileOperation() }
        do {
            guard let original = try repository.album(id: draft.id) else { return false }
            var updated = draft
            var newArtworkKey: String?
            if let artworkData {
                let key = artworkBaseKey(albumID: draft.id)
                newArtworkKey = try artworkStore.store(artworkData, key: key)
                updated.artworkKey = newArtworkKey
            }
            updated.updatedAt = Date()

            let needsSkyRechart = original.artist != updated.artist
                || original.genre != updated.genre
                || original.artworkKey != updated.artworkKey
            do {
                if needsSkyRechart {
                    _ = try skyRepository.rechart(updatedAlbum: updated)
                } else {
                    try skyRepository.refreshMetadata(updatedAlbum: updated)
                }
            } catch {
                if let newArtworkKey { try? artworkStore.remove(key: newArtworkKey) }
                throw error
            }
            if let old = original.artworkKey, old != updated.artworkKey { try? artworkStore.remove(key: old) }
            if newArtworkKey != nil {
                invalidateArtwork(key: original.artworkKey)
                invalidateArtwork(key: updated.artworkKey)
            }
            skyController.reload()
            selectAlbum(id: updated.id)
            reload(reset: true)
            message = "Album updated."
            return true
        } catch {
            message = "The edit could not be committed. Nothing was changed."
            return false
        }
    }

    func deleteSelectedAlbum() -> Bool {
        guard let album = selectedAlbum else { return false }
        guard repository.beginFileOperation() else { message = "Another library operation is running."; return false }
        defer { repository.endFileOperation() }
        do {
            let tracks = try repository.allTracks(albumID: album.id)
            let deleted = try skyRepository.deleteAlbum(id: album.id)
            guard deleted else { return false }
            var cleanupFailed = false
            for track in tracks {
                do { try mediaStore.removeManagedMedia(track.mediaReference) }
                catch { cleanupFailed = true }
            }
            if let key = album.artworkKey {
                do { try artworkStore.remove(key: key) }
                catch { cleanupFailed = true }
                invalidateArtwork(key: key)
            }
            scrubQueue(removingAlbumID: album.id)
            dismissAlbum()
            skyController.reload()
            reload(reset: true)
            message = cleanupFailed
                ? "Album removed. One managed file could not be cleaned up."
                : "Album deleted."
            return true
        } catch {
            message = "The album could not be deleted. Nothing was changed."
            return false
        }
    }

    func lookupGenre(for artist: String) async -> String? {
        do {
            let result = try await metadataEnricher.manualLookup(for: artist) { _, _ in true }
            if result == nil { message = "No genre match was found." }
            return result
        } catch {
            message = "Genre lookup is unavailable while offline."
            return nil
        }
    }

    func findArtwork(title: String, artist: String) async -> Data? {
        let term = [artist, title].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " ")
        guard !term.isEmpty,
              var components = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "1")
        ]
        do {
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = (payload["results"] as? [[String: Any]])?.first,
                  let value = result["artworkUrl100"] as? String,
                  let artworkURL = URL(string: value.replacingOccurrences(of: "100x100", with: "600x600")) else {
                message = "No artwork match was found."
                return nil
            }
            let (artworkData, artworkResponse) = try await URLSession.shared.data(from: artworkURL)
            guard (artworkResponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return artworkData
        } catch {
            message = "Artwork search is unavailable while offline."
            return nil
        }
    }

    func clearMessage() { message = nil }

    func availabilityText(for track: CatalogTrack) -> String? {
        switch track.mediaReference {
        case .unavailable, .legacyBlob: return "FILE UNAVAILABLE"
        case .native, .documents, .externalBookmark: return nil
        }
    }

    private func acceptPlayback(_ marker: PlaybackMarker) {
        objectWillChange.send()
        if marker.trackID != playbackMarker.trackID || playingAlbumID == nil {
            playingAlbumID = marker.trackID.flatMap { trackID in
                (try? repository.track(id: trackID))?.albumID
            }
        }
        playbackMarker = marker
    }

    /// Catalogue writes arrive in bursts: every committed album during an import, every
    /// recorded play. Coalesce them into one refresh that keeps the albums already loaded,
    /// so the grid neither collapses to its first page nor loses its scroll position.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            self.refreshLoadedAlbums()
        }
    }

    private func refreshLoadedAlbums() {
        do {
            let target = max(albums.count, Self.pageSize)
            var refreshed: [CatalogAlbumSummary] = []
            var seen = Set<String>()
            var offset = 0
            while offset < target {
                let limit = min(CatalogDatabase.maximumPageSize, target - offset)
                let page = try repository.albumPage(offset: offset, limit: limit, sort: sort.repositorySort)
                offset += page.count
                refreshed.append(contentsOf: page.filter { seen.insert($0.id).inserted })
                if page.count < limit { break }
            }
            totalCount = try repository.albumCount()
            albums = refreshed
            loadState = .ready
            // Visible cells request their own covers. A catalogue refresh must not decode
            // every page the collector has visited during this session.
            prefetchArtwork(for: Array(refreshed.prefix(Self.pageSize)))
            if isSearching { performSearch() }
            if let id = selectedAlbum?.id { selectAlbum(id: id) }
        } catch {
            loadState = .failed("The library could not be read. Your catalogue was not changed.")
        }
    }

    private func performSearch() {
        guard isSearching else {
            searchResults = CatalogSearchResults(albums: [], artists: [], tracks: [])
            return
        }
        do {
            searchResults = try repository.search(query, limit: Self.pageSize)
            prefetchArtwork(for: searchResults.albums)
        } catch {
            searchResults = CatalogSearchResults(albums: [], artists: [], tracks: [])
            message = "Search could not be completed."
        }
    }

    private func prefetchArtwork(for summaries: [CatalogAlbumSummary]) {
        for summary in summaries {
            requestArtwork(key: summary.artworkKey)
        }
    }

    func requestArtwork(key: String?) {
        guard let key else { return }
        if thumbnails[key] != nil {
            thumbnailRecency.removeAll { $0 == key }
            thumbnailRecency.append(key)
            return
        }
        guard thumbnailTasks[key] == nil, !pendingThumbnailKeys.contains(key) else { return }
        pendingThumbnailKeys.append(key)
        if pendingThumbnailKeys.count > Self.thumbnailLimit,
           let oldest = pendingThumbnailKeys.firstIndex(where: {
               $0 != selectedAlbum?.artworkKey && visibleArtworkReferences[$0] == nil
           }) {
            pendingThumbnailKeys.remove(at: oldest)
        }
        startThumbnailRequests()
    }

    func retainVisibleArtwork(key: String?) {
        guard let key else { return }
        visibleArtworkReferences[key, default: 0] += 1
        requestArtwork(key: key)
    }

    func releaseVisibleArtwork(key: String?) {
        guard let key, let count = visibleArtworkReferences[key] else { return }
        visibleArtworkReferences[key] = count > 1 ? count - 1 : nil
        trimThumbnails()
    }

    private func trimThumbnails() {
        var retained = thumbnails
        while thumbnailRecency.count > Self.thumbnailLimit {
            guard let oldest = thumbnailRecency.firstIndex(where: {
                $0 != selectedAlbum?.artworkKey && visibleArtworkReferences[$0] == nil
            }) else { break }
            retained[thumbnailRecency.remove(at: oldest)] = nil
        }
        if retained.count != thumbnails.count { thumbnails = retained }
    }

    private func startThumbnailRequests() {
        while thumbnailTasks.count < Self.thumbnailConcurrency, !pendingThumbnailKeys.isEmpty {
            let key = pendingThumbnailKeys.removeFirst()
            let requestID = UUID()
            thumbnailRequests[key] = requestID
            let store = artworkStore
            thumbnailTasks[key] = Task.detached(priority: .utility) { [weak self] in
                guard !Task.isCancelled else { return }
                let rendered = Self.decodeThumbnail(store: store, key: key)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.finishThumbnail(key: key, requestID: requestID, image: rendered)
                }
            }
        }
    }

    private func finishThumbnail(key: String, requestID: UUID, image: UIImage?) {
        guard thumbnailRequests[key] == requestID else { return }
        thumbnailTasks[key] = nil
        thumbnailRequests[key] = nil
        if let image {
            thumbnailRecency.removeAll { $0 == key }
            thumbnailRecency.append(key)
            thumbnails[key] = image
            trimThumbnails()
        }
        startThumbnailRequests()
    }

    private func invalidateArtwork(key: String?) {
        guard let key else { return }
        thumbnailTasks.removeValue(forKey: key)?.cancel()
        thumbnailRequests[key] = nil
        pendingThumbnailKeys.removeAll { $0 == key }
        thumbnailRecency.removeAll { $0 == key }
        thumbnails[key] = nil
    }

    private nonisolated static func decodeThumbnail(store: ArtworkStore, key: String) -> UIImage? {
        autoreleasepool {
            guard let url = try? store.url(forKey: key),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 360,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }
    }

    private func scrubQueue(removingAlbumID albumID: String) {
        guard let snapshot = playback.snapshot else { return }
        let filtered = snapshot.queue.filter { $0.albumID != albumID }
        guard filtered != snapshot.queue else { return }
        let index: Int
        if filtered.isEmpty { index = 0 }
        else if let trackID = snapshot.trackID, let retained = filtered.firstIndex(where: { $0.trackID == trackID }) {
            index = retained
        } else {
            index = min(snapshot.queueIndex ?? 0, filtered.count - 1)
        }
        playback.setQueue(filtered, index: index, revision: snapshot.queueRevision &+ 1)
    }

    private func artworkBaseKey(albumID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let value = albumID.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return "album-" + String(value).prefix(96)
    }

    private func seedFixtureIfNeeded() {
        #if DEBUG
        guard ["populated", "long-title"].contains(Self.fixtureName() ?? ""), (try? repository.albumCount()) == 0 else { return }
        let artists = ["Arden Vale", "Black Static", "Cinder Atlas", "Dawn Index"]
        let genres = ["Ambient", "Electronic", "Hip-Hop", "Soul"]
        let records: [(CatalogAlbum, [CatalogTrack])] = (1...12).map { index in
            let albumID = "library-fixture-album-\(index)"
            let timestamp = Date(timeIntervalSince1970: TimeInterval(index * 1_000))
            let album = CatalogAlbum(
                id: albumID,
                sequence: Int64(index),
                title: index == 12 ? (Self.fixtureName() == "long-title" ? "Lil Uzi Vert Vs. The World 2 (Sessions)" : "Glass Archive") : "Signal \(index)",
                artist: artists[(index - 1) % artists.count],
                year: index == 3 ? "" : "\(2012 + index)",
                genre: genres[(index - 1) % genres.count],
                artworkKey: nil,
                importedAt: timestamp,
                updatedAt: timestamp
            )
            let tracks = (1...3).map { trackIndex in
                CatalogTrack(
                    id: "\(albumID)-track-\(trackIndex)",
                    albumID: albumID,
                    sequence: trackIndex,
                    discNumber: 1,
                    trackNumber: trackIndex,
                    title: trackIndex == 2 && index == 12 ? "Silver Chamber" : "Movement \(trackIndex)",
                    artist: "",
                    duration: TimeInterval(150 + trackIndex * 17),
                    byteCount: 0,
                    mediaReference: .unavailable(trackID: "\(albumID)-track-\(trackIndex)"),
                    importedAt: timestamp
                )
            }
            return (album, tracks)
        }
        do {
            try repository.insertAlbums(records)
            try repository.mergeListening(
                trackID: "library-fixture-album-12-track-1",
                playCount: 7,
                lastPosition: 42,
                lastPlayedAt: Date(timeIntervalSince1970: 20_000)
            )
            _ = try skyRepository.backfill()
            skyController.reload()
        } catch {
            message = "The library fixture could not be prepared."
        }
        #endif
    }

    private static func fixtureName() -> String? {
        let arguments = AeonTestOverrides.arguments
        guard let index = arguments.firstIndex(of: "-AeonLibraryFixture"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
