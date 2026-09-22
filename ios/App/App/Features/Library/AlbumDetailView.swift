import SwiftUI

struct AlbumDetailView: View {
    @ObservedObject var controller: LibraryController
    let album: CatalogAlbum
    let embedded: Bool
    let close: () -> Void
    let findInSky: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editing = false
    @State private var confirmingDelete = false

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                hero(width: geometry.size.width, height: geometry.size.height)
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
        }
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
                AeonGlyph(kind: embedded ? .disclosure : .close)
                    .rotationEffect(.degrees(embedded ? 180 : 0))
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
                Button("EDIT") { editing = true }.accessibilityIdentifier("aeon.album.edit")
                Button("DELETE ALBUM", role: .destructive) { confirmingDelete = true }
            } label: {
                AeonGlyph(kind: .more)
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            }
            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            .contentShape(Rectangle())
            .foregroundStyle(AeonTheme.ColorToken.bone)
            .accessibilityLabel("Album actions")
            .accessibilityIdentifier("aeon.album.actions")
        }
    }

    private func hero(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 19) {
            let image = album.artworkKey
                .flatMap { controller.thumbnails[$0] }
                .map { Image(uiImage: $0) }
            AeonArtwork(image: image, size: min(260, max(205, min(width * 0.60, height * 0.34))))
                .frame(maxWidth: .infinity)
            VStack(spacing: 6) {
                AeonDisplayText(album.title, size: album.title.count > 32 ? 32 : 35, maximumLines: dynamicTypeSize.isAccessibilitySize ? 8 : 3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
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
        VStack(spacing: 4) {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button { AeonFeedback.transport(); controller.playAlbum(id: album.id) } label: {
                    HStack(spacing: 8) { AeonGlyph(kind: .play); Text("PLAY") }
                        .padding(.horizontal, 12).frame(minHeight: 44)
                }
                    .buttonStyle(AeonTransportButtonStyle())
                    .frame(minWidth: AeonTheme.Space.minimumTarget, minHeight: AeonTheme.Space.minimumTarget)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("aeon.album.play")
                Button { findInSky(album.id) } label: {
                    HStack(spacing: 8) { AeonGlyph(kind: .sky); Text("FIND IN SKY") }
                        .padding(.horizontal, 12).frame(minHeight: 44)
                }
                    .buttonStyle(AeonTransportButtonStyle())
                    .frame(minWidth: AeonTheme.Space.minimumTarget, minHeight: AeonTheme.Space.minimumTarget)
                    .contentShape(Rectangle())
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .accessibilityIdentifier("aeon.album.find-in-sky")
            }
            playlistMenu
                .font(AeonTheme.FontToken.metric(.caption))

        }
        .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
        .frame(maxWidth: .infinity)
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
            HStack(spacing: AeonTheme.Space.small) {
                AeonGlyph(kind: .add)
                Text("ADD TO PLAYLIST")
            }
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
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: AeonTheme.Space.section))
        return layout {
            if !album.year.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadataValue("YEAR", album.year)
            }
            if !album.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                metadataValue("GENRE", album.genre)
            }
            metadataValue("TRACKS", "\(controller.selectedTracks.count)")
        }
        .padding(.vertical, 14)
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
                    Button {
                        // The row itself is the playback affordance: selecting a track starts it.
                        controller.playAlbum(id: album.id, startingTrackID: track.id)
                    } label: {
                        HStack(spacing: AeonTheme.Space.medium) {
                            Text(trackNumber(track, fallback: index + 1))
                                .font(AeonTheme.FontToken.metric(.caption))
                                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                                .frame(width: 28, alignment: .trailing)
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
                            Spacer(minLength: 0)
                            Text(duration(track.duration))
                                .font(AeonTheme.FontToken.metric(.caption2))
                                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("aeon.album.track.play.\(track.id)")
                    TrackActionMenu(
                        track: track,
                        catalog: controller.repository,
                        playback: controller.playback,
                        playFromHere: { controller.playAlbum(id: album.id, startingTrackID: track.id) },
                        showAlbum: { controller.selectAlbum(id: track.albumID) },
                        showArtist: {
                            controller.setQuery(track.artist)
                            controller.dismissAlbum()
                            close()
                        }
                    ) {
                        AeonGlyph(kind: .more)
                            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    }
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    .contentShape(Rectangle())
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
                .frame(minHeight: 62)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
                }
                .accessibilityElement(children: .contain)
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
