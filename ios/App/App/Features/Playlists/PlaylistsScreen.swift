import SwiftUI

struct PlaylistsScreen: View {
    @ObservedObject var controller: PlaylistsController
    let contentBottomInset: CGFloat
    @State private var creationPresented = false
    @State private var detailPresented = false
    @State private var name = ""
    init(controller: PlaylistsController, contentBottomInset: CGFloat = 0) {
        self.controller = controller; self.contentBottomInset = contentBottomInset
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    header
                    if controller.playlists.isEmpty {
                        VStack(spacing: AeonTheme.Space.large) {
                            AeonEmptyState(title: "No routes charted yet.",
                                           detail: "Build a route through the records you return to.", actionTitle: nil, action: nil)
                            Button("CREATE PLAYLIST") { creationPresented = true }
                                .buttonStyle(AeonButtonStyle(tier: .filled)).frame(maxWidth: 320)
                                .accessibilityIdentifier("aeon.playlists.create")
                        }
                        .frame(maxWidth: 440).frame(maxWidth: .infinity)
                        .frame(minHeight: max(0, geometry.size.height - contentBottomInset - 200))
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
                            AeonBreadcrumb(text: "New playlist")
                            AeonDisplayText("Chart a playlist", size: 32, maximumLines: 2).foregroundStyle(AeonOrbit.title)
                            Text("Give this route a name. Tracks can be added from albums afterward.")
                                .font(AeonTheme.FontToken.ui(.callout)).foregroundStyle(AeonOrbit.secondary)
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
            PlaylistDetailView(controller: controller, close: { detailPresented = false })
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
                AeonBreadcrumb(text: "Playlists")
                AeonDisplayText("Playlists", size: 42, maximumLines: 1).foregroundStyle(AeonOrbit.title)
                    .accessibilityIdentifier("aeon.playlists.screen")
                if !controller.playlists.isEmpty {
                    Text("\(controller.playlists.count) ROUTE\(controller.playlists.count == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .medium)).tracking(1.2).foregroundStyle(AeonOrbit.secondary)
                }
            }
            Spacer()
            if !controller.playlists.isEmpty {
                Button { creationPresented = true } label: {
                    HStack { Text("NEW").font(AeonTheme.FontToken.metric(.caption2)); AeonGlyph(kind: .arrow) }
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
                    Text(overview.playlist.name).font(AeonTheme.FontToken.ui(.callout, weight: .semibold))
                        .foregroundStyle(AeonTheme.ColorToken.textPrimary).lineLimit(2)
                    Text("\(overview.itemCount) TRACK\(overview.itemCount == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption2, weight: .medium)).tracking(1.2).foregroundStyle(AeonOrbit.secondary)
                }
                Spacer()
                AeonGlyph(kind: .arrow).foregroundStyle(AeonOrbit.secondary)
            }
            .padding(.vertical, AeonTheme.Space.medium).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
        }
        .buttonStyle(.plain).accessibilityIdentifier("aeon.playlists.row.\(overview.id)")
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
    @State private var deleteConfirmation = false
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
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    AeonBreadcrumb(text: "Playlist")
                    AeonDisplayText(controller.selectedPlaylist?.name ?? "Route", size: 34, maximumLines: 2).foregroundStyle(AeonOrbit.title)
                    AeonLabel(text: "\(controller.selectedItems.count) tracks")
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Close Playlist").accessibilityIdentifier("aeon.playlists.detail.close")
            }
            HStack(spacing: AeonTheme.Space.medium) {
                Button("PLAY") { controller.play() }.buttonStyle(AeonButtonStyle(tier: .filled))
                    .disabled(controller.selectedItems.isEmpty).accessibilityIdentifier("aeon.playlists.detail.play")
                Button("DELETE") { deleteConfirmation = true }.buttonStyle(AeonButtonStyle(tier: .bare, destructive: true))
                    .accessibilityIdentifier("aeon.playlists.detail.delete")
            }
        }
    }
    private func trackRow(_ route: PlaylistRouteItem, index: Int) -> some View {
        AeonRow(title: route.item.trackTitle,
                detail: route.unavailable ? "FILE UNAVAILABLE · \(route.item.artist) · \(route.item.albumTitle)"
                    : "\(route.item.artist) · \(route.item.albumTitle)") {
            Menu {
                Button("PLAY FROM HERE") { controller.play(startingAt: index) }.disabled(route.unavailable)
                Button("REMOVE", role: .destructive) { controller.remove(position: index) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(AeonOrbit.secondary)
            }.accessibilityLabel("Actions for \(route.item.trackTitle)")
        }
    }
}
