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

    func testEachPickerKindAsksForTheContentItActuallyImports() {
        XCTAssertEqual(ImportPickerKind.folder.contentTypes, [.folder])
        XCTAssertTrue(ImportPickerKind.audioFiles.allowsMultipleSelection)
        XCTAssertFalse(ImportPickerKind.folder.allowsMultipleSelection)
        XCTAssertFalse(ImportPickerKind.catalogArchive.allowsMultipleSelection)
    }
}
