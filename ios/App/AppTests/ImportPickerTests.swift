import UniformTypeIdentifiers
import XCTest
@testable import App

final class ImportPickerTests: XCTestCase {
    func testEverySupportedExtensionThatHasADeclaredTypeIsOfferedToThePicker() {
        let identifiers = Set(AeonImportContentTypes.audio.map(\.identifier))
        XCTAssertFalse(identifiers.isEmpty)
        for ext in AudioTagReader.supportedExtensions {
            // An extension with no declared type at all cannot be offered; what must not
            // happen is a type existing and the picker leaving it out, which is how FLAC
            // ended up greyed out in the Files browser.
            guard let type = UTType(filenameExtension: ext), !type.isDynamic else { continue }
            XCTAssertTrue(
                identifiers.contains(type.identifier),
                "Files with the .\(ext) extension would not be selectable"
            )
        }
    }

    func testFLACResolvesThroughTheImportedTypeDeclarationRatherThanADynamicType() {
        let flac = UTType(filenameExtension: "flac")
        XCTAssertNotNil(flac)
        XCTAssertEqual(flac?.isDynamic, false, "FLAC has no declared type, so Files greys it out")
        XCTAssertEqual(flac?.conforms(to: .audio), true)
    }

    func testAudioPickerNeverFallsBackToEveryFileOnDisk() {
        XCTAssertFalse(AeonImportContentTypes.audio.contains(.item))
        XCTAssertFalse(AeonImportContentTypes.audio.contains(.data))
    }

    func testOnlyAFolderIsOpenedInPlace() {
        // Opening someone else's file in place needs a security-scoped grant from
        // the file provider, and when that grant fails the picker reports the
        // selection as a cancel: files started working on device the moment they
        // were copied instead. A folder cannot take that route — the picker
        // raises rather than duplicating a directory, which took the app down —
        // so it is the one journey that still has to ask.
        XCTAssertTrue(ImportPickerKind.audioFiles.copiesSelection)
        XCTAssertTrue(ImportPickerKind.catalogArchive.copiesSelection)
        XCTAssertFalse(ImportPickerKind.folder.copiesSelection)
    }

    func testACopyTheSystemMadeIsToldApartFromTheUsersOwnFiles() throws {
        let temporary = FileManager.default.temporaryDirectory
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        XCTAssertTrue(PickedSelection.isSystemCopy(
            temporary.appendingPathComponent("A1B2/Nocturnes", isDirectory: true)
        ))
        XCTAssertTrue(PickedSelection.isSystemCopy(
            documents.appendingPathComponent("Inbox/track.flac")
        ))
        // The library Aeon keeps is under Documents but not in the Inbox, and
        // deleting any of it would be catastrophic.
        XCTAssertFalse(PickedSelection.isSystemCopy(
            documents.appendingPathComponent("Media/album/track.flac")
        ))
        XCTAssertFalse(PickedSelection.isSystemCopy(documents))
        XCTAssertFalse(PickedSelection.isSystemCopy(URL(fileURLWithPath: "/private/var/mobile/Music")))
    }

    func testDiscardingCopiesLeavesWhatTheUserOwnsAlone() throws {
        let manager = FileManager.default
        let copy = manager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let owned = manager.temporaryDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AeonOwned-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: copy, withIntermediateDirectories: true)
        try manager.createDirectory(at: owned, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: owned) }

        PickedSelection.discardCopies(in: [copy, owned])

        XCTAssertFalse(manager.fileExists(atPath: copy.path))
        XCTAssertTrue(manager.fileExists(atPath: owned.path))
    }

    func testEachPickerKindAsksForTheContentItActuallyImports() {
        XCTAssertEqual(ImportPickerKind.folder.contentTypes, [.folder])
        XCTAssertTrue(ImportPickerKind.audioFiles.allowsMultipleSelection)
        XCTAssertFalse(ImportPickerKind.folder.allowsMultipleSelection)
        XCTAssertFalse(ImportPickerKind.catalogArchive.allowsMultipleSelection)
    }
}
