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

    /// Audio is imported, not edited in place. Ask the system to deliver a copy.
    /// Folder grants and catalogue recovery retain their existing open-in-place mode.
    var copiesSelection: Bool { self == .audioFiles }

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
    var event: (String) -> Void = { _ in }
    let completion: (ImportPickerOutcome) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = Self.makeController(for: kind)
        event("configured.\(kind.rawValue).\(kind.copiesSelection ? "copy" : "open")")
        if kind == .folder {
            return FolderPickerHost(picker: controller, event: event, completion: completion)
        }
        controller.delegate = context.coordinator
        return controller
    }

    /// The production picker and the configuration regression use this same factory.
    static func makeController(for kind: ImportPickerKind) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forOpeningContentTypes: kind.contentTypes,
            asCopy: kind.copiesSelection
        )
        controller.allowsMultipleSelection = kind.allowsMultipleSelection
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.completion = completion
        context.coordinator.event = event
        if let host = controller as? FolderPickerHost {
            host.event = event
            host.completion = completion
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(event: event, completion: completion) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var completion: (ImportPickerOutcome) -> Void
        var event: (String) -> Void
        private var finished = false

        init(event: @escaping (String) -> Void = { _ in }, completion: @escaping (ImportPickerOutcome) -> Void) {
            self.event = event
            self.completion = completion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !finished else { return }
            finished = true
            event("received.\(urls.count)")
            guard !urls.isEmpty else {
                completion(.failed("That location returned nothing Aeon can open. Choose a folder or files stored on this iPhone or in iCloud Drive."))
                return
            }
            completion(.picked(urls))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !finished else { return }
            finished = true
            event("cancelled")
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

/// The SwiftUI sheet owns this host, and this host is the folder picker's delegate.
/// UIKit dismisses the child picker, not the sheet that owns its callback receiver.
/// Keep the existing audio-file presentation and copy policy untouched.
@MainActor
final class FolderPickerHost: UIViewController, UIDocumentPickerDelegate {
    private(set) var picker: UIDocumentPickerViewController
    var event: (String) -> Void
    var completion: (ImportPickerOutcome) -> Void
    private let sessionID = UUID().uuidString.lowercased()
    private var hasPresented = false
    private var finished = false
    private let statusLabel = UILabel()

    init(picker: UIDocumentPickerViewController, event: @escaping (String) -> Void,
         completion: @escaping (ImportPickerOutcome) -> Void) {
        self.picker = picker
        self.event = event
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        picker.delegate = self
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "Choose a music folder."
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        let retry = UIButton(type: .system)
        retry.setTitle("Choose Folder", for: .normal)
        retry.addTarget(self, action: #selector(retrySelection), for: .touchUpInside)
        retry.accessibilityIdentifier = "aeon.import.folder.retry"
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.addTarget(self, action: #selector(cancelSelection), for: .touchUpInside)
        cancel.accessibilityIdentifier = "aeon.import.folder.cancel"
        let stack = UIStackView(arrangedSubviews: [statusLabel, retry, cancel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !finished else { return }
        if !hasPresented {
            presentPicker()
        } else if presentedViewController == nil {
            // This is not treated as success or cancellation: delivery can arrive late.
            // Leave a recoverable UI and keep the delegate alive until a real outcome.
            trace("returned_without_result")
            statusLabel.text = "No folder has been received. Choose a folder again or cancel."
        }
    }

    private func presentPicker() {
        guard !finished, !hasPresented, presentedViewController == nil, view.window != nil else { return }
        hasPresented = true
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AeonFolderPickerAcceptance") {
            do { picker.directoryURL = try Self.prepareAcceptanceSource() }
            catch {
                trace("fixture_failed")
                finish(.failed("The folder test source could not be prepared."))
                return
            }
        }
        #endif
        trace("presenting")
        // viewDidAppear is the presentation boundary; no guessed sheet-animation delay.
        present(picker, animated: false) { [weak self] in self?.trace("presented") }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        trace("callback.entered.\(urls.count).finished.\(finished)")
        guard controller === picker, !finished else { trace("callback.ignored"); return }
        event("received.\(urls.count)")
        guard !urls.isEmpty else {
            finish(.failed("Files returned no folder. Choose a music folder and press Open."))
            return
        }
        // The root acquires scoped access synchronously, then schedules the importer.
        finish(.picked(urls))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        trace("cancel.entered.finished.\(finished)")
        guard controller === picker, !finished else { return }
        event("cancelled")
        finish(.cancelled)
    }

    @objc private func retrySelection() {
        guard !finished, presentedViewController == nil else { return }
        picker = ImportDocumentPicker.makeController(for: .folder)
        hasPresented = false
        presentPicker()
    }

    @objc private func cancelSelection() { finish(.cancelled) }

    private func finish(_ outcome: ImportPickerOutcome) {
        guard !finished else { return }
        finished = true
        trace("delivering")
        completion(outcome)
        trace("delivered")
    }

    private func trace(_ marker: String) { event("folder.\(sessionID).\(marker)") }

    #if DEBUG
    /// Generate only a source file in the simulator's real Documents folder. The test
    /// must use Apple Files/Open and the real importer to create its catalogue record.
    private static func prepareAcceptanceSource() throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Aeon Folder Check", isDirectory: true)
        let nested = root.appendingPathComponent("Nested Record", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let rate = 44_100
        let count = rate / 4
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36 + count * 2))
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(UInt32(count * 2))
        for index in 0..<count { append(Int16(sin(Double(index) * 2 * .pi * 220 / Double(rate)) * 500)) }
        try data.write(to: nested.appendingPathComponent("01 Folder Check.wav"), options: .atomic)
        return root
    }
    #endif
}
