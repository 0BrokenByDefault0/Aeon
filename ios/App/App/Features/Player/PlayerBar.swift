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
        let duration = snapshot.sourceFormat?.duration ?? track.duration ?? 0
        return PlayerPresentation(
            track: track,
            album: album,
            artist: track.artist.isEmpty ? album.artist : track.artist,
            artwork: image,
            duration: duration.isFinite ? max(0, duration) : 0
        )
    }
}

struct PlayerBar: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var visibility: PlayerBarPresentation
    var layerID: UUID? = nil
    let catalog: CatalogRepository
    let artworkStore: ArtworkStore
    let open: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let presentation = PlayerPresentation.resolve(
            snapshot: playback.snapshot,
            catalog: catalog,
            artworkStore: artworkStore
        ), let snapshot = playback.snapshot {
            HStack(spacing: AeonTheme.Space.small) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        miniArtwork(presentation.artwork)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(presentation.track.title)
                                .font(AeonTheme.FontToken.ui(.subheadline, weight: .semibold))
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
            .frame(minHeight: 56)
            .background {
                if reduceTransparency || AeonTestOverrides.reduceTransparency || contrast == .increased || AeonTestOverrides.increasedContrast {
                    AeonTheme.ColorToken.surface
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.12))
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(AeonTheme.ColorToken.ivorySecondary)
                        .frame(
                            width: geometry.size.width * progress(snapshot: snapshot, duration: presentation.duration),
                            height: 2.5
                        )
                }
                .frame(height: 2.5)
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
            .padding(.horizontal, AeonTheme.Space.medium)
            .padding(.vertical, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("aeon.player.bar")
            .opacity(visibility.isActive(layerID) ? 1 : 0)
            .allowsHitTesting(visibility.isActive(layerID))
            .accessibilityHidden(!visibility.isActive(layerID))
        }
    }

    // Square, hairline-bordered, exactly like every other cover in the app. The rounded
    // corner here was the last survivor of the pre-square geometry.
    private func miniArtwork(_ image: Image?) -> some View {
        AeonArtwork(image: image, size: 40)
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

/// Presentation ownership only; all layers still use the one playback controller.
/// Covered bars keep their layout reservation without remaining touch/VoiceOver targets.
final class PlayerBarPresentation: ObservableObject {
    @Published private var layers: [UUID] = []

    func isActive(_ id: UUID?) -> Bool { layers.last == id }
    func present(_ id: UUID) {
        if !layers.contains(id) { layers.append(id) }
    }
    func dismiss(_ id: UUID) { layers.removeAll { $0 == id } }
}

/// Modal screens borrow the same playback controller. Nested sheets compose dismiss
/// actions so opening the player returns through the whole presentation stack.
struct PlayerBarContext {
    let playback: PlaybackController
    let presentation: PlayerBarPresentation
    let catalog: CatalogRepository
    let artworkStore: ArtworkStore
    let open: () -> Void
}

private struct PlayerBarContextKey: EnvironmentKey {
    static let defaultValue: PlayerBarContext? = nil
}

extension EnvironmentValues {
    var aeonPlayerBar: PlayerBarContext? {
        get { self[PlayerBarContextKey.self] }
        set { self[PlayerBarContextKey.self] = newValue }
    }
}

private struct ModalPlayerBar: ViewModifier {
    @Environment(\.aeonPlayerBar) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var layerID = UUID()

    @ViewBuilder func body(content: Content) -> some View {
        if let player {
            let scoped = PlayerBarContext(playback: player.playback, presentation: player.presentation, catalog: player.catalog,
                artworkStore: player.artworkStore, open: { dismiss(); player.open() })
            // A concrete sibling reserves space even for GeometryReader-backed album
            // content, which otherwise extends through a safeAreaInset on this sheet.
            VStack(spacing: 0) {
                content
                    .environment(\.aeonPlayerBar, scoped)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PlayerBar(playback: scoped.playback, visibility: scoped.presentation,
                    layerID: layerID, catalog: scoped.catalog,
                    artworkStore: scoped.artworkStore, open: scoped.open)
            }
            .presentationBackground(.clear)
            .onAppear { player.presentation.present(layerID) }
            .onDisappear { player.presentation.dismiss(layerID) }
        } else {
            content
        }
    }
}

extension View {
    func aeonMiniPlayerInset() -> some View { modifier(ModalPlayerBar()) }
}
