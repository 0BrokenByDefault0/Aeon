import SwiftUI
import UniformTypeIdentifiers

struct QueueView: View {
    @ObservedObject var playback: PlaybackController
    let catalog: CatalogRepository
    let close: () -> Void
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
            if let offset {
                AeonGlyph(kind: .grip)
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
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
