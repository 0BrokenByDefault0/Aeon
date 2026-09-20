import SwiftUI

struct SearchResultsView: View {
    @ObservedObject var controller: LibraryController
    let thumbnails: [String: UIImage]

    private var results: CatalogSearchResults { controller.searchResults }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: AeonTheme.Space.large) {
            if results.albums.isEmpty, results.artists.isEmpty, results.tracks.isEmpty {
                AeonEmptyState(
                    title: "No matches",
                    detail: "Try an album, artist, track, or genre.",
                    actionTitle: nil,
                    action: nil
                )
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("aeon.library.search.empty")
            }
            if !results.artists.isEmpty {
                resultSection("ARTISTS") {
                    ForEach(results.artists, id: \.self) { artist in
                        AeonRow(title: artist, detail: "ARTIST")
                    }
                }
            }
            if !results.albums.isEmpty {
                resultSection("ALBUMS") {
                    ForEach(results.albums) { album in
                        Button { controller.selectAlbum(id: album.id) } label: {
                            HStack(spacing: AeonTheme.Space.medium) {
                                AeonArtwork(
                                    image: album.artworkKey.flatMap { thumbnails[$0] }.map(Image.init(uiImage:)),
                                    size: 62
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.title)
                                        .font(AeonTheme.FontToken.ui(.body, weight: .medium))
                                        .foregroundStyle(AeonTheme.ColorToken.bone)
                                    Text(album.artist)
                                        .font(AeonTheme.FontToken.ui(.caption))
                                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                                }
                                Spacer()
                            }
                            .frame(minHeight: 70)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("aeon.library.search.album.\(album.id)")
                    }
                }
            }
            if !results.tracks.isEmpty {
                resultSection("TRACKS") {
                    ForEach(results.tracks) { hit in
                        if let track = try? controller.repository.track(id: hit.trackID) {
                            HStack(spacing: AeonTheme.Space.small) {
                                Button { controller.playAlbum(id: hit.albumID, startingTrackID: hit.trackID) } label: {
                                    AeonRow(
                                        title: hit.trackTitle,
                                        detail: [hit.artist, hit.albumTitle].filter { !$0.isEmpty }.joined(separator: " · ")
                                    ) {
                                        AeonGlyph(kind: .play)
                                            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Play \(hit.trackTitle)")
                                .accessibilityIdentifier("aeon.library.search.track.\(hit.trackID)")
                                TrackActionMenu(
                                    track: track,
                                    catalog: controller.repository,
                                    playback: controller.playback,
                                    showAlbum: { controller.selectAlbum(id: hit.albumID) },
                                    showArtist: { controller.setQuery(hit.artist) }
                                ) {
                                    AeonGlyph(kind: .more)
                                        .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                                }
                                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func resultSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            AeonLabel(text: title)
            content()
        }
    }
}
