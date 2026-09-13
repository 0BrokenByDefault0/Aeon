import SwiftUI

struct SearchResultsView: View {
    let results: CatalogSearchResults
    let thumbnails: [String: UIImage]
    let selectAlbum: (String) -> Void
    let playTrack: (String, String) -> Void

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
                        Button { selectAlbum(album.id) } label: {
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
                    ForEach(results.tracks) { track in
                        Button { playTrack(track.albumID, track.trackID) } label: {
                            AeonRow(
                                title: track.trackTitle,
                                detail: [track.artist, track.albumTitle].filter { !$0.isEmpty }.joined(separator: " · ")
                            ) {
                                Image(systemName: "play.fill")
                                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(track.trackTitle)")
                        .accessibilityIdentifier("aeon.library.search.track.\(track.trackID)")
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
