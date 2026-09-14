import SwiftUI

struct PlaylistsScreen: View {
    @ObservedObject var controller: PlaylistsController
    let contentBottomInset: CGFloat
    @State private var creationPresented = false
    @State private var detailPresented = false
    @State private var name = ""

    init(controller: PlaylistsController, contentBottomInset: CGFloat = 0) {
        self.controller = controller
        self.contentBottomInset = contentBottomInset
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, AeonTheme.Space.large)

            if controller.playlists.isEmpty {
                Spacer(minLength: AeonTheme.Space.section)
                AeonEmptyState(
                    title: "No routes charted yet.",
                    detail: "Build a route through the records you return to.",
                    actionTitle: "CREATE PLAYLIST",
                    action: { creationPresented = true }
                )
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                Spacer(minLength: AeonTheme.Space.section)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.playlists) { overview in
                            playlistRow(overview)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, AeonTheme.Space.edge)
        .padding(.top, AeonTheme.Space.medium)
        .padding(.bottom, contentBottomInset + AeonTheme.Space.edge)
        .sheet(isPresented: $creationPresented) {
            AeonSheet {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                        AeonLabel(text: "New route")
                        AeonDisplayText("Chart a playlist", size: 32, maximumLines: 2)
                            .foregroundStyle(AeonTheme.ColorToken.bone)
                        Text("Give this route a name. Tracks can be added from albums afterward.")
                            .font(AeonTheme.FontToken.ui(.callout))
                            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    }
                    createForm
                    Button("CANCEL") { creationPresented = false }
                        .buttonStyle(AeonButtonStyle(tier: .bare))
                }
                .padding(AeonTheme.Space.edge)
                .foregroundStyle(AeonTheme.ColorToken.bone)
            }
            .presentationDetents([.height(310)])
        }
        .sheet(isPresented: $detailPresented, onDismiss: controller.dismissSelection) {
            PlaylistDetailView(controller: controller, close: { detailPresented = false })
        }
        .overlay(alignment: .bottom) {
            if let message = controller.message {
                AeonToast(message: message)
                    .padding(AeonTheme.Space.edge)
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
                AeonBreadcrumb(text: "Routes")
                AeonDisplayText("Playlists", size: 42, maximumLines: 1)
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                    .accessibilityIdentifier("aeon.playlists.screen")
                if !controller.playlists.isEmpty {
                    Text("\(controller.playlists.count) ROUTE\(controller.playlists.count == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
            }
            Spacer()
            if !controller.playlists.isEmpty {
                Button { creationPresented = true } label: {
                    Label("NEW", systemImage: "plus")
                }
                .buttonStyle(AeonButtonStyle(tier: .hairline))
                .accessibilityLabel("Create Playlist")
                .accessibilityIdentifier("aeon.playlists.create")
            }
        }
    }

    private func playlistRow(_ overview: PlaylistOverview) -> some View {
        Button {
            controller.select(id: overview.id)
            detailPresented = controller.selectedPlaylist != nil
        } label: {
            HStack(spacing: AeonTheme.Space.large) {
                ZStack {
                    RoundedRectangle(cornerRadius: AeonTheme.Radius.compact, style: .continuous)
                        .fill(AeonTheme.ColorToken.surfaceSelected.opacity(0.56))
                    AeonRouteMark().frame(width: 48, height: 34)
                }
                .frame(width: 68, height: 58)
                VStack(alignment: .leading, spacing: 5) {
                    AeonDisplayText(overview.playlist.name, size: 24, maximumLines: 2)
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                    Text("\(overview.itemCount) TRACK\(overview.itemCount == 1 ? "" : "S")")
                        .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
                        .tracking(1.2)
                        .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
            }
            .padding(.vertical, AeonTheme.Space.medium)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("aeon.playlists.row.\(overview.id)")
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            TextField("Playlist name", text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding(.horizontal, AeonTheme.Space.regular)
                .frame(minHeight: AeonTheme.Space.minimumTarget)
                .background(
                    RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                        .fill(AeonTheme.ColorToken.surfaceSelected.opacity(0.54))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                        .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
                )
                .accessibilityIdentifier("aeon.playlists.name")
                .onSubmit(create)
            Button("CREATE", action: create)
                .buttonStyle(AeonButtonStyle(tier: .filled))
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("aeon.playlists.commit-create")
        }
    }

    private func create() {
        if controller.create(name: name) {
            name = ""
            creationPresented = false
        }
    }
}

private struct PlaylistDetailView: View {
    @ObservedObject var controller: PlaylistsController
    let close: () -> Void
    @State private var deleteConfirmation = false

    var body: some View {
        AeonSheet {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, AeonTheme.Space.edge)
                    .padding(.bottom, AeonTheme.Space.large)

                if controller.selectedItems.isEmpty {
                    AeonEmptyState(
                        title: "Empty route.",
                        detail: "Add tracks from an album to begin shaping this playlist.",
                        actionTitle: nil,
                        action: nil
                    )
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(controller.selectedItems.enumerated()), id: \.element.id) { index, route in
                                trackRow(route, index: index)
                            }
                        }
                        .padding(.horizontal, AeonTheme.Space.edge)
                    }
                }
            }
            .foregroundStyle(AeonTheme.ColorToken.bone)
        }
        .presentationDetents([.medium, .large])
        .alert("Delete playlist?", isPresented: $deleteConfirmation) {
            Button("Delete Playlist", role: .destructive) {
                if controller.deleteSelected() { close() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tracks stay in the library.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    AeonBreadcrumb(text: "Playlist")
                    AeonDisplayText(controller.selectedPlaylist?.name ?? "Route", size: 34, maximumLines: 2)
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                    AeonLabel(text: "\(controller.selectedItems.count) tracks")
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Playlist")
                .accessibilityIdentifier("aeon.playlists.detail.close")
            }
            HStack(spacing: AeonTheme.Space.medium) {
                Button("PLAY") { controller.play() }
                    .buttonStyle(AeonButtonStyle(tier: .filled))
                    .disabled(controller.selectedItems.isEmpty)
                    .accessibilityIdentifier("aeon.playlists.detail.play")
                Button("DELETE") { deleteConfirmation = true }
                    .buttonStyle(AeonButtonStyle(tier: .bare, destructive: true))
                    .accessibilityIdentifier("aeon.playlists.detail.delete")
            }
        }
    }

    private func trackRow(_ route: PlaylistRouteItem, index: Int) -> some View {
        AeonRow(
            title: route.item.trackTitle,
            detail: route.unavailable
                ? "FILE UNAVAILABLE · \(route.item.artist) · \(route.item.albumTitle)"
                : "\(route.item.artist) · \(route.item.albumTitle)"
        ) {
            Menu {
                Button("PLAY FROM HERE") { controller.play(startingAt: index) }
                    .disabled(route.unavailable)
                Button("REMOVE", role: .destructive) { controller.remove(position: index) }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            }
            .accessibilityLabel("Actions for \(route.item.trackTitle)")
        }
    }
}
