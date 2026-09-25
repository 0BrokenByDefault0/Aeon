import SwiftUI

struct PlaylistsScreen: View {
    @ObservedObject var controller: PlaylistsController
    let contentBottomInset: CGFloat
    let showAlbum: (String) -> Void
    let showArtist: (String) -> Void
    @State private var creationPresented = false
    @State private var detailPresented = false
    @State private var name = ""
    init(
        controller: PlaylistsController,
        contentBottomInset: CGFloat = 0,
        showAlbum: @escaping (String) -> Void = { _ in },
        showArtist: @escaping (String) -> Void = { _ in }
    ) {
        self.controller = controller
        self.contentBottomInset = contentBottomInset
        self.showAlbum = showAlbum
        self.showArtist = showArtist
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    header
                    if !controller.smartRoutes.isEmpty {
                        LazyVStack(spacing: 0) { ForEach(controller.smartRoutes) { smartRow($0) } }
                    }
                    if controller.playlists.isEmpty {
                        AeonEmptyState(title: "No routes charted yet.",
                                       detail: "Build a route through the records you return to.",
                                       actionTitle: "CREATE PLAYLIST", motif: .route,
                                       actionIdentifier: "aeon.playlists.create") { creationPresented = true }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: controller.smartRoutes.isEmpty
                               ? max(0, geometry.size.height - contentBottomInset - 200) : 0)
                    } else {
                        LazyVStack(spacing: 0) { ForEach(controller.playlists) { playlistRow($0) } }
                    }
                }
                .padding(.horizontal, AeonTheme.Space.edge).padding(.top, AeonTheme.Space.medium)
                .padding(.bottom, contentBottomInset + AeonTheme.Space.edge)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $creationPresented) {
            AeonSheet {
                ScrollView {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                        VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
                            AeonDisplayText("Chart a playlist", size: 32, maximumLines: 2).foregroundStyle(AeonOrbit.title)
                            Text("Give this route a name. Tracks can be added from albums afterward.")
                                .font(AeonOrbit.supportingFont).foregroundStyle(AeonOrbit.secondary)
                        }
                        createForm
                        Button("CANCEL") { creationPresented = false }.buttonStyle(AeonButtonStyle(tier: .bare))
                    }
                    .padding(AeonTheme.Space.edge).foregroundStyle(AeonOrbit.ink)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $detailPresented, onDismiss: controller.dismissSelection) {
            PlaylistDetailView(
                controller: controller,
                close: { detailPresented = false },
                showAlbum: { id in detailPresented = false; showAlbum(id) },
                showArtist: { artist in detailPresented = false; showArtist(artist) }
            )
        }
        .overlay(alignment: .bottom) {
            if let message = controller.message {
                AeonToast(message: message).padding(AeonTheme.Space.edge).padding(.bottom, contentBottomInset)
                    .task {
                        try? await Task.sleep(nanoseconds: UInt64(AeonTheme.Duration.toast * 1_000_000_000))
                        controller.clearMessage()
                    }
            }
        }
    }
    private var header: some View {
        HStack(alignment: .bottom, spacing: AeonTheme.Space.medium) {
            VStack(alignment: .leading, spacing: 4) {
                AeonDisplayText("Playlists", size: 42, maximumLines: 1).foregroundStyle(AeonOrbit.title)
                    .accessibilityIdentifier("aeon.playlists.screen")
                if !controller.playlists.isEmpty {
                    Text("\(controller.playlists.count) ROUTE\(controller.playlists.count == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .medium)).tracking(1.2).foregroundStyle(AeonOrbit.secondary)
                }
            }
            Spacer()
            if controller.playlistsFolder != nil {
                Button { Task { await controller.importPlaylistFiles() } } label: {
                    HStack { Text("M3U").font(AeonTheme.FontToken.metric(.caption2)); AeonGlyph(kind: .picker) }
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(AeonOrbit.ink)
                .disabled(controller.isImporting)
                .accessibilityLabel(controller.isImporting ? "Importing Playlists" : "Import Playlists from Files").accessibilityIdentifier("aeon.playlists.import")
            }
            if !controller.playlists.isEmpty {
                Button { creationPresented = true } label: {
                    HStack { Text("NEW").font(AeonTheme.FontToken.metric(.caption2)); AeonGlyph(kind: .add) }
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(AeonOrbit.ink)
                .accessibilityLabel("Create Playlist").accessibilityIdentifier("aeon.playlists.create")
            }
        }
    }
    private func playlistRow(_ overview: PlaylistOverview) -> some View {
        Button { controller.select(id: overview.id); detailPresented = controller.selectedPlaylist != nil } label: {
            HStack(spacing: AeonTheme.Space.large) {
                AeonRouteMark(width: 62, height: 48).frame(width: 68, height: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text(overview.playlist.name).font(AeonTheme.FontToken.ui(.callout, weight: .regular))
                        .foregroundStyle(AeonTheme.ColorToken.textPrimary).lineLimit(2)
                    Text("\(overview.itemCount) TRACK\(overview.itemCount == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption2, weight: .medium)).tracking(1.2).foregroundStyle(AeonOrbit.secondary)
                }
                Spacer()
                AeonGlyph(kind: .disclosure).foregroundStyle(AeonOrbit.secondary)
            }
            .padding(.vertical, AeonTheme.Space.medium).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
        }
        .buttonStyle(.plain).accessibilityIdentifier("aeon.playlists.row.\(overview.id)")
    }
    private func smartRow(_ overview: SmartRouteOverview) -> some View {
        Button { controller.select(smart: overview.route); detailPresented = controller.selectedSmartRoute != nil } label: {
            HStack(spacing: AeonTheme.Space.large) {
                AeonGlyph(kind: overview.route == .favourites ? .star : .play)
                    .foregroundStyle(AeonOrbit.secondary).frame(width: 68, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(overview.route.title).font(AeonTheme.FontToken.ui(.callout, weight: .regular))
                        .foregroundStyle(AeonTheme.ColorToken.textPrimary).lineLimit(2)
                    Text("\(overview.itemCount) TRACK\(overview.itemCount == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption2, weight: .medium)).tracking(1.2).foregroundStyle(AeonOrbit.secondary)
                }
                Spacer()
                AeonGlyph(kind: .disclosure).foregroundStyle(AeonOrbit.secondary)
            }
            .padding(.vertical, AeonTheme.Space.medium).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
        }
        .buttonStyle(.plain).accessibilityIdentifier("aeon.playlists.smart.\(overview.route.rawValue)")
    }
    private var createForm: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            TextField("Playlist name", text: $name).textInputAutocapitalization(.words).submitLabel(.done)
                .padding(.horizontal, AeonTheme.Space.regular).frame(minHeight: AeonTheme.Space.minimumTarget)
                .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
                .accessibilityIdentifier("aeon.playlists.name").onSubmit(create)
            Button("CREATE", action: create).buttonStyle(AeonButtonStyle(tier: .filled))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("aeon.playlists.commit-create")
        }
    }
    private func create() {
        if controller.create(name: name) { name = ""; creationPresented = false }
    }
}

private struct PlaylistDetailView: View {
    @ObservedObject var controller: PlaylistsController
    let close: () -> Void
    let showAlbum: (String) -> Void
    let showArtist: (String) -> Void
    @State private var deleteConfirmation = false
    @State private var renamePresented = false
    @State private var reorderPresented = false
    var body: some View {
        AeonSheet {
            ScrollView {
                VStack(spacing: AeonTheme.Space.large) {
                    header
                    if controller.selectedItems.isEmpty {
                        AeonEmptyState(title: "Empty route.", detail: "Add tracks from an album to begin shaping this playlist.",
                                       actionTitle: nil, action: nil).frame(maxWidth: 440).frame(maxWidth: .infinity)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(controller.selectedItems.enumerated()), id: \.element.id) { index, route in
                                trackRow(route, index: index)
                            }
                        }
                    }
                }
                .padding(.horizontal, AeonTheme.Space.edge).padding(.bottom, AeonTheme.Space.edge).foregroundStyle(AeonOrbit.ink)
            }
        }
        .presentationDetents([.medium, .large])
        .alert("Delete playlist?", isPresented: $deleteConfirmation) {
            Button("Delete Playlist", role: .destructive) { if controller.deleteSelected() { close() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Tracks stay in the library.") }
        .sheet(isPresented: $renamePresented) { PlaylistRenameView(controller: controller) }
        .sheet(isPresented: $reorderPresented) { PlaylistReorderView(controller: controller) }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    AeonDisplayText(controller.selectionTitle, size: 34, maximumLines: 2).foregroundStyle(AeonOrbit.title)
                    AeonLabel(text: "\(controller.selectedItems.count) tracks")
                }
                Spacer()
                Menu {
                    if controller.selectionIsEditable {
                        Button("RENAME") { renamePresented = true }
                        Button("REORDER") { reorderPresented = true }.disabled(controller.selectedItems.count < 2)
                    }
                    if controller.playlistsFolder != nil {
                        Button("EXPORT M3U") { controller.exportSelected() }.disabled(controller.selectedItems.isEmpty)
                    }
                } label: { AeonGlyph(kind: .more).frame(width: 44, height: 44) }
                .accessibilityLabel("Playlist Actions").accessibilityIdentifier("aeon.playlists.detail.actions")
                Button(action: close) { AeonGlyph(kind: .close).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Close Playlist").accessibilityIdentifier("aeon.playlists.detail.close")
            }
            HStack(spacing: AeonTheme.Space.medium) {
                Button("PLAY") { controller.play() }.buttonStyle(AeonButtonStyle(tier: .filled))
                    .disabled(controller.selectedItems.isEmpty).accessibilityIdentifier("aeon.playlists.detail.play")
                if controller.selectionIsEditable {
                    Button("DELETE") { deleteConfirmation = true }.buttonStyle(AeonButtonStyle(tier: .bare, destructive: true))
                        .accessibilityIdentifier("aeon.playlists.detail.delete")
                }
            }
        }
    }
    private func trackRow(_ route: PlaylistRouteItem, index: Int) -> some View {
        AeonRow(
            title: route.item.trackTitle,
            detail: route.unavailable ? "FILE UNAVAILABLE · \(route.item.artist) · \(route.item.albumTitle)"
                : "\(route.item.artist) · \(route.item.albumTitle)"
        ) {
            if let track = try? controller.repository.track(id: route.item.trackID) {
                TrackActionMenu(
                    track: track,
                    catalog: controller.repository,
                    playback: controller.playback,
                    playFromHere: route.unavailable ? nil : { controller.play(startingAt: index) },
                    showAlbum: { showAlbum(route.item.albumID) },
                    showArtist: { showArtist(route.item.artist) },
                    removeTitle: controller.selectedSmartRoute == .favourites ? "REMOVE FROM FAVOURITES" : "REMOVE FROM PLAYLIST",
                    remove: controller.selectionIsEditable || controller.selectedSmartRoute == .favourites
                        ? { controller.remove(position: index) } : nil
                ) {
                    AeonGlyph(kind: .more).frame(width: 44, height: 44)
                }
                .foregroundStyle(AeonOrbit.secondary)
            }
        }
    }
}

private struct PlaylistRenameView: View {
    @ObservedObject var controller: PlaylistsController
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        AeonSheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    AeonDisplayText("Rename playlist", size: 32, maximumLines: 2).foregroundStyle(AeonOrbit.title)
                    TextField("Playlist name", text: $name).textInputAutocapitalization(.words).submitLabel(.done)
                        .padding(.horizontal, AeonTheme.Space.regular).frame(minHeight: AeonTheme.Space.minimumTarget)
                        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
                        .accessibilityIdentifier("aeon.playlists.rename.name").onSubmit(save)
                    Button("SAVE", action: save).buttonStyle(AeonButtonStyle(tier: .filled))
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("aeon.playlists.rename.commit")
                    Button("CANCEL") { dismiss() }.buttonStyle(AeonButtonStyle(tier: .bare))
                }
                .padding(AeonTheme.Space.edge).foregroundStyle(AeonOrbit.ink)
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { name = controller.selectedPlaylist?.name ?? "" }
    }
    private func save() {
        if controller.renameSelected(to: name) { dismiss() }
    }
}

/// Drag handles come from the system list in edit mode, so VoiceOver users get the
/// standard move actions rather than a custom gesture.
private struct PlaylistReorderView: View {
    @ObservedObject var controller: PlaylistsController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        AeonSheet {
            VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
                HStack(alignment: .top) {
                    AeonDisplayText("Reorder route", size: 32, maximumLines: 2).foregroundStyle(AeonOrbit.title)
                    Spacer()
                    Button("DONE") { dismiss() }.buttonStyle(AeonButtonStyle(tier: .bare))
                        .accessibilityIdentifier("aeon.playlists.reorder.done")
                }
                List {
                    ForEach(controller.selectedItems) { route in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(route.item.trackTitle).font(AeonTheme.FontToken.ui(.callout))
                                .foregroundStyle(AeonTheme.ColorToken.textPrimary).lineLimit(2)
                            Text("\(route.item.artist) \u{00b7} \(route.item.albumTitle)").font(AeonTheme.FontToken.ui(.caption))
                                .foregroundStyle(AeonOrbit.secondary).lineLimit(1)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in controller.moveItems(fromOffsets: source, toOffset: destination) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
                .accessibilityIdentifier("aeon.playlists.reorder.list")
            }
            .padding(AeonTheme.Space.edge).foregroundStyle(AeonOrbit.ink)
        }
        .presentationDetents([.large])
    }
}
