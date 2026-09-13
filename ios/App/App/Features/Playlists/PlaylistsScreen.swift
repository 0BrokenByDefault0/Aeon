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
            HStack(spacing: AeonTheme.Space.medium) {
                VStack(alignment: .leading, spacing: 2) {
                    AeonBreadcrumb(text: "Aeon / Routes")
                    AeonDisplayText("Playlists", size: 42, maximumLines: 1)
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                        .accessibilityIdentifier("aeon.playlists.screen")
                }
                Spacer()
                if !controller.playlists.isEmpty {
                    Button { creationPresented = true } label: {
                        Image(systemName: "plus")
                            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    }
                    .buttonStyle(AeonButtonStyle(tier: .hairline))
                    .accessibilityLabel("Create Playlist")
                    .accessibilityIdentifier("aeon.playlists.create")
                }
            }
            .padding(.bottom, AeonTheme.Space.medium)

            if controller.playlists.isEmpty {
                Spacer()
                AeonEmptyState(
                    title: "No routes charted yet.",
                    detail: "Name a playlist, then add tracks from any album.",
                    actionTitle: nil,
                    action: nil
                )
                createForm
                    .frame(maxWidth: 420)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(controller.playlists) { overview in
                            Button {
                                controller.select(id: overview.id)
                                detailPresented = controller.selectedPlaylist != nil
                            } label: {
                                HStack(spacing: AeonTheme.Space.large) {
                                    AeonRouteMark().frame(width: 48, height: 34)
                                    VStack(alignment: .leading, spacing: 5) {
                                        AeonDisplayText(overview.playlist.name, size: 23, maximumLines: 2)
                                            .foregroundStyle(AeonTheme.ColorToken.bone)
                                        Text("\(overview.itemCount) TRACK\(overview.itemCount == 1 ? "" : "S")")
                                            .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
                                            .tracking(1.2)
                                            .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(AeonTheme.ColorToken.boneTertiary)
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
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, AeonTheme.Space.edge)
        .padding(.vertical, AeonTheme.Space.medium)
        .padding(.bottom, contentBottomInset)
        .sheet(isPresented: $creationPresented) {
            AeonSheet {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    AeonDisplayText("Chart a route", size: 30, maximumLines: 1)
                    createForm
                    Button("CANCEL") { creationPresented = false }
                        .buttonStyle(AeonButtonStyle(tier: .bare))
                }
                .padding(AeonTheme.Space.edge)
                .foregroundStyle(AeonTheme.ColorToken.bone)
            }
            .presentationDetents([.height(280)])
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

    private var createForm: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            TextField("Playlist name", text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding(.horizontal, AeonTheme.Space.medium)
                .frame(minHeight: AeonTheme.Space.minimumTarget)
                .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
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
                HStack {
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
                .padding(.horizontal, AeonTheme.Space.edge)
                HStack(spacing: AeonTheme.Space.medium) {
                    Button("PLAY") { controller.play() }
                        .buttonStyle(AeonButtonStyle(tier: .filled))
                        .disabled(controller.selectedItems.isEmpty)
                        .accessibilityIdentifier("aeon.playlists.detail.play")
                    Spacer()
                    Button("DELETE") { deleteConfirmation = true }
                        .buttonStyle(AeonButtonStyle(tier: .bare, destructive: true))
                        .accessibilityIdentifier("aeon.playlists.detail.delete")
                }
                .padding(AeonTheme.Space.edge)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if controller.selectedItems.isEmpty {
                            AeonEmptyState(title: "Empty route.", detail: nil, actionTitle: nil, action: nil)
                        }
                        ForEach(Array(controller.selectedItems.enumerated()), id: \.element.id) { index, route in
                            AeonRow(
                                title: route.item.trackTitle,
                                detail: route.unavailable
                                    ? "FILE UNAVAILABLE · \(route.item.artist) · \(route.item.albumTitle)"
                                    : "\(route.item.artist) · \(route.item.albumTitle)"
                            ) {
                                HStack(spacing: 0) {
                                    Button { controller.play(startingAt: index) } label: {
                                        Image(systemName: "play.fill").frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(route.unavailable)
                                    .accessibilityLabel("Play \(route.item.trackTitle)")
                                    Button { controller.remove(position: index) } label: {
                                        Image(systemName: "xmark").frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove from playlist")
                                }
                                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                            }
                        }
                    }
                    .padding(.horizontal, AeonTheme.Space.edge)
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
}
