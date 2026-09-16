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
        // Opening a file in place needs a security-scoped grant from the file
        // provider. When that grant fails the picker reports the selection as a
        // cancel and the import silently never starts, which is what happened on
        // device. Aeon copies audio into its own library anyway, so only the
        // folder — whose bookmark is the entire point — is opened in place.
        XCTAssertTrue(ImportPickerKind.audioFiles.copiesSelection)
        XCTAssertTrue(ImportPickerKind.catalogArchive.copiesSelection)
        XCTAssertFalse(ImportPickerKind.folder.copiesSelection)
    }

    func testEachPickerKindAsksForTheContentItActuallyImports() {
        XCTAssertEqual(ImportPickerKind.folder.contentTypes, [.folder])
        XCTAssertTrue(ImportPickerKind.audioFiles.allowsMultipleSelection)
        XCTAssertFalse(ImportPickerKind.folder.allowsMultipleSelection)
        XCTAssertFalse(ImportPickerKind.catalogArchive.allowsMultipleSelection)
    }
}
