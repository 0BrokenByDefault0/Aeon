import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The three document-picker journeys Aeon offers. A single presentation is driven by
/// this value so that only one picker modifier is ever attached to the root view:
/// stacking several `fileImporter` modifiers on one view silently drops all but one of
/// them, which is how IMPORT FILES ended up doing nothing on device.
enum ImportPickerKind: String, Identifiable {
    case audioFiles
    case folder
    case catalogArchive

    var id: String { rawValue }

    var allowsMultipleSelection: Bool { self == .audioFiles }

    var contentTypes: [UTType] {
        switch self {
        case .audioFiles: return AeonImportContentTypes.audio
        case .folder: return [.folder]
        case .catalogArchive: return [.data]
        }
    }
}

enum ImportPickerOutcome {
    case picked([URL])
    case cancelled
    case failed(String)
}

enum AeonImportContentTypes {
    /// Content types for every container `AudioTagReader` can read. `public.audio` alone
    /// leaves FLAC and CAF greyed out in the Files browser on device, so each supported
    /// extension is resolved to its declared type as well. FLAC resolves through the
    /// imported type declaration in Info.plist when the system does not declare one.
    static let audio: [UTType] = {
        var resolved: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        for ext in AudioTagReader.supportedExtensions.sorted() {
            // A dynamic type is the system saying it has never heard of the extension.
            // Handing one to the picker matches nothing, so leave it out.
            guard let type = UTType(filenameExtension: ext), !type.isDynamic else { continue }
            resolved.append(type)
        }
        var seen = Set<String>()
        return resolved.filter { seen.insert($0.identifier).inserted }
    }()
}

/// Presents a `UIDocumentPickerViewController` directly. SwiftUI's `fileImporter` cannot
/// report why a pick failed and cannot be stacked, both of which this flow needs.
struct ImportDocumentPicker: UIViewControllerRepresentable {
    let kind: ImportPickerKind
    let completion: (ImportPickerOutcome) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: kind.contentTypes,
            asCopy: kind != .catalogArchive
        )
        controller.allowsMultipleSelection = kind.allowsMultipleSelection
        controller.shouldShowFileExtensions = true
        controller.view.accessibilityIdentifier = "aeon.import.document-picker"
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.completion = completion
    }

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var completion: (ImportPickerOutcome) -> Void
        private var finished = false

        init(completion: @escaping (ImportPickerOutcome) -> Void) {
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !finished else { return }
            finished = true
            guard !urls.isEmpty else {
                completion(.failed("That location returned nothing Aeon can open. Choose a folder or files stored on this iPhone or in iCloud Drive."))
                return
            }
            completion(.picked(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !finished else { return }
            finished = true
            completion(.cancelled)
        }
    }
}


/// Retain security-scoped access from the picker callback through asynchronous import.
/// A false return is not automatically an error: app-container URLs need no grant.
final class ImportAccessLease: @unchecked Sendable {
    private let accessed: [URL]
    init(urls: [URL]) {
        accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
    }
    deinit { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
}

struct PendingImportSelection {
    let kind: ImportPickerKind
    let outcome: ImportPickerOutcome
    let accessLease: ImportAccessLease

    init(kind: ImportPickerKind, outcome: ImportPickerOutcome) {
        self.kind = kind
        self.outcome = outcome
        if case .picked(let urls) = outcome {
            accessLease = ImportAccessLease(urls: urls)
        } else {
            accessLease = ImportAccessLease(urls: [])
        }
    }
}

/// Direct actions. There is no source-choice sheet to dismiss before opening Files.
struct AeonImportActions: View {
    let selectFiles: () -> Void
    let selectFolder: () -> Void
    var disabled = false

    var body: some View {
        VStack(spacing: 0) {
            sourceButton("Import Files", detail: "Select audio files", symbol: "doc.badge.plus",
                         identifier: "aeon.library.import.files", action: selectFiles)
            Divider().overlay(AeonTheme.ColorToken.rule)
            sourceButton("Import Folder", detail: "Include music in subfolders", symbol: "folder.badge.plus",
                         identifier: "aeon.library.import.folder", action: selectFolder)
        }
        .background(AeonTheme.ColorToken.surfaceSelected.opacity(0.35))
        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: 0.5))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func sourceButton(_ title: String, detail: String, symbol: String,
                              identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(AeonTheme.FontToken.ui(.callout, weight: .medium))
                    Text(detail).font(AeonTheme.FontToken.ui(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(AeonTheme.ColorToken.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

struct AeonImportStatus: View {
    let progress: LibraryImportProgress?
    let result: LibraryImportResult?
    let cancel: () -> Void

    var body: some View {
        if let progress {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(progressLabel(progress)).font(AeonTheme.FontToken.ui(.callout, weight: .medium))
                    Spacer(minLength: 8)
                    Button("Pause", action: cancel)
                        .font(AeonTheme.FontToken.ui(.callout))
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("aeon.library.import.cancel")
                }
                if progress.totalFiles == 0 {
                    ProgressView().tint(AeonTheme.ColorToken.textPrimary)
                } else {
                    ProgressView(value: fraction(progress)).tint(AeonTheme.ColorToken.textPrimary)
                }
            }
            .foregroundStyle(AeonTheme.ColorToken.textPrimary)
            .accessibilityIdentifier("aeon.library.import.progress")
        } else if let result {
            VStack(alignment: .leading, spacing: 6) {
                Text(resultTitle(result)).font(AeonTheme.FontToken.ui(.callout, weight: .semibold))
                Text(resultDetail(result)).font(AeonTheme.FontToken.ui(.caption))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AeonTheme.ColorToken.surfaceSelected.opacity(0.4))
            .accessibilityIdentifier("aeon.library.import.result")
        }
    }

    private func fraction(_ value: LibraryImportProgress) -> Double {
        if value.totalGroups > 0 {
            return Double(value.completedGroups) / Double(value.totalGroups)
        }
        return Double(value.completedFiles) / Double(max(1, value.totalFiles))
    }

    private func progressLabel(_ value: LibraryImportProgress) -> String {
        switch value.phase {
        case .scanning: return "Scanning your selection…"
        case .readingMetadata: return "Reading files: \(value.completedFiles) of \(value.totalFiles)"
        case .grouping: return "Organizing albums…"
        case .committing: return "Adding albums: \(value.completedGroups) of \(value.totalGroups)"
        case .complete: return "Import complete"
        }
    }

    private func resultTitle(_ value: LibraryImportResult) -> String {
        if value.importedTracks > 0 {
            return "Added \(value.importedTracks) \(value.importedTracks == 1 ? "track" : "tracks")"
        }
        return value.skippedDuplicateAlbums.isEmpty ? "No tracks imported" : "Already in your library"
    }

    private func resultDetail(_ value: LibraryImportResult) -> String {
        var parts: [String] = []
        if value.importedAlbums > 0 {
            parts.append("\(value.importedAlbums) \(value.importedAlbums == 1 ? "album" : "albums") added.")
        }
        if !value.skippedDuplicateAlbums.isEmpty {
            parts.append("\(value.skippedDuplicateAlbums.count) existing albums skipped.")
        }
        if !value.failedFiles.isEmpty {
            parts.append("\(value.failedFiles.count) files could not be read or played. Check the format and that the files have downloaded.")
        }
        return parts.isEmpty ? "The selection produced no playable audio. Try another file or folder." : parts.joined(separator: " ")
    }
}

enum AeonRecoveryBuildIdentity {
    static var label: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = info["AeonBuildCommit"] as? String ?? "local"
        return "Recovery 2 · \(commit.prefix(8))"
    }
}
