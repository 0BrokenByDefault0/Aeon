import SwiftUI

struct LibraryScreen: View {
    @ObservedObject var controller: LibraryController
    let importProgress: LibraryImportProgress?
    let importError: String?
    let importAction: () -> Void
    let findInSky: (String, Bool) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if horizontalSizeClass == .regular, let album = controller.selectedAlbum {
                AlbumDetailView(
                    controller: controller,
                    album: album,
                    embedded: true,
                    close: controller.dismissAlbum,
                    findInSky: { id in findInSky(id, effectiveReduceMotion) }
                )
            } else {
                library
            }
        }
        .sheet(
            isPresented: Binding(
                get: { horizontalSizeClass == .compact && controller.selectedAlbum != nil },
                set: { if !$0 { controller.dismissAlbum() } }
            )
        ) {
            if let album = controller.selectedAlbum {
                AlbumDetailView(
                    controller: controller,
                    album: album,
                    embedded: false,
                    close: controller.dismissAlbum,
                    findInSky: { id in
                        controller.dismissAlbum()
                        findInSky(id, effectiveReduceMotion)
                    }
                )
            }
        }
        .overlay(alignment: .top) {
            if let message = controller.message {
                AeonToast(message: message)
                    .padding(.top, AeonTheme.Space.small)
                    .onTapGesture { controller.clearMessage() }
            }
        }
        .accessibilityIdentifier("aeon.library.screen")
    }

    private var effectiveReduceMotion: Bool {
        reduceMotion || AeonTestOverrides.reduceMotion
    }

    private var library: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AeonTheme.Space.section) {
                    header
                    if let importProgress { importStatus(importProgress) }
                    if let importError, !importError.isEmpty {
                        inlineStatus(importError, symbol: "exclamationmark.triangle")
                    }
                    if let album = controller.continueAlbum {
                        continueListening(album)
                    }
                    controls
                    content(width: geometry.size.width)
                }
                .padding(.horizontal, geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge)
                .padding(.vertical, AeonTheme.Space.edge)
            }
            .scrollIndicators(.hidden)
            .refreshable { controller.reload(reset: true) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            AeonBreadcrumb(text: "Collection")
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    AeonDisplayText("Library", size: 42, maximumLines: 1)
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                    Text("\(controller.totalCount) ALBUM\(controller.totalCount == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .medium))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                        .accessibilityIdentifier("aeon.library.count")
                }
                Spacer()
                Button("IMPORT", action: importAction)
                    .buttonStyle(AeonButtonStyle(tier: .hairline))
                    .accessibilityIdentifier("aeon.library.import")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: AeonTheme.Space.medium) {
            HStack(spacing: AeonTheme.Space.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                TextField(
                    "Search albums, artists, tracks",
                    text: Binding(get: { controller.query }, set: controller.setQuery)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(AeonTheme.ColorToken.bone)
                .accessibilityIdentifier("aeon.library.search")
                if controller.isSearching {
                    Button { controller.setQuery("") } label: {
                        Image(systemName: "xmark")
                            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, AeonTheme.Space.medium)
            .frame(minHeight: AeonTheme.Space.minimumTarget)
            .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))

            HStack(spacing: AeonTheme.Space.medium) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AeonTheme.Space.large) {
                        ForEach(LibraryController.Sort.allCases) { sort in
                            Button(sort.label) { controller.setSort(sort) }
                                .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                                .foregroundStyle(controller.sort == sort ? AeonTheme.ColorToken.bone : AeonTheme.ColorToken.boneSecondary)
                                .frame(minHeight: AeonTheme.Space.minimumTarget)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(controller.sort == sort ? AeonTheme.ColorToken.bone : .clear)
                                        .frame(height: 1)
                                }
                                .accessibilityAddTraits(controller.sort == sort ? .isSelected : [])
                                .accessibilityIdentifier("aeon.library.sort.\(sort.rawValue)")
                        }
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    densityButton(.grid, symbol: "square.grid.2x2")
                    densityButton(.list, symbol: "list.bullet")
                }
            }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch controller.loadState {
        case .loading:
            ProgressView().tint(AeonTheme.ColorToken.bone).frame(maxWidth: .infinity, minHeight: 220)
        case .failed(let detail):
            AeonEmptyState(title: "Library unavailable", detail: detail, actionTitle: "RETRY") {
                controller.reload(reset: true)
            }
            .frame(maxWidth: .infinity)
        case .ready:
            if controller.isSearching {
                SearchResultsView(
                    results: controller.searchResults,
                    thumbnails: controller.thumbnails,
                    selectAlbum: controller.selectAlbum,
                    playTrack: { albumID, trackID in controller.playAlbum(id: albumID, startingTrackID: trackID) }
                )
            } else if controller.albums.isEmpty {
                AeonEmptyState(
                    title: "Your sky is quiet",
                    detail: "Import audio files or a folder to begin charting the collection.",
                    actionTitle: "IMPORT MUSIC",
                    action: importAction
                )
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("aeon.library.empty")
            } else if controller.density == .grid {
                albumGrid(width: width)
            } else {
                albumList
            }
        }
    }

    private func albumGrid(width: CGFloat) -> some View {
        let count = columnCount(for: width)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: AeonTheme.Space.large), count: count),
            spacing: AeonTheme.Space.section
        ) {
            ForEach(controller.albums) { album in
                albumGridCell(album)
                    .onAppear {
                        if album.id == controller.albums.last?.id { controller.loadNextPage() }
                    }
            }
        }
    }

    private var albumList: some View {
        LazyVStack(spacing: 0) {
            ForEach(controller.albums) { album in
                Button { controller.selectAlbum(id: album.id) } label: {
                    HStack(spacing: AeonTheme.Space.medium) {
                        artwork(album, size: 62)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(album.title)
                                .font(AeonTheme.FontToken.ui(.body, weight: .medium))
                                .foregroundStyle(AeonTheme.ColorToken.bone)
                            Text(detailLine(album))
                                .font(AeonTheme.FontToken.metric(.caption2))
                                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                            if let status = controller.status(for: album.id) {
                                AeonLabel(text: status).foregroundStyle(AeonTheme.ColorToken.bone)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                    }
                    .padding(.vertical, AeonTheme.Space.small)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("aeon.library.album.\(album.id)")
                .onAppear {
                    if album.id == controller.albums.last?.id { controller.loadNextPage() }
                }
            }
        }
    }

    private func albumGridCell(_ album: CatalogAlbumSummary) -> some View {
        Button { controller.selectAlbum(id: album.id) } label: {
            VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                GeometryReader { proxy in artwork(album, size: proxy.size.width) }
                    .aspectRatio(1, contentMode: .fit)
                Text(album.title)
                    .font(AeonTheme.FontToken.ui(.callout, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                    .lineLimit(2)
                Text(album.artist)
                    .font(AeonTheme.FontToken.ui(.caption))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .lineLimit(1)
                if let status = controller.status(for: album.id) { AeonLabel(text: status) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aeon.library.album.\(album.id)")
    }

    private func continueListening(_ album: CatalogAlbumSummary) -> some View {
        Button { controller.selectAlbum(id: album.id) } label: {
            AeonGlass {
                HStack(spacing: AeonTheme.Space.large) {
                    artwork(album, size: 76)
                    VStack(alignment: .leading, spacing: 5) {
                        AeonLabel(text: "Continue listening")
                        Text(album.title)
                            .font(AeonTheme.FontToken.ui(.headline, weight: .semibold))
                            .foregroundStyle(AeonTheme.ColorToken.bone)
                        Text(album.artist)
                            .font(AeonTheme.FontToken.ui(.caption))
                            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                }
                .padding(AeonTheme.Space.medium)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aeon.library.continue")
    }

    private func importStatus(_ progress: LibraryImportProgress) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            AeonLabel(text: "Import in progress")
            AeonProgressBar(value: progress.totalFiles == 0 ? 0 : Double(progress.completedFiles) / Double(progress.totalFiles))
            Text("\(progress.completedFiles) of \(progress.totalFiles) files")
                .font(AeonTheme.FontToken.metric(.caption2))
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        }
        .accessibilityIdentifier("aeon.library.import.progress")
    }

    private func inlineStatus(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: AeonTheme.Space.medium) {
            Image(systemName: symbol)
            Text(text).font(AeonTheme.FontToken.ui(.callout))
        }
        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        .padding(AeonTheme.Space.medium)
        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
    }

    private func densityButton(_ density: LibraryController.Density, symbol: String) -> some View {
        Button { controller.setDensity(density) } label: {
            Image(systemName: symbol)
                .foregroundStyle(controller.density == density ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.boneSecondary)
                .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                .background(controller.density == density ? AeonTheme.ColorToken.bone : .clear)
                .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(density.label.capitalized) view")
        .accessibilityAddTraits(controller.density == density ? .isSelected : [])
        .accessibilityIdentifier("aeon.library.density.\(density.rawValue)")
    }

    private func artwork(_ album: CatalogAlbumSummary, size: CGFloat) -> some View {
        let image = album.artworkKey.flatMap { controller.thumbnails[$0] }.map(Image.init(uiImage:))
        return AeonArtwork(image: image, size: size)
    }

    private func detailLine(_ album: CatalogAlbumSummary) -> String {
        [album.artist, album.year.isEmpty ? nil : album.year, "\(album.trackCount) TRACKS"]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func columnCount(for width: CGFloat) -> Int {
        let available = width - AeonTheme.Space.edge * 2
        for columns in [5, 4, 3] {
            let item = (available - CGFloat(columns - 1) * AeonTheme.Space.large) / CGFloat(columns)
            if width >= CGFloat(columns == 3 ? 600 : columns == 4 ? 768 : 1_100), item >= 142 { return columns }
        }
        return 2
    }
}
