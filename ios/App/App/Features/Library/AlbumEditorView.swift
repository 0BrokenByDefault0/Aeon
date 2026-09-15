import PhotosUI
import SwiftUI

struct AlbumEditorView: View {
    @ObservedObject var controller: LibraryController
    let album: CatalogAlbum
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var year: String
    @State private var genre: String
    @State private var artworkData: Data?
    @State private var artworkImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var lookupRunning = false
    @State private var pendingMovementCount = 0
    @State private var confirmingMove = false
    @State private var saveError: String?

    init(controller: LibraryController, album: CatalogAlbum) {
        self.controller = controller
        self.album = album
        _title = State(initialValue: album.title)
        _artist = State(initialValue: album.artist)
        _year = State(initialValue: album.year)
        _genre = State(initialValue: album.genre)
        _artworkImage = State(initialValue: album.artworkKey.flatMap {
            guard let url = try? controller.artworkStore.url(forKey: $0) else { return nil }
            return UIImage(contentsOfFile: url.path)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AeonTheme.Space.section) {
                header
                artworkEditor
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    field("TITLE", text: $title, identifier: "aeon.album.editor.title")
                    field("ARTIST", text: $artist, identifier: "aeon.album.editor.artist")
                    HStack(alignment: .top, spacing: AeonTheme.Space.medium) {
                        field("YEAR", text: $year, identifier: "aeon.album.editor.year", keyboard: .numberPad)
                        field("GENRE", text: $genre, identifier: "aeon.album.editor.genre")
                    }
                    Button(lookupRunning ? "LOOKING UP" : "LOOK UP GENRE") {
                        lookupRunning = true
                        Task {
                            if let value = await controller.lookupGenre(for: artist) { genre = value }
                            lookupRunning = false
                        }
                    }
                    .buttonStyle(AeonButtonStyle(tier: .bare))
                    .disabled(lookupRunning || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("aeon.album.editor.lookup-genre")
                }
                .padding(.top, AeonTheme.Space.large)
                .overlay(alignment: .top) {
                    Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
                }
            }
            .padding(AeonTheme.Space.edge)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AeonTheme.ColorToken.void.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            saveBar
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                artworkData = data
                artworkImage = image
            }
        }
        .alert("Move this artist's stars?", isPresented: $confirmingMove) {
            Button("Cancel", role: .cancel) {}
            Button("Move \(pendingMovementCount) Star\(pendingMovementCount == 1 ? "" : "s")") { commit() }
        } message: {
            Text("This will move \(pendingMovementCount) star(s). The metadata and new coordinates will be committed together.")
        }
        .accessibilityIdentifier("aeon.album.editor")
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            if let saveError {
                Text(saveError)
                    .font(AeonTheme.FontToken.ui(.callout))
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                    .accessibilityIdentifier("aeon.album.editor.save-error")
            }
            Button("SAVE CHANGES") { requestSave() }
                .buttonStyle(AeonButtonStyle(tier: .filled))
                .frame(minHeight: AeonTheme.Space.minimumTarget)
                .disabled(!valid)
                .accessibilityIdentifier("aeon.album.editor.save")
        }
        .padding(.horizontal, AeonTheme.Space.edge)
        .padding(.vertical, AeonTheme.Space.small)
        .background(AeonTheme.ColorToken.void.opacity(0.96))
        .overlay(alignment: .top) {
            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: AeonTheme.Space.medium) {
            VStack(alignment: .leading, spacing: 4) {
                AeonBreadcrumb(text: "Album / Edit")
                AeonDisplayText("Edit metadata", size: 36, maximumLines: 2)
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                Text("Changes update Aeon’s catalogue without altering the source file tags.")
                    .font(AeonTheme.FontToken.ui(.callout))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            }
            .buttonStyle(.plain)
            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            .contentShape(Rectangle())
            .foregroundStyle(AeonTheme.ColorToken.bone)
            .accessibilityLabel("Cancel editing")
            .accessibilityIdentifier("aeon.album.editor.cancel")
        }
    }

    private var artworkEditor: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
            AeonLabel(text: "Artwork")
            AeonArtwork(image: artworkImage.map { Image(uiImage: $0) }, size: 176)
            HStack(spacing: AeonTheme.Space.medium) {
                Button(lookupRunning ? "SEARCHING" : "FIND ART") {
                    lookupRunning = true
                    Task {
                        if let data = await controller.findArtwork(title: title, artist: artist),
                           let image = UIImage(data: data) {
                            artworkData = data
                            artworkImage = image
                        }
                        lookupRunning = false
                    }
                }
                .buttonStyle(AeonButtonStyle(tier: .hairline))
                .disabled(lookupRunning)
                .accessibilityIdentifier("aeon.album.editor.find-art")
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("CHOOSE PHOTO", systemImage: "photo")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
                        .tracking(1.0)
                        .frame(minHeight: AeonTheme.Space.minimumTarget)
                }
                .buttonStyle(AeonButtonStyle(tier: .bare))
                .accessibilityIdentifier("aeon.album.editor.pick-art")
            }
        }
    }

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        identifier: String,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            AeonLabel(text: label)
            TextField(label.capitalized, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
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
                .accessibilityLabel(label.capitalized)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity)
    }

    private var draft: CatalogAlbum {
        var result = album
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        result.year = year.trimmingCharacters(in: .whitespacesAndNewlines)
        result.genre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    private func requestSave() {
        saveError = nil
        let count = controller.movementCount(for: draft)
        if count > 0 {
            pendingMovementCount = count
            confirmingMove = true
        } else {
            commit()
        }
    }

    private func commit() {
        if controller.saveAlbum(draft, artworkData: artworkData) {
            dismiss()
        } else {
            saveError = "The album could not be saved. Your edits are still here. Try again or cancel to leave them unsaved."
        }
    }
}
