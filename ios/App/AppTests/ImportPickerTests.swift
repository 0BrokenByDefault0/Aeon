import UIKit
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

    @MainActor
    func testAudioPickerUsesSystemCopiesAndFolderKeepsItsDirectoryGrant() {
        let audio = ImportDocumentPicker.makeController(for: .audioFiles)
        let folder = ImportDocumentPicker.makeController(for: .folder)
        XCTAssertEqual(audio.documentPickerMode, .import)
        XCTAssertEqual(folder.documentPickerMode, .open)
        XCTAssertTrue(audio.allowsMultipleSelection)
        XCTAssertFalse(folder.allowsMultipleSelection)
        XCTAssertTrue(ImportPickerKind.audioFiles.copiesSelection)
        XCTAssertFalse(ImportPickerKind.folder.copiesSelection)
        XCTAssertFalse(ImportPickerKind.catalogArchive.copiesSelection)
    }

    func testEachPickerKindAsksForTheContentItActuallyImports() {
        XCTAssertEqual(ImportPickerKind.folder.contentTypes, [.folder])
        XCTAssertTrue(ImportPickerKind.audioFiles.allowsMultipleSelection)
        XCTAssertFalse(ImportPickerKind.folder.allowsMultipleSelection)
        XCTAssertFalse(ImportPickerKind.catalogArchive.allowsMultipleSelection)
    }
}

extension ImportPickerTests {
    @objc func testSourceAccessRetainsOnlyUniqueSuccessfulGrantsUntilReleased() {
        let local = URL(fileURLWithPath: "/fixture/local.mp3")
        let external = URL(fileURLWithPath: "/fixture/external.mp3")
        var started: [URL] = []
        var ended: [URL] = []
        var access: ImportSourceAccess? = ImportSourceAccess(
            urls: [external, local, external],
            begin: { url in started.append(url); return url == external },
            end: { ended.append($0) }
        )
        XCTAssertNotNil(access)
        XCTAssertEqual(started, [external, local])
        XCTAssertTrue(ended.isEmpty)
        access = nil
        XCTAssertEqual(ended, [external])
    }

    @objc func testImportResultReportsZeroTracksAsFailureAndKeepsOriginalFilenames() {
        var result = LibraryImportResult()
        let url = URL(fileURLWithPath: "/private/provider/Unavailable.mp3")
        result.recordFailure(url, stage: "could not save the audio", error: CocoaError(.fileWriteOutOfSpace))
        XCTAssertTrue(result.userMessage.hasPrefix("No tracks were imported."))
        XCTAssertTrue(result.userMessage.contains("Unavailable.mp3: could not save the audio"))
        XCTAssertFalse(result.userMessage.contains("/private/provider"))
        XCTAssertEqual(result.failedFiles, [url])
    }

    @objc func testImportResultSeparatesSuccessDuplicatesAndPartialFailure() {
        var added = LibraryImportResult()
        added.importedAlbums = 1
        added.importedTracks = 1
        XCTAssertTrue(added.userMessage.hasPrefix("Added 1 track in 1 album to Library."))
        added.recordFailure(URL(fileURLWithPath: "/Bad.mp3"), stage: "could not decode audio")
        XCTAssertTrue(added.userMessage.contains("1 file could not be imported."))
        var duplicate = LibraryImportResult()
        duplicate.skippedDuplicateAlbums = ["Existing"]
        XCTAssertTrue(duplicate.userMessage.contains("already in your Library"))
        XCTAssertFalse(duplicate.userMessage.contains("Added"))
        var repaired = LibraryImportResult()
        repaired.repairedTracks = 2
        XCTAssertTrue(repaired.userMessage.contains("Re-linked 2 adopted tracks"))
    }

    /// Real compressed bytes, the actual picker delegate, importer, decoder, database,
    /// media store and audio engine. This is not an OS-provider or physical-iPhone test.
    @MainActor
    @objc func testPickerCallbackMP3ReachesPersistentLibraryAndProductionPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AeonImportPlayback-\(UUID().uuidString)", isDirectory: true)
        let roots = try AppStorageRoots.temporary(at: root, fileManager: .default)
        let services = try AppServices.production(roots: roots, startSpectrum: false, startPlayback: true)
        defer {
            services.playbackController.applicationDidEnterBackground()
            services.catalogDatabase.close()
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = try XCTUnwrap(Bundle(for: ImportPickerTests.self).resourceURL)
            .appendingPathComponent("audio/tone-48000.mp3")
        let selected = root.appendingPathComponent("01 Import Check.mp3")
        let bytes = try Data(contentsOf: fixture)
        try bytes.write(to: selected)
        let originalTags = try await AudioTagReader().read(url: selected, includeArtwork: false)

        var returnedURLs: [URL] = []
        var deliveries = 0
        let delegate = ImportDocumentPicker.Coordinator { outcome in
            deliveries += 1
            if case .picked(let urls) = outcome { returnedURLs = urls }
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.mp3], asCopy: false)
        delegate.documentPicker(picker, didPickDocumentsAt: [selected])
        delegate.documentPicker(picker, didPickDocumentsAt: [selected])
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(returnedURLs, [selected])

        let result = try await services.libraryImporter.importURLs(returnedURLs, mode: .single)
        XCTAssertEqual(result.importedTracks, 1, result.userMessage)
        XCTAssertEqual(result.importedAlbums, 1, result.userMessage)
        XCTAssertTrue(result.failedFiles.isEmpty, result.userMessage)
        let album = try XCTUnwrap(services.catalogRepository.albumPage().first)
        let track = try XCTUnwrap(services.catalogRepository.tracks(albumID: album.id).first)
        if let title = originalTags.title { XCTAssertEqual(track.title, title) }
        let saved = try services.mediaStore.resolve(track.mediaReference)
        guard case .documents(let path) = track.mediaReference else { return XCTFail("Imported audio must be persistent, not a temporary provider URL") }
        XCTAssertTrue(path.hasPrefix("Music/_Imported/"))
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        XCTAssertEqual(try Data(contentsOf: selected), bytes, "User source must not be rewritten")
        try FileManager.default.removeItem(at: selected)
        guard case .playable(let media) = services.metadataProbe.probe(url: saved) else { return XCTFail("Saved MP3 must decode after the selected source has disappeared") }
        XCTAssertGreaterThan(media.frameCount, 0)

        let loaded = try await command { completion in
            services.playbackCoordinator.load(trackID: track.id, mediaRef: track.mediaReference,
                queue: [QueueItem(trackID: track.id, albumID: track.albumID, mediaRef: track.mediaReference)],
                index: 0, completion: completion)
        }
        XCTAssertEqual(loaded.trackID, track.id)
        let started = try await command { services.playbackCoordinator.play(completion: $0) }
        XCTAssertEqual(started.intent, .playing)
        var observedPosition: Double = 0
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let snapshot = try await command { completion in
                services.playbackCoordinator.getState { completion(.success($0)) }
            }
            observedPosition = max(observedPosition, snapshot.position)
            if observedPosition > 0.01 { break }
        }
        _ = try await command { services.playbackCoordinator.pause(completion: $0) }
        XCTAssertGreaterThan(observedPosition, 0.01, "The production audio playhead must actually advance")
        XCTAssertEqual(services.playbackController.snapshot?.trackID, track.id)
        XCTAssertNil(services.playbackController.failure)
    }

    @MainActor
    @objc func testAdoptedMusicFolderStaysInPlaceAndPlaysThroughProductionEngine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonAdoptPlayback-\(UUID().uuidString)", isDirectory: true)
        let roots = try AppStorageRoots.temporary(at: root, fileManager: .default)
        let services = try AppServices.production(roots: roots, startSpectrum: false, startPlayback: true)
        defer {
            services.playbackController.applicationDidEnterBackground()
            services.catalogDatabase.close()
            try? FileManager.default.removeItem(at: root)
        }

        let fixture = try XCTUnwrap(Bundle(for: ImportPickerTests.self).resourceURL)
            .appendingPathComponent("audio/tone-48000.mp3")
        let source = services.mediaStore.documentsMusicRoot
            .appendingPathComponent("Adopt Artist/Adopt Album/01 Adopted.mp3")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bytes = try Data(contentsOf: fixture)
        try bytes.write(to: source, options: .atomic)

        let result = try await services.libraryImporter.adoptMusicLibrary()
        XCTAssertEqual(result.importedTracks, 1, result.userMessage)
        XCTAssertEqual(result.importedAlbums, 1, result.userMessage)
        let album = try XCTUnwrap(services.catalogRepository.albumPage().first)
        let track = try XCTUnwrap(services.catalogRepository.tracks(albumID: album.id).first)
        guard case .documents(let path) = track.mediaReference else {
            return XCTFail("Adopted music must remain a Documents reference")
        }
        XCTAssertEqual(path, "Music/Adopt Artist/Adopt Album/01 Adopted.mp3")
        XCTAssertEqual(try Data(contentsOf: source), bytes)

        let queue = [QueueItem(trackID: track.id, albumID: track.albumID, mediaRef: track.mediaReference)]
        let loaded = try await command { completion in
            services.playbackCoordinator.load(
                trackID: track.id,
                mediaRef: track.mediaReference,
                queue: queue,
                index: 0,
                completion: completion
            )
        }
        XCTAssertEqual(loaded.trackID, track.id)
        _ = try await command { services.playbackCoordinator.play(completion: $0) }
        var observedPosition: Double = 0
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let snapshot = try await command { completion in
                services.playbackCoordinator.getState { completion(.success($0)) }
            }
            observedPosition = max(observedPosition, snapshot.position)
            if observedPosition > 0.01 { break }
        }
        _ = try await command { services.playbackCoordinator.pause(completion: $0) }
        XCTAssertGreaterThan(observedPosition, 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNil(services.playbackController.failure)
    }

    @MainActor
    private func command(_ execute: (@escaping PlaybackCommandCompletion) -> Void) async throws -> PlaybackSnapshot {
        let completed = XCTestExpectation(description: "Production playback command completes")
        var result: Result<PlaybackSnapshot, PlaybackFailure>?
        execute { result = $0; completed.fulfill() }
        let status = await XCTWaiter.fulfillment(of: [completed], timeout: 10)
        XCTAssertEqual(status, .completed)
        return try XCTUnwrap(result).get()
    }
}
