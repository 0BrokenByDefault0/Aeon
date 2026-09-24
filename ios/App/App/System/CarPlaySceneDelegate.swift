import CarPlay
import UIKit

/// CarPlay audio interface: recently played, recently added albums, and playlists.
///
/// iOS only connects this scene for an app signed with Apple's
/// `com.apple.developer.carplay-audio` entitlement. That entitlement is granted by Apple
/// on request and is deliberately absent from this project so that ordinary signing keeps
/// working; until it is added, this delegate is never instantiated.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private static let listLimit = 100

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Task { @MainActor [weak self] in
            guard let self else { return }
            let services = await AeonRuntime.awaitServices()
            let root = CPTabBarTemplate(templates: [
                self.recentTemplate(services),
                self.albumsTemplate(services),
                self.playlistsTemplate(services)
            ])
            interfaceController.setRootTemplate(root, animated: false, completion: nil)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    private func recentTemplate(_ services: AppServices?) -> CPListTemplate {
        let items = ((try? services?.catalogRepository.listeningRouteItems(.recentlyPlayed, limit: Self.listLimit)) ?? [])
        let rows = items.enumerated().map { position, item in
            listItem(text: item.trackTitle, detail: "\(item.artist) \u{00b7} \(item.albumTitle)") { [weak self] in
                self?.play(trackIDs: items.map(\.trackID), startingAt: position)
            }
        }
        return CPListTemplate(title: "Recent", sections: [CPListSection(items: rows)])
    }

    private func albumsTemplate(_ services: AppServices?) -> CPListTemplate {
        let albums = ((try? services?.catalogRepository.albumPage(offset: 0, limit: Self.listLimit, sort: .recentlyAdded)) ?? [])
        let rows = albums.map { album in
            listItem(text: album.title, detail: album.artist) { [weak self] in self?.playAlbum(id: album.id) }
        }
        return CPListTemplate(title: "Albums", sections: [CPListSection(items: rows)])
    }

    private func playlistsTemplate(_ services: AppServices?) -> CPListTemplate {
        let catalog = services?.catalogRepository
        let playlists = ((try? catalog?.playlists()) ?? [])
        let rows = playlists.map { playlist in
            listItem(text: playlist.name, detail: nil) { [weak self] in
                let ids = ((try? catalog?.allPlaylistItems(playlistID: playlist.id)) ?? []).map(\.trackID)
                self?.play(trackIDs: ids, startingAt: 0)
            }
        }
        return CPListTemplate(title: "Playlists", sections: [CPListSection(items: rows)])
    }

    private func listItem(text: String, detail: String?, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: text, detailText: detail)
        item.handler = { _, completion in
            action()
            completion()
        }
        return item
    }

    private func playAlbum(id: String) {
        guard let catalog = AeonRuntime.services?.catalogRepository,
              let tracks = try? catalog.tracks(albumID: id) else { return }
        play(tracks: tracks, startingAt: 0)
    }

    private func play(trackIDs: [String], startingAt position: Int) {
        guard let catalog = AeonRuntime.services?.catalogRepository else { return }
        play(tracks: trackIDs.compactMap { (try? catalog.track(id: $0)).flatMap { $0 } }, startingAt: position)
    }

    private func play(tracks: [CatalogTrack], startingAt position: Int) {
        guard let playback = AeonRuntime.services?.playbackController, !tracks.isEmpty else { return }
        let index = min(max(0, position), tracks.count - 1)
        let queue = tracks.map { QueueItem(trackID: $0.id, albumID: $0.albumID, mediaRef: $0.mediaReference) }
        playback.loadAndPlay(track: tracks[index], queue: queue, index: index)
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }
}
