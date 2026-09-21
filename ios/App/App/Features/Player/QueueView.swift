import SwiftUI
import UniformTypeIdentifiers

struct QueueView: View {
    @ObservedObject var playback: PlaybackController
    let catalog: CatalogRepository
    let close: () -> Void
    var showAlbum: (String) -> Void = { _ in }
    var showArtist: (String) -> Void = { _ in }
    @State private var naming = false
    @State private var playlistName = ""
    @State private var draggedOffset: Int?
    @State private var dropOffset: Int?

    var body: some View {
        AeonSheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.section) {
                    header
                    actions
                    if naming { namingForm }
                    if let message = playback.queueMessage {
                        status(message)
                    }
                    queueRows
                }
                .padding(.horizontal, AeonTheme.Space.edge)
                .padding(.bottom, AeonTheme.Space.section)
            }
            .scrollIndicators(.hidden)
        }
        .background(AeonTheme.ColorToken.void.ignoresSafeArea())
        .onDisappear { playback.clearQueueMessage() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AeonTheme.Space.medium) {
            VStack(alignment: .leading, spacing: 4) {
                AeonBreadcrumb(text: "Player / Queue")
                AeonDisplayText("Up next", size: 36, maximumLines: 1)
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                if let snapshot = playback.snapshot, let index = snapshot.queueIndex {
                    Text("\(index + 1) OF \(snapshot.queue.count)")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .medium))
                        .tracking(1.1)
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
            }
            Spacer()
            Button(action: close) {
                AeonGlyph(kind: .close)
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AeonTheme.ColorToken.bone)
            .accessibilityLabel("Close queue")
            .accessibilityIdentifier("aeon.player.queue.close")
        }
    }

    private var actions: some View {
        HStack(spacing: AeonTheme.Space.medium) {
            Button("SAVE AS PLAYLIST") { naming.toggle() }
                .buttonStyle(AeonButtonStyle(tier: .hairline))
                .disabled(playback.snapshot?.queue.isEmpty != false)
                .accessibilityIdentifier("aeon.player.queue.save")
            Button("CLEAR UPCOMING", action: playback.clearUpcoming)
                .buttonStyle(AeonButtonStyle(tier: .bare))
                .disabled(upcomingItems.isEmpty)
                .accessibilityIdentifier("aeon.player.queue.clear")
        }
    }

    private var namingForm: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            AeonLabel(text: "Playlist name")
            HStack(spacing: AeonTheme.Space.small) {
                TextField("Name this queue", text: $playlistName)
                    .textInputAutocapitalization(.words)
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                    .padding(.horizontal, AeonTheme.Space.regular)
                    .frame(minHeight: 48)
                    .background(
                        RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                            .fill(AeonTheme.ColorToken.surfaceSelected.opacity(0.54))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                            .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
                    )
                    .accessibilityIdentifier("aeon.player.queue.name")
                Button("SAVE") {
                    if playback.saveQueueAsPlaylist(name: playlistName) {
                        playlistName = ""
                        naming = false
                    }
                }
                .buttonStyle(AeonButtonStyle(tier: .filled))
                .accessibilityIdentifier("aeon.player.queue.commit-save")
            }
        }
        .padding(AeonTheme.Space.medium)
        .background(
            RoundedRectangle(cornerRadius: AeonTheme.Radius.surface, style: .continuous)
                .fill(AeonTheme.ColorToken.chamber.opacity(0.74))
        )
    }

    private func status(_ message: String) -> some View {
        HStack(spacing: AeonTheme.Space.small) {
            AeonGlyph(kind: .check)
            Text(message)
                .font(AeonTheme.FontToken.ui(.caption))
        }
        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("aeon.player.queue.status")
    }

    @ViewBuilder
    private var queueRows: some View {
        if let snapshot = playback.snapshot,
           let currentIndex = snapshot.queueIndex,
           snapshot.queue.indices.contains(currentIndex) {
            VStack(alignment: .leading, spacing: 0) {
                AeonLabel(text: "Playing").padding(.bottom, AeonTheme.Space.small)
                queueRow(snapshot.queue[currentIndex], position: currentIndex + 1, current: true, offset: nil)
                if !upcomingItems.isEmpty {
                    AeonLabel(text: "Upcoming")
                        .padding(.top, AeonTheme.Space.section)
                        .padding(.bottom, AeonTheme.Space.small)
                    ForEach(Array(upcomingItems.enumerated()), id: \.offset) { offset, item in
                        queueRow(item, position: currentIndex + offset + 2, current: false, offset: offset)
                    }
                }
            }
        } else {
            AeonEmptyState(
                title: "Nothing queued",
                detail: "Play an album or route and the upcoming sequence will appear here.",
                actionTitle: nil,
                action: nil
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var upcomingItems: [QueueItem] {
        guard let snapshot = playback.snapshot, let currentIndex = snapshot.queueIndex,
              snapshot.queue.indices.contains(currentIndex), currentIndex + 1 < snapshot.queue.count else { return [] }
        return Array(snapshot.queue.suffix(from: currentIndex + 1))
    }

    private func queueRow(
        _ item: QueueItem,
        position: Int,
        current: Bool,
        offset: Int?
    ) -> some View {
        let track = try? catalog.track(id: item.trackID)
        let album = try? catalog.album(id: item.albumID)
        let title = track?.title ?? "Unavailable track"
        let artist = track?.artist.isEmpty == false ? track!.artist : (album?.artist ?? "")
        let detail = [artist, album?.title].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
        let isDropTarget = offset.map { dropOffset == $0 } ?? false

        return HStack(spacing: AeonTheme.Space.medium) {
            Text(current ? "NOW" : String(format: "%02d", position))
                .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
                .foregroundStyle(current ? AeonTheme.ColorToken.bone : AeonTheme.ColorToken.boneTertiary)
                .frame(width: 34, alignment: .trailing)
                .accessibilityIdentifier(current ? "aeon.player.queue.current" : "aeon.player.queue.position.\(position)")
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AeonTheme.FontToken.ui(.body, weight: current ? .semibold : .medium))
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                if !detail.isEmpty {
                    Text(detail)
                        .font(AeonTheme.FontToken.ui(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let track {
                TrackActionMenu(
                    track: track,
                    catalog: catalog,
                    playback: playback,
                    showAlbum: { close(); showAlbum(item.albumID) },
                    showArtist: { close(); showArtist(artist) },
                    removeTitle: "REMOVE FROM QUEUE",
                    remove: offset == nil ? nil : { playback.removeFromQueue(at: position - 1) }
                ) {
                    AeonGlyph(kind: .more)
                        .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                }
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            }
            if let offset {
                AeonGlyph(kind: .grip)
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                    .frame(width: 45, height: 45)
                    .contentShape(Rectangle())
                    .onDrag {
                        draggedOffset = offset
                        return NSItemProvider(object: String(offset) as NSString)
                    }
                    // One element for the whole 44pt target, carrying the image trait the
                    // handle used to get for free from a filled SF Symbol. Assistive
                    // technology and XCUITest both address it as an image.
                    .accessibilityElement()
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel("Reorder \(title)")
                    .accessibilityHint("Drag to a new position")
                    .accessibilityIdentifier("aeon.player.queue.drag.\(item.trackID)")
            }
        }
        .padding(.vertical, AeonTheme.Space.small)
        .padding(.horizontal, isDropTarget ? AeonTheme.Space.small : 0)
        .frame(minHeight: 62)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: AeonTheme.Radius.compact, style: .continuous)
                    .fill(AeonTheme.ColorToken.surfaceSelected.opacity(0.78))
            }
        }
        .overlay(alignment: .bottom) {
            if !isDropTarget {
                Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
            }
        }
        .opacity(draggedOffset == offset ? 0.55 : 1)
        .onDrop(
            of: [UTType.text],
            delegate: QueueDropDelegate(
                targetOffset: offset,
                draggedOffset: $draggedOffset,
                dropOffset: $dropOffset,
                playback: playback
            )
        )
    }
}

private struct QueueDropDelegate: DropDelegate {
    let targetOffset: Int?
    @Binding var draggedOffset: Int?
    @Binding var dropOffset: Int?
    let playback: PlaybackController

    func dropEntered(info: DropInfo) { dropOffset = targetOffset }

    func dropExited(info: DropInfo) {
        if dropOffset == targetOffset { dropOffset = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedOffset = nil
            dropOffset = nil
        }
        guard let source = draggedOffset, let target = targetOffset, source != target else { return false }
        playback.moveUpcoming(
            fromOffsets: IndexSet(integer: source),
            toOffset: source < target ? target + 1 : target
        )
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

enum TrackActionSheet: String, Identifiable {
    case playlist
    case info
    var id: String { rawValue }
}

struct TrackActionMenu<Label: View>: View {
    let track: CatalogTrack
    let catalog: CatalogRepository
    @ObservedObject var playback: PlaybackController
    let playFromHere: (() -> Void)?
    let showAlbum: (() -> Void)?
    let showArtist: (() -> Void)?
    let removeTitle: String
    let remove: (() -> Void)?
    let label: Label
    @State private var presentedSheet: TrackActionSheet?

    init(
        track: CatalogTrack,
        catalog: CatalogRepository,
        playback: PlaybackController,
        playFromHere: (() -> Void)? = nil,
        showAlbum: (() -> Void)? = nil,
        showArtist: (() -> Void)? = nil,
        removeTitle: String = "REMOVE FROM PLAYLIST",
        remove: (() -> Void)? = nil,
        @ViewBuilder label: () -> Label
    ) {
        self.track = track
        self.catalog = catalog
        self.playback = playback
        self.playFromHere = playFromHere
        self.showAlbum = showAlbum
        self.showArtist = showArtist
        self.removeTitle = removeTitle
        self.remove = remove
        self.label = label()
    }

    var body: some View {
        Menu {
            Button("PLAY NEXT") { playback.playNext(track) }
            Button("ADD TO QUEUE") { playback.addToQueue(track) }
            Button("ADD TO PLAYLIST") { presentedSheet = .playlist }
            if let showAlbum { Button("SHOW ALBUM", action: showAlbum) }
            if let showArtist, !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Aeon currently has artist search, not an artist detail destination.
                Button("FIND ARTIST", action: showArtist)
            }
            Button("TRACK INFO") { presentedSheet = .info }
            if let playFromHere { Button("PLAY FROM HERE", action: playFromHere) }
            if let remove { Button(removeTitle, role: .destructive, action: remove) }
        } label: { label }
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .playlist:
                TrackPlaylistPicker(track: track, catalog: catalog)
            case .info:
                TrackInfoSheet(track: track, album: try? catalog.album(id: track.albumID))
            }
        }
        .accessibilityLabel("Actions for \(track.title)")
        .accessibilityIdentifier("aeon.track.actions.\(track.id)")
    }
}

private struct TrackPlaylistPicker: View {
    let track: CatalogTrack
    let catalog: CatalogRepository
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        AeonSheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    AeonDisplayText("Add to playlist", size: 32, maximumLines: 2)
                        .foregroundStyle(AeonOrbit.title)
                    let playlists = (try? catalog.playlists()) ?? []
                    if !playlists.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(playlists) { playlist in
                                Button {
                                    add(to: playlist.id)
                                } label: {
                                    AeonRow(title: playlist.name, detail: "PLAYLIST") {
                                        AeonGlyph(kind: .add).frame(width: 44, height: 44)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                        AeonLabel(text: "New playlist")
                        TextField("Playlist name", text: $name)
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, AeonTheme.Space.regular)
                            .frame(minHeight: AeonTheme.Space.minimumTarget)
                            .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, style: AeonOrbit.line))
                        Button("CREATE AND ADD") { createAndAdd() }
                            .buttonStyle(AeonButtonStyle(tier: .filled))
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error {
                        Text(error).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonTheme.ColorToken.danger)
                    }
                    Button("CANCEL") { dismiss() }.buttonStyle(AeonButtonStyle(tier: .bare))
                }
                .padding(AeonTheme.Space.edge)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to playlistID: String) {
        do {
            let ids = try catalog.playlistItems(playlistID: playlistID).map(\.trackID) + [track.id]
            try catalog.replacePlaylistItems(playlistID: playlistID, trackIDs: ids)
            AeonFeedback.succeeded()
            dismiss()
        } catch {
            self.error = "The track could not be added."
            AeonFeedback.failed()
        }
    }

    private func createAndAdd() {
        do {
            _ = try catalog.createPlaylist(name: name, trackIDs: [track.id])
            AeonFeedback.succeeded()
            dismiss()
        } catch {
            self.error = "The playlist could not be created."
            AeonFeedback.failed()
        }
    }
}

private struct TrackInfoSheet: View {
    let track: CatalogTrack
    let album: CatalogAlbum?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AeonSheet {
            VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                AeonDisplayText(track.title, size: 32, maximumLines: 3).foregroundStyle(AeonOrbit.title)
                VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
                    detail("ARTIST", track.artist.isEmpty ? album?.artist ?? "Unknown" : track.artist)
                    detail("ALBUM", album?.title ?? "Unknown")
                    if let trackNumber = track.trackNumber { detail("TRACK", "\(trackNumber)") }
                    if let duration = track.duration { detail("DURATION", String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60)) }
                }
                Button("DONE") { dismiss() }.buttonStyle(AeonButtonStyle(tier: .filled))
            }
            .padding(AeonTheme.Space.edge)
        }
        .presentationDetents([.medium])
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            AeonLabel(text: label)
            Text(value).font(AeonTheme.FontToken.ui(.body)).foregroundStyle(AeonOrbit.ink)
        }
    }
}
