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
                HStack {
                    Button("CANCEL") { dismiss() }
                        .buttonStyle(AeonButtonStyle(tier: .bare))
                    Spacer()
                    AeonBreadcrumb(text: "Edit album")
                }
                AeonDisplayText("Edit metadata", size: 36, maximumLines: 2)
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                artworkEditor
                field("TITLE", text: $title, identifier: "aeon.album.editor.title")
                field("ARTIST", text: $artist, identifier: "aeon.album.editor.artist")
                field("YEAR", text: $year, identifier: "aeon.album.editor.year", keyboard: .numberPad)
                VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                    field("GENRE", text: $genre, identifier: "aeon.album.editor.genre")
                    Button(lookupRunning ? "LOOKING UP" : "LOOK UP GENRE") {
                        lookupRunning = true
                        Task {
                            if let value = await controller.lookupGenre(for: artist) { genre = value }
                            lookupRunning = false
                        }
                    }
                    .buttonStyle(AeonButtonStyle(tier: .hairline))
                    .disabled(lookupRunning || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("aeon.album.editor.lookup-genre")
                }
                Button("SAVE") { requestSave() }
                    .buttonStyle(AeonButtonStyle(tier: .filled))
                    .disabled(!valid)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("aeon.album.editor.save")
            }
            .padding(AeonTheme.Space.edge)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AeonTheme.ColorToken.void.ignoresSafeArea())
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

    private var artworkEditor: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            HStack {
                AeonArtwork(image: artworkImage.map { Image(uiImage: $0) }, size: 152)
                Spacer()
            }
            HStack(spacing: AeonTheme.Space.small) {
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
                    Text("PICK ART")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
                        .tracking(1.2)
                        .frame(minHeight: AeonTheme.Space.minimumTarget)
                }
                .buttonStyle(AeonButtonStyle(tier: .hairline))
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
                .padding(.horizontal, AeonTheme.Space.medium)
                .frame(minHeight: AeonTheme.Space.minimumTarget)
                .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
                .accessibilityIdentifier(identifier)
        }
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
        let count = controller.movementCount(for: draft)
        if count > 0 {
            pendingMovementCount = count
            confirmingMove = true
        } else {
            commit()
        }
    }

    private func commit() {
        if controller.saveAlbum(draft, artworkData: artworkData) { dismiss() }
    }
}
