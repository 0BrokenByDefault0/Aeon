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

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = Self.makeController(for: kind)
        controller.delegate = context.coordinator
        event("configured.\(kind.rawValue).\(kind.copiesSelection ? "copy" : "open")")
        return controller
    }

    /// Audio keeps copy mode. Folder uses Apple's documented directory initializer
    /// without routing through the generic copy/open initializer.
    static func makeController(for kind: ImportPickerKind) -> UIDocumentPickerViewController {
        let controller: UIDocumentPickerViewController
        if kind == .folder {
            controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        } else {
            controller = UIDocumentPickerViewController(
                forOpeningContentTypes: kind.contentTypes,
                asCopy: kind.copiesSelection
            )
        }
        controller.allowsMultipleSelection = kind.allowsMultipleSelection
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.completion = completion
        context.coordinator.event = event
        controller.delegate = context.coordinator
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

/// Folder selection has different lifetime requirements from copied file selection.
/// The root owns this session across sheet dismissal, and the session strongly retains
/// the system picker until a real pick/cancel result arrives.
@MainActor
final class FolderPickerSession: NSObject, ObservableObject, UIDocumentPickerDelegate {
    private var event: (String) -> Void = { _ in }
    private var completion: (ImportPickerOutcome) -> Void = { _ in }
    private var currentController: UIDocumentPickerViewController?
    private var sessionID = UUID().uuidString.lowercased()
    private var active = false
    private var finished = true

    var awaitingOutcome: Bool { active && !finished }

    func begin(
        event: @escaping (String) -> Void,
        completion: @escaping (ImportPickerOutcome) -> Void
    ) {
        currentController = nil
        sessionID = UUID().uuidString.lowercased()
        self.event = event
        self.completion = completion
        active = true
        finished = false
        trace("began")
    }

    func makeController() -> UIDocumentPickerViewController {
        let controller = ImportDocumentPicker.makeController(for: .folder)
        controller.delegate = self
        currentController = controller
        event("configured.folder.open")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AeonFolderPickerAcceptance") {
            do { controller.directoryURL = try Self.prepareAcceptanceSource() }
            catch { trace("fixture_failed") }
        }
        #endif
        trace("presented")
        return controller
    }

    func refresh(_ controller: UIDocumentPickerViewController) {
        currentController = controller
        controller.delegate = self
    }

    func sheetDidDismiss() {
        guard awaitingOutcome else { return }
        // Do not release the picker/delegate here. Files can dismiss its UI immediately
        // before delegate delivery, as already observed for successful file selection.
        trace("sheet_dismissed_awaiting_callback")
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        trace("callback.entered.\(urls.count).finished.\(finished)")
        guard active, !finished, controller === currentController else {
            trace("callback.ignored")
            return
        }
        event("received.\(urls.count)")
        guard !urls.isEmpty else {
            finish(.failed("Files returned no folder. Choose a music folder and confirm the selection."))
            return
        }
        finish(.picked(urls))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
        documentPicker(controller, didPickDocumentsAt: [url])
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        trace("cancel.entered.finished.\(finished)")
        guard active, !finished, controller === currentController else { return }
        event("cancelled")
        finish(.cancelled)
    }

    private func finish(_ outcome: ImportPickerOutcome) {
        guard active, !finished else { return }
        finished = true
        active = false
        trace("delivering")
        let callback = completion
        callback(outcome)
        currentController = nil
        trace("delivered")
    }

    private func trace(_ marker: String) {
        event("folder.\(sessionID).\(marker)")
    }

    #if DEBUG
    /// Generate only source audio. Apple Files must return the directory and the real
    /// importer must create the catalogue result.
    private static func prepareAcceptanceSource() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
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
        for index in 0..<count {
            append(Int16(sin(Double(index) * 2 * .pi * 220 / Double(rate)) * 500))
        }
        try data.write(to: nested.appendingPathComponent("01 Folder Check.wav"), options: .atomic)
        return root
    }
    #endif
}

struct FolderDocumentPicker: UIViewControllerRepresentable {
    let session: FolderPickerSession

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        session.makeController()
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        session.refresh(controller)
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
