import SwiftUI

struct LibraryScreen: View {
    @ObservedObject var controller: LibraryController
    let importProgress: LibraryImportProgress?
    let importError: String?
    let importFiles: () -> Void
    let importFolder: () -> Void
    let findInSky: (String, Bool) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.aeonReadableInsets) private var readableInsets
    @State private var importSheetPresented = false
    var body: some View {
        Group {
            if horizontalSizeClass == .regular, let album = controller.selectedAlbum {
                AlbumDetailView(controller: controller, album: album, embedded: true, close: controller.dismissAlbum,
                                findInSky: { id in findInSky(id, effectiveReduceMotion) })
            } else { library }
        }
        .sheet(isPresented: Binding(get: { horizontalSizeClass == .compact && controller.selectedAlbum != nil },
                                    set: { if !$0 { controller.dismissAlbum() } })) {
            if let album = controller.selectedAlbum {
                AlbumDetailView(controller: controller, album: album, embedded: false, close: controller.dismissAlbum,
                                findInSky: { id in controller.dismissAlbum(); findInSky(id, effectiveReduceMotion) })
            }
        }
        .sheet(isPresented: $importSheetPresented) { AeonImportSheet(selectFiles: importFiles, selectFolder: importFolder) }
        .overlay(alignment: .top) {
            if let message = controller.message {
                AeonToast(message: message).padding(.top, AeonTheme.Space.small).onTapGesture { controller.clearMessage() }
            }
        }
        .accessibilityIdentifier("aeon.library.screen")
    }
    private var effectiveReduceMotion: Bool { reduceMotion || AeonTestOverrides.reduceMotion }
    private var hasLibraryContent: Bool { controller.totalCount > 0 || !controller.albums.isEmpty }
    private var library: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AeonTheme.Space.section) {
                    header
                    if let importProgress { importStatus(importProgress) }
                    if let importError, !importError.isEmpty { inlineStatus(importError, symbol: "exclamationmark.triangle") }
                    if let album = controller.continueAlbum, hasLibraryContent { continueListening(album) }
                    if hasLibraryContent { controls }
                    content(width: geometry.size.width)
                }
                .padding(.horizontal, geometry.size.width < 360 ? AeonTheme.Space.compactEdge : AeonTheme.Space.edge)
                .padding(.vertical, AeonTheme.Space.edge)
                .padding(.bottom, horizontalSizeClass == .compact ? readableInsets.bottom : 0)
            }
            .scrollIndicators(.hidden).refreshable { controller.reload(reset: true) }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            AeonBreadcrumb(text: "Library")
            HStack(alignment: .bottom, spacing: AeonTheme.Space.regular) {
                VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                    AeonDisplayText("Library", size: 42, maximumLines: 1).foregroundStyle(AeonOrbit.title)
                    Text("\(controller.totalCount) ALBUM\(controller.totalCount == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .medium)).foregroundStyle(AeonOrbit.secondary)
                        .accessibilityIdentifier("aeon.library.count")
                }
                Spacer(minLength: 0)
                // Import remains available here, but Sky owns the empty-library primary action.
                Button { importSheetPresented = true } label: {
                    HStack(spacing: 6) {
                        Text("IMPORT").font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
                        AeonGlyph(kind: .arrow)
                    }
                    .foregroundStyle(AeonOrbit.ink).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Import music").accessibilityIdentifier("aeon.library.import")
            }
        }
    }
    private var controls: some View {
        VStack(spacing: AeonTheme.Space.regular) {
            HStack(spacing: AeonTheme.Space.small) {
                Image(systemName: "magnifyingglass").foregroundStyle(AeonOrbit.secondary)
                TextField("Search albums, artists, tracks", text: Binding(get: { controller.query }, set: controller.setQuery))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(AeonTheme.FontToken.ui(.callout)).foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    .accessibilityIdentifier("aeon.library.search")
                if controller.isSearching {
                    Button { controller.setQuery("") } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, AeonTheme.Space.regular).frame(minHeight: 48)
            .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
            HStack(spacing: AeonTheme.Space.medium) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AeonTheme.Space.large) {
                        ForEach(LibraryController.Sort.allCases) { sort in
                            Button(sort.label) { controller.setSort(sort) }
                                .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                                .foregroundStyle(controller.sort == sort ? AeonOrbit.ink : AeonOrbit.secondary)
                                .frame(minHeight: 44)
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(controller.sort == sort ? AeonOrbit.ink : .clear).frame(height: AeonOrbit.stroke)
                                }
                                .accessibilityAddTraits(controller.sort == sort ? .isSelected : [])
                                .accessibilityIdentifier("aeon.library.sort.\(sort.rawValue)")
                        }
                    }
                }
                HStack(spacing: AeonTheme.Space.xSmall) {
                    densityButton(.grid, glyph: .library)
                    densityButton(.list, glyph: .files)
                }
            }
        }
    }
    @ViewBuilder private func content(width: CGFloat) -> some View {
        switch controller.loadState {
        case .loading:
            ProgressView().tint(AeonOrbit.ink).frame(maxWidth: .infinity, minHeight: 220)
        case .failed(let detail):
            AeonEmptyState(title: "Library unavailable", detail: detail, actionTitle: "RETRY") { controller.reload(reset: true) }
                .frame(maxWidth: .infinity)
        case .ready:
            if controller.isSearching {
                SearchResultsView(results: controller.searchResults, thumbnails: controller.thumbnails,
                                  selectAlbum: controller.selectAlbum,
                                  playTrack: { albumID, trackID in controller.playAlbum(id: albumID, startingTrackID: trackID) })
            } else if controller.albums.isEmpty { emptyLibrary }
            else if controller.density == .grid { regionShelves(width: width) }
            else { albumList }
        }
    }
    private var emptyLibrary: some View {
        VStack(spacing: AeonTheme.Space.large) {
            AeonCollectionMark()
            VStack(spacing: AeonTheme.Space.regular) {
                AeonDisplayText("Your collection starts here.", size: 28, maximumLines: 2)
                    .foregroundStyle(AeonOrbit.title).multilineTextAlignment(.center)
                Text("The records you bring into Aeon live here.\nYours to browse, play, and return to.")
                    .font(AeonTheme.FontToken.ui(.callout)).foregroundStyle(AeonOrbit.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280).padding(.vertical, AeonTheme.Space.hero)
        .accessibilityIdentifier("aeon.library.empty")
    }

    private struct RegionShelf: Identifiable {
        let id: String
        let title: String
        var albums: [CatalogAlbumSummary]
    }
    private var shelves: [RegionShelf] {
        let catalogue = controller.skyController.catalogue
        let stars = Dictionary(uniqueKeysWithValues: catalogue.stars.map { ($0.albumID, $0.regionID) })
        let names = Dictionary(uniqueKeysWithValues: catalogue.regions.map { ($0.id, $0.name) })
        var result: [RegionShelf] = []
        for album in controller.albums {
            let regionID = stars[album.id] ?? "uncharted"
            if let index = result.firstIndex(where: { $0.id == regionID }) { result[index].albums.append(album) }
            else { result.append(RegionShelf(id: regionID, title: names[regionID] ?? "Uncharted", albums: [album])) }
        }
        return result
    }
    private func regionShelves(width: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: AeonTheme.Space.section) {
            ForEach(shelves) { shelf in
                VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
                    AeonBreadcrumb(text: shelf.title)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: AeonTheme.Space.large) {
                            ForEach(shelf.albums) { album in
                                albumGridCell(album).frame(width: width >= 700 ? 174 : 146)
                                    .onAppear { if album.id == controller.albums.last?.id { controller.loadNextPage() } }
                            }
                        }.padding(.vertical, 2)
                    }
                }
            }
            if controller.hasMore {
                Button("LOAD MORE ALBUMS") { controller.loadNextPage() }.buttonStyle(AeonButtonStyle(tier: .bare))
            }
        }
    }
    private var albumList: some View {
        LazyVStack(spacing: 0) {
            ForEach(controller.albums) { album in
                Button { controller.selectAlbum(id: album.id) } label: {
                    HStack(spacing: AeonTheme.Space.regular) {
                        artwork(album, size: 62)
                        VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                            Text(album.title).font(AeonTheme.FontToken.ui(.callout, weight: .medium)).foregroundStyle(AeonTheme.ColorToken.textPrimary)
                            Text(detailLine(album)).font(AeonTheme.FontToken.metric(.caption2)).foregroundStyle(AeonOrbit.secondary)
                            if let status = controller.status(for: album.id) { AeonLabel(text: status) }
                        }
                        Spacer()
                        AeonGlyph(kind: .arrow).foregroundStyle(AeonOrbit.secondary)
                    }
                    .padding(.vertical, AeonTheme.Space.small).contentShape(Rectangle())
                    .overlay(alignment: .bottom) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
                }
                .buttonStyle(.plain).accessibilityIdentifier("aeon.library.album.\(album.id)")
                .onAppear { if album.id == controller.albums.last?.id { controller.loadNextPage() } }
            }
        }
    }
    private func albumGridCell(_ album: CatalogAlbumSummary) -> some View {
        Button { controller.selectAlbum(id: album.id) } label: {
            VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                GeometryReader { proxy in artwork(album, size: proxy.size.width) }.aspectRatio(1, contentMode: .fit)
                Text(album.title).font(AeonTheme.FontToken.ui(.callout, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary).lineLimit(2)
                Text(album.artist).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary).lineLimit(1)
                if let status = controller.status(for: album.id) { AeonLabel(text: status) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("aeon.library.album.\(album.id)")
    }
    private func continueListening(_ album: CatalogAlbumSummary) -> some View {
        Button { controller.selectAlbum(id: album.id) } label: {
            HStack(spacing: AeonTheme.Space.large) {
                artwork(album, size: 76)
                VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                    AeonLabel(text: "Continue listening")
                    Text(album.title).font(AeonTheme.FontToken.ui(.headline, weight: .semibold)).foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    Text(album.artist).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
                }
                Spacer()
                AeonGlyph(kind: .arrow).foregroundStyle(AeonOrbit.ink)
            }
            .padding(.vertical, AeonTheme.Space.regular).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
        }
        .buttonStyle(.plain).accessibilityIdentifier("aeon.library.continue")
    }
    private func importStatus(_ progress: LibraryImportProgress) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            AeonLabel(text: "Import in progress")
            AeonProgressBar(value: progress.totalFiles == 0 ? 0 : Double(progress.completedFiles) / Double(progress.totalFiles))
            Text("\(progress.completedFiles) of \(progress.totalFiles) files")
                .font(AeonTheme.FontToken.metric(.caption2)).foregroundStyle(AeonOrbit.secondary)
        }.accessibilityIdentifier("aeon.library.import.progress")
    }
    private func inlineStatus(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: AeonTheme.Space.medium) {
            Image(systemName: symbol)
            Text(text).font(AeonTheme.FontToken.ui(.callout))
        }
        .foregroundStyle(AeonOrbit.secondary).padding(AeonTheme.Space.regular)
        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
    }
    private func densityButton(_ density: LibraryController.Density, glyph: AeonGlyphKind) -> some View {
        Button { controller.setDensity(density) } label: {
            AeonGlyph(kind: glyph).foregroundStyle(controller.density == density ? AeonOrbit.ink : AeonOrbit.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Rectangle().fill(controller.density == density ? AeonOrbit.ink : .clear).frame(height: AeonOrbit.stroke)
                }
        }
        .buttonStyle(.plain).accessibilityLabel("\(density.label.capitalized) view")
        .accessibilityAddTraits(controller.density == density ? .isSelected : [])
        .accessibilityIdentifier("aeon.library.density.\(density.rawValue)")
    }
    private func artwork(_ album: CatalogAlbumSummary, size: CGFloat) -> some View {
        let image = album.artworkKey.flatMap { controller.thumbnails[$0] }.map(Image.init(uiImage:))
        return AeonArtwork(image: image, size: size)
    }
    private func detailLine(_ album: CatalogAlbumSummary) -> String {
        [album.artist, album.year.isEmpty ? nil : album.year, "\(album.trackCount) TRACKS"].compactMap { $0 }.joined(separator: " · ")
    }
}
