import Combine
import MediaPlayer
import UIKit

@MainActor
final class RemoteCommandCoordinator {
    private let controller: PlaybackController
    private let catalog: CatalogRepository
    private let artworkStore: ArtworkStore
    private let commandCenter: MPRemoteCommandCenter
    private let infoCenter: MPNowPlayingInfoCenter
    private var observation: AnyCancellable?
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    init(
        controller: PlaybackController,
        catalog: CatalogRepository,
        artworkStore: ArtworkStore,
        commandCenter: MPRemoteCommandCenter = .shared(),
        infoCenter: MPNowPlayingInfoCenter = .default()
    ) {
        self.controller = controller
        self.catalog = catalog
        self.artworkStore = artworkStore
        self.commandCenter = commandCenter
        self.infoCenter = infoCenter
        installCommands()
        observation = controller.$snapshot.compactMap { $0 }.sink { [weak self] in self?.publish($0) }
    }

    deinit {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
    }

    private func installCommands() {
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandTargets.append((commandCenter.playCommand, commandCenter.playCommand.addTarget { [weak self] _ in self?.controller.play(); return .success }))
        commandTargets.append((commandCenter.pauseCommand, commandCenter.pauseCommand.addTarget { [weak self] _ in self?.controller.pause(); return .success }))
        commandTargets.append((commandCenter.togglePlayPauseCommand, commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in self?.controller.toggle(); return .success }))
        commandTargets.append((commandCenter.nextTrackCommand, commandCenter.nextTrackCommand.addTarget { [weak self] _ in self?.controller.next(); return .success }))
        commandTargets.append((commandCenter.previousTrackCommand, commandCenter.previousTrackCommand.addTarget { [weak self] _ in self?.controller.previous(); return .success }))
        let positionTarget = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.controller.seek(to: event.positionTime)
            return .success
        }
        commandTargets.append((commandCenter.changePlaybackPositionCommand, positionTarget))
    }

    private func publish(_ snapshot: PlaybackSnapshot) {
        guard let trackID = snapshot.trackID,
              let track = try? catalog.track(id: trackID) else {
            infoCenter.nowPlayingInfo = nil
            return
        }
        let album = try? catalog.album(id: track.albumID)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist.isEmpty ? (album?.artist ?? "") : track.artist,
            MPMediaItemPropertyAlbumTitle: album?.title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.intent == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: snapshot.queueIndex ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: snapshot.queue.count,
            "AeonPlaybackRoute": snapshot.route?.name ?? "Unknown output"
        ]
        if let duration = track.duration ?? snapshot.sourceFormat?.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let key = album?.artworkKey,
           let url = try? artworkStore.url(forKey: key),
           let image = UIImage(contentsOfFile: url.path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = snapshot.intent == .playing ? .playing : .paused
    }
}
