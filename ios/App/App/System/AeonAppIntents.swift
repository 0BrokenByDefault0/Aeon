import AppIntents
import Foundation

@MainActor
enum AeonIntentSupport {
    /// The player once the library is open and the coordinator has restored its state.
    static func readyPlayback(timeout: TimeInterval = 5) async -> PlaybackController? {
        guard let services = await AeonRuntime.awaitServices(timeout: timeout) else { return nil }
        let playback = services.playbackController
        let deadline = Date().addingTimeInterval(timeout)
        while !playback.isInitialized, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return playback.isInitialized ? playback : nil
    }

    static func play(tracks: [CatalogTrack], playback: PlaybackController) throws {
        guard let first = tracks.first else { throw AeonIntentError.nothingToPlay }
        let queue = tracks.map { QueueItem(trackID: $0.id, albumID: $0.albumID, mediaRef: $0.mediaReference) }
        playback.loadAndPlay(track: first, queue: queue, index: 0)
    }
}

/// An album as Siri and Shortcuts see it. Titles and artists are read from the on-device
/// catalogue only when the system asks; nothing is donated ahead of time.
struct AeonAlbumEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Album"
    static let defaultQuery = AeonAlbumQuery()

    let id: String
    let title: String
    let artist: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(artist)")
    }

    init(summary: CatalogAlbumSummary) {
        id = summary.id
        title = summary.title
        artist = summary.artist
    }
}

struct AeonAlbumQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [AeonAlbumEntity.ID]) async throws -> [AeonAlbumEntity] {
        guard let catalog = await AeonRuntime.awaitServices()?.catalogRepository else { return [] }
        return identifiers.compactMap { id in (try? catalog.albumSummary(id: id)).flatMap { $0 }.map(AeonAlbumEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [AeonAlbumEntity] {
        guard let catalog = await AeonRuntime.awaitServices()?.catalogRepository else { return [] }
        return ((try? catalog.search(string, limit: 24))?.albums ?? []).map(AeonAlbumEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [AeonAlbumEntity] {
        guard let catalog = await AeonRuntime.awaitServices()?.catalogRepository else { return [] }
        return ((try? catalog.albumPage(offset: 0, limit: 24, sort: .recentlyAdded)) ?? []).map(AeonAlbumEntity.init)
    }
}

struct AeonPlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Plays an album from your ISOLATION library from its first track.")

    @Parameter(title: "Album")
    var album: AeonAlbumEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album)")
    }

    init() {}

    init(album: AeonAlbumEntity) {
        self.album = album
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let services = AeonRuntime.services, let playback = await AeonIntentSupport.readyPlayback() else {
            throw AeonIntentError.libraryUnavailable
        }
        try AeonIntentSupport.play(tracks: try services.catalogRepository.tracks(albumID: album.id), playback: playback)
        return .result()
    }
}

struct AeonShuffleFavouritesIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Favourites"
    static let description = IntentDescription("Plays the tracks you marked as favourites in ISOLATION, shuffled.")

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let services = AeonRuntime.services, let playback = await AeonIntentSupport.readyPlayback() else {
            throw AeonIntentError.libraryUnavailable
        }
        let catalog = services.catalogRepository
        let ids = ((try? catalog.allPlaylistItems(playlistID: CatalogRepository.favouritesPlaylistID)) ?? []).map(\.trackID)
        let tracks = ids.shuffled().compactMap { (try? catalog.track(id: $0)).flatMap { $0 } }
        try AeonIntentSupport.play(tracks: tracks, playback: playback)
        return .result()
    }
}

struct AeonShowAlbumIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Album"
    static let description = IntentDescription("Opens an album in the ISOLATION library.")
    static let openAppWhenRun = true

    @Parameter(title: "Album")
    var album: AeonAlbumEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: AeonRuntime.showAlbumNotification, object: album.id)
        return .result()
    }
}

struct AeonShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AeonResumeIntent(),
            phrases: ["Resume \(.applicationName)", "Continue listening in \(.applicationName)"],
            shortTitle: "Resume",
            systemImageName: "play"
        )
        AppShortcut(
            intent: AeonPlayAlbumIntent(),
            phrases: ["Play \(\.$album) in \(.applicationName)", "Play an album in \(.applicationName)"],
            shortTitle: "Play Album",
            systemImageName: "square.stack"
        )
        AppShortcut(
            intent: AeonShuffleFavouritesIntent(),
            phrases: ["Shuffle my favourites in \(.applicationName)", "Shuffle favourites in \(.applicationName)"],
            shortTitle: "Shuffle Favourites",
            systemImageName: "shuffle"
        )
        AppShortcut(
            intent: AeonPauseIntent(),
            phrases: ["Pause \(.applicationName)"],
            shortTitle: "Pause",
            systemImageName: "pause"
        )
    }
}
