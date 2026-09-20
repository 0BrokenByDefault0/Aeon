import SwiftUI
import UIKit

struct PlayerPresentation {
    let track: CatalogTrack
    let album: CatalogAlbum
    let artist: String
    let artwork: Image?
    let duration: TimeInterval

    static func resolve(
        snapshot: PlaybackSnapshot?,
        catalog: CatalogRepository,
        artworkStore: ArtworkStore
    ) -> PlayerPresentation? {
        guard let snapshot, let trackID = snapshot.trackID,
              let track = try? catalog.track(id: trackID),
              let album = try? catalog.album(id: track.albumID) else { return nil }
        let image: Image?
        if let key = album.artworkKey,
           let url = try? artworkStore.url(forKey: key),
           let value = UIImage(contentsOfFile: url.path) {
            image = Image(uiImage: value)
        } else {
            image = nil
        }
        return PlayerPresentation(
            track: track,
            album: album,
            artist: track.artist.isEmpty ? album.artist : track.artist,
            artwork: image,
            duration: max(0, track.duration ?? snapshot.sourceFormat?.duration ?? 0)
        )
    }
}

struct PlayerBar: View {
    @ObservedObject var playback: PlaybackController
    let catalog: CatalogRepository
    let artworkStore: ArtworkStore
    let open: () -> Void

    var body: some View {
        if let presentation = PlayerPresentation.resolve(
            snapshot: playback.snapshot,
            catalog: catalog,
            artworkStore: artworkStore
        ), let snapshot = playback.snapshot {
            HStack(spacing: AeonTheme.Space.small) {
                Button(action: open) {
                    HStack(spacing: AeonTheme.Space.medium) {
                        miniArtwork(presentation.artwork)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(presentation.track.title)
                                .font(AeonTheme.FontToken.ui(.callout, weight: .semibold))
                                .foregroundStyle(AeonTheme.ColorToken.bone)
                                .lineLimit(1)
                            Text(presentation.artist)
                                .font(AeonTheme.FontToken.ui(.caption))
                                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Now Playing for \(presentation.track.title)")
                .accessibilityIdentifier("aeon.player.open")

                transportButton(
                    snapshot.intent == .playing ? .pause : .play,
                    label: snapshot.intent == .playing ? "Pause" : "Play",
                    identifier: "aeon.player.toggle",
                    action: playback.toggle
                )
                transportButton(
                    .next,
                    label: "Next track",
                    identifier: "aeon.player.next",
                    action: playback.next
                )
            }
            .padding(.horizontal, AeonTheme.Space.medium)
            .frame(minHeight: AeonTheme.Space.playerBar)
            // The one remaining translucent surface in the app. Over a live starfield it
            // muddied into the sky; every other utility surface is already opaque.
            .background(AeonTheme.ColorToken.chamber)
            .overlay(alignment: .top) {
                Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
            }
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(AeonTheme.ColorToken.ivorySecondary)
                        .frame(
                            width: geometry.size.width * progress(snapshot: snapshot, duration: presentation.duration),
                            height: 2
                        )
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
    }

    // Square, hairline-bordered, exactly like every other cover in the app. The rounded
    // corner here was the last survivor of the pre-square geometry.
    private func miniArtwork(_ image: Image?) -> some View {
        AeonArtwork(image: image, size: 44)
    }

    private func transportButton(
        _ glyph: AeonGlyphKind,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            AeonFeedback.transport()
            action()
        } label: {
            AeonGlyph(kind: glyph)
                .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AeonTheme.ColorToken.bone)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func progress(snapshot: PlaybackSnapshot, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, snapshot.position / duration)))
    }
}
