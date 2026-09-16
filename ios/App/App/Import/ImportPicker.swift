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
/// a controller that is actually in the window.
///
/// Two ways this has already failed on device:
///
/// 1. Embedding the picker in a SwiftUI sheet as a child controller. It renders,
///    and Open animates and does nothing, because a document picker is a remote
///    view controller that has to be presented, not installed in a hierarchy.
/// 2. Presenting it from a controller that is not in the window, or is in the
///    middle of being dismissed. The picker still appears — it draws from its own
///    process — but the delegate callback has nowhere to arrive, so Open animates
///    and nothing happens. A zero-sized background representable can easily have
///    no window of its own, so the anchor is resolved from the active scene
///    rather than from this view, and presentation waits for any transition to
///    finish.
struct ImportPickerPresenter: UIViewControllerRepresentable {
    @Binding var kind: ImportPickerKind?
    let completion: (ImportPickerOutcome, ImportPickerKind) -> Void
    var log: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.completion = completion
        context.coordinator.log = log
        context.coordinator.clearSelection = { kind = nil }
        guard let kind else { return }
        context.coordinator.present(kind)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        var completion: ((ImportPickerOutcome, ImportPickerKind) -> Void)?
        var clearSelection: (() -> Void)?
        var log: (String) -> Void = { _ in }
        private var presenting: ImportPickerKind?
        /// Held strongly: the picker's `delegate` is weak, and an orphaned
        /// coordinator is another way Open ends up doing nothing.
        private var picker: UIDocumentPickerViewController?

        func present(_ kind: ImportPickerKind, attempt: Int = 0) {
            if presenting != nil {
                // A pending cancel from an earlier dismissal must not swallow a
                // fresh tap: if nothing is on screen, that state is stale.
                guard picker?.viewIfLoaded?.window == nil else { return }
                presenting = nil
                picker = nil
            }
            presenting = kind
            log("import_picker_requested_\(kind.rawValue)")
            attemptPresentation(kind, attempt: attempt)
        }

        private func attemptPresentation(_ kind: ImportPickerKind, attempt: Int) {
            guard let anchor = Self.presentationAnchor, anchor.viewIfLoaded?.window != nil,
                  anchor.transitionCoordinator == nil, !anchor.isBeingDismissed, !anchor.isBeingPresented else {
                guard attempt < 30 else {
                    log("import_picker_no_anchor")
                    finish(.failed("Aeon could not open the file browser. Close anything on screen and try again."))
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.attemptPresentation(kind, attempt: attempt + 1)
                }
                return
            }
            let controller = UIDocumentPickerViewController(
                forOpeningContentTypes: kind.contentTypes,
                asCopy: false
            )
            controller.allowsMultipleSelection = kind.allowsMultipleSelection
            controller.shouldShowFileExtensions = true
            controller.delegate = self
            // Deliberately NOT the presentationController delegate's only
            // source of truth: see scheduleCancelAfterDismissal.
            controller.presentationController?.delegate = self
            picker = controller
            anchor.present(controller, animated: true) { [weak self] in
                self?.log("import_picker_presented")
            }
        }

        /// The topmost controller that is actually on screen, found through the
        /// active scene rather than through the presenting view.
        private static var presentationAnchor: UIViewController? {
            let root = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }?
                .rootViewController
            var anchor = root
            while let presented = anchor?.presentedViewController, !presented.isBeingDismissed {
                anchor = presented
            }
            return anchor
        }

        private func finish(_ outcome: ImportPickerOutcome) {
            guard let kind = presenting else { return }
            presenting = nil
            picker = nil
            switch outcome {
            case .picked(let urls): log("import_picker_picked_\(urls.count)")
            case .cancelled: log("import_picker_cancelled")
            case .failed: log("import_picker_failed")
            }
            clearSelection?()
            completion?(outcome, kind)
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Runs after presentationControllerDidDismiss has been scheduled;
            // finishing here first is what makes the deferred cancel a no-op.
            guard !urls.isEmpty else {
                finish(.failed("That location returned nothing Aeon can open. Choose a folder or files stored on this iPhone or in iCloud Drive."))
                return
            }
            finish(.picked(urls))
        }

        /// The single-URL callback older systems still deliver when multiple
        /// selection is off. Without it those picks vanish silently.
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
            finish(.picked([url]))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.cancelled)
        }

        /// Swiping the picker away is a cancel too, but so is choosing a file
        /// from the app's point of view: picking dismisses the picker, and this
        /// callback arrives BEFORE `didPickDocumentsAt`. Calling it a cancel
        /// here threw the real selection away — Open looked like it did nothing.
        /// So wait a beat, and only call it a cancel if no URLs followed.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            scheduleCancelAfterDismissal()
        }

        /// Visible for tests: a pick arriving while this is pending must win.
        ///
        /// The window is generous on purpose. UIKit can deliver the URLs a beat
        /// after the dismissal animation ends, and a short window turned a real
        /// selection into a cancel that reported nothing at all.
        func scheduleCancelAfterDismissal(after delay: TimeInterval = 4.0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.finish(.cancelled)
            }
        }

        /// Visible for tests: normally set when the picker is presented.
        func beginTracking(_ kind: ImportPickerKind) {
            presenting = kind
        }
    }
}
