import SwiftUI

struct AlbumDetailView: View {
    @ObservedObject var controller: LibraryController
    let album: CatalogAlbum
    let embedded: Bool
    let close: () -> Void
    let findInSky: (String) -> Void
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AeonTheme.Space.section) {
                header
                hero
                primaryActions
                metadata
                tracks
            }
            .padding(AeonTheme.Space.edge)
            .padding(.bottom, AeonTheme.Space.section)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(AeonTheme.ColorToken.void.ignoresSafeArea())
        .sheet(isPresented: $editing) {
            AlbumEditorView(controller: controller, album: controller.selectedAlbum ?? album)
        }
        .alert("Delete Album?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if controller.deleteSelectedAlbum() { close() }
            }
        } message: {
            Text("This removes the catalogue entry, managed copies, artwork, playlist references, and its star. Adopted files stay on disk.")
        }
        .accessibilityIdentifier("aeon.album.detail")
    }

    private var header: some View {
        HStack(spacing: AeonTheme.Space.medium) {
            Button(action: close) {
                Image(systemName: embedded ? "chevron.left" : "xmark")
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            }
            .buttonStyle(.plain)
            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            .contentShape(Rectangle())
            .foregroundStyle(AeonTheme.ColorToken.bone)
            .accessibilityLabel(embedded ? "Back to library" : "Close album")
            .accessibilityIdentifier("aeon.album.close")
            AeonBreadcrumb(text: "Album")
            Spacer(minLength: 0)
            Menu {
                Button("EDIT") { editing = true }
                Button("DELETE ALBUM", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            }
            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            .contentShape(Rectangle())
            .foregroundStyle(AeonTheme.ColorToken.bone)
            .accessibilityLabel("Album actions")
            .accessibilityIdentifier("aeon.album.actions")
        }
    }

    private var hero: some View {
        VStack(spacing: AeonTheme.Space.large) {
            let image = album.artworkKey
                .flatMap { controller.thumbnails[$0] }
                .map { Image(uiImage: $0) }
            AeonArtwork(image: image, size: embedded ? 230 : 300)
                .frame(maxWidth: .infinity)
            VStack(spacing: 6) {
                AeonDisplayText(album.title, size: 40, maximumLines: 3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                    .accessibilityIdentifier("aeon.album.title")
                Text(album.artist)
                    .font(AeonTheme.FontToken.ui(.title3, weight: .medium))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .multilineTextAlignment(.center)
                if let status = controller.status(for: album.id) { AeonLabel(text: status) }
            }
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
    }

    private var primaryActions: some View {
        VStack(spacing: AeonTheme.Space.medium) {
            HStack(spacing: AeonTheme.Space.small) {
                Button("PLAY") { controller.playAlbum(id: album.id) }
                    .buttonStyle(AeonButtonStyle(tier: .filled))
                    .frame(minWidth: AeonTheme.Space.minimumTarget, minHeight: AeonTheme.Space.minimumTarget)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("aeon.album.play")
                Button("FIND IN SKY") { findInSky(album.id) }
                    .buttonStyle(AeonButtonStyle(tier: .hairline))
                    .frame(minWidth: AeonTheme.Space.minimumTarget, minHeight: AeonTheme.Space.minimumTarget)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("aeon.album.find-in-sky")
            }
            HStack(spacing: AeonTheme.Space.large) {
                Button("EDIT") { editing = true }
                    .buttonStyle(AeonButtonStyle(tier: .bare))
                    .frame(minWidth: AeonTheme.Space.minimumTarget, minHeight: AeonTheme.Space.minimumTarget)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("aeon.album.edit")
                playlistMenu
            }
        }
    }

    private var playlistMenu: some View {
        Menu {
            let playlists = (try? controller.repository.playlists()) ?? []
            if playlists.isEmpty {
                Button("NO PLAYLISTS YET") {}.disabled(true)
            } else {
                ForEach(playlists) { playlist in
                    Button(playlist.name) { controller.addSelectedAlbum(to: playlist.id) }
                }
            }
        } label: {
            Label("ADD TO PLAYLIST", systemImage: "text.badge.plus")
                .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
                .tracking(1.0)
                .frame(minHeight: AeonTheme.Space.minimumTarget)
        }
        .frame(minHeight: AeonTheme.Space.minimumTarget)
        .contentShape(Rectangle())
        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        .accessibilityIdentifier("aeon.album.add-playlist")
    }

    private var metadata: some View {
        HStack(alignment: .top, spacing: AeonTheme.Space.section) {
            if !album.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadataValue("YEAR", album.year)
            }
            if !album.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadataValue("GENRE", album.genre)
            }
            metadataValue("TRACKS", "\(controller.selectedTracks.count)")
        }
        .padding(.vertical, AeonTheme.Space.large)
        .overlay(alignment: .top) {
            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
        }
    }

    private var tracks: some View {
        VStack(alignment: .leading, spacing: 0) {
            AeonLabel(text: "Tracks").padding(.bottom, AeonTheme.Space.small)
            ForEach(Array(controller.selectedTracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: AeonTheme.Space.medium) {
                    Text(trackNumber(track, fallback: index + 1))
                        .font(AeonTheme.FontToken.metric(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                        .frame(width: 28, alignment: .trailing)
                    Button {
                        controller.playAlbum(id: album.id, startingTrackID: track.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title)
                                .font(AeonTheme.FontToken.ui(.body, weight: .medium))
                                .foregroundStyle(AeonTheme.ColorToken.bone)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: AeonTheme.Space.small) {
                                if !track.artist.isEmpty { Text(track.artist) }
                                if let unavailable = controller.availabilityText(for: track) { Text(unavailable) }
                            }
                            .font(AeonTheme.FontToken.metric(.caption2))
                            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text(duration(track.duration))
                        .font(AeonTheme.FontToken.metric(.caption2))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    Menu {
                        Button("PLAY FROM HERE") {
                            controller.playAlbum(id: album.id, startingTrackID: track.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    }
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    .contentShape(Rectangle())
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .accessibilityLabel("Actions for \(track.title)")
                }
                .frame(minHeight: 62)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
                }
                .accessibilityIdentifier("aeon.album.track.\(track.id)")
            }
        }
    }

    private func metadataValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AeonLabel(text: label)
            Text(value)
                .font(AeonTheme.FontToken.ui(.callout, weight: .medium))
                .foregroundStyle(AeonTheme.ColorToken.bone)
        }
    }

    private func trackNumber(_ track: CatalogTrack, fallback: Int) -> String {
        if let number = track.trackNumber { return String(format: "%02d", number) }
        return String(format: "%02d", fallback)
    }

    private func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
