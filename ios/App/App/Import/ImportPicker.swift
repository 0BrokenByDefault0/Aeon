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

/// Presents `UIDocumentPickerViewController` the way UIKit expects: modally, from
/// the topmost view controller.
///
/// Embedding the picker in a SwiftUI sheet as a child controller renders it, and
/// Open then animates and does nothing at all — the delegate never fires, because a
/// document picker is a remote view controller that has to be presented rather than
/// installed in a hierarchy. That is why importing did nothing on device.
struct ImportPickerPresenter: UIViewControllerRepresentable {
    @Binding var kind: ImportPickerKind?
    let completion: (ImportPickerOutcome, ImportPickerKind) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.completion = completion
        context.coordinator.clearSelection = { kind = nil }
        guard let kind else { return }
        context.coordinator.present(kind, from: host)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        var completion: ((ImportPickerOutcome, ImportPickerKind) -> Void)?
        var clearSelection: (() -> Void)?
        private var presenting: ImportPickerKind?

        func present(_ kind: ImportPickerKind, from host: UIViewController) {
            guard presenting == nil else { return }
            presenting = kind
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: kind.contentTypes,
                asCopy: false
            )
            picker.allowsMultipleSelection = kind.allowsMultipleSelection
            picker.shouldShowFileExtensions = true
            picker.delegate = self
            picker.presentationController?.delegate = self
            // The import sheet dismisses itself first, so wait a turn for the
            // presentation to settle before asking for another one.
            DispatchQueue.main.async { [weak self, weak host] in
                guard let presenter = host?.presentationAnchor else {
                    self?.finish(.failed("Aeon could not open the file browser. Try again."))
                    return
                }
                presenter.present(picker, animated: true)
            }
        }

        private func finish(_ outcome: ImportPickerOutcome) {
            guard let kind = presenting else { return }
            presenting = nil
            clearSelection?()
            completion?(outcome, kind)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else {
                finish(.failed("That location returned nothing Aeon can open. Choose a folder or files stored on this iPhone or in iCloud Drive."))
                return
            }
            finish(.picked(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.cancelled)
        }

        /// Swiping the picker away is a cancel too; without this the selection
        /// sticks and the next tap on IMPORT does nothing.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish(.cancelled)
        }
    }
}

private extension UIViewController {
    /// The controller a modal should be presented from: the top of whatever is
    /// already presented above this one.
    var presentationAnchor: UIViewController? {
        var anchor: UIViewController? = view.window?.rootViewController ?? self
        while let presented = anchor?.presentedViewController, !presented.isBeingDismissed {
            anchor = presented
        }
        return anchor
    }
}
