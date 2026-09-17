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
            asCopy: false
        )
        controller.allowsMultipleSelection = kind.allowsMultipleSelection
        controller.shouldShowFileExtensions = true
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

/// Claim the provider grant synchronously in the picker callback and retain it across
/// sheet dismissal and asynchronous import. Balance only the grants actually acquired.
final class ImportSourceAccess {
    private let accessed: [URL]
    private let end: (URL) -> Void

    init(
        urls: [URL],
        begin: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        end: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.end = end
        var seen = Set<URL>()
        accessed = urls.filter { seen.insert($0).inserted }.filter(begin)
    }

    deinit { accessed.forEach(end) }
}
