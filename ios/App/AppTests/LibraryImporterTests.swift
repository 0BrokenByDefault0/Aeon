import XCTest
@testable import App

final class LibraryImporterTests: XCTestCase {
    private var root: URL!
    private var database: CatalogDatabase!
    private var repository: CatalogRepository!
    private var mediaStore: MediaStore!
    private var artworkStore: ArtworkStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AeonLibraryImporterTests/\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        database = try CatalogDatabase(rootURL: support.appendingPathComponent("Aeon", isDirectory: true))
        repository = CatalogRepository(database: database)
        mediaStore = try MediaStore(baseURL: support, documentsRoot: documents)
        artworkStore = try ArtworkStore(rootURL: support.appendingPathComponent("Aeon/Artwork", isDirectory: true))
    }

    override func tearDown() {
        database?.close(); database = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testExternalFilesCopyThroughIncomingWhileMusicFilesAreAdoptedInPlace() async throws {
        let external = root.appendingPathComponent("External/01 External.wav")
        let adopted = mediaStore.documentsMusicRoot.appendingPathComponent("Artist/Album/02 Adopted.wav")
        try writeAudio(external); try writeAudio(adopted)
        let reader = StubTagReader(values: [
            external.lastPathComponent: AudioTags(title: "External", artist: "Artist", albumArtist: nil, album: "Album", year: "2026", genre: "Ambient", trackNumber: 1, discNumber: 1, artworkData: nil),
            adopted.lastPathComponent: AudioTags(title: "Adopted", artist: "Artist", albumArtist: nil, album: "Album", year: "2026", genre: "Ambient", trackNumber: 2, discNumber: 1, artworkData: nil)
        ])
        let importer = makeImporter(reader: reader, probe: StubProbe())

        let result = try await importer.importURLs([external, adopted], mode: .smart)
        XCTAssertEqual(result.importedAlbums, 1)
        XCTAssertEqual(result.importedTracks, 2)
        let album = try XCTUnwrap(repository.albumPage().first)
        let tracks = try repository.tracks(albumID: album.id)
        guard case .documents(let copiedPath) = tracks[0].mediaReference,
              case .documents(let adoptedPath) = tracks[1].mediaReference else { return XCTFail("Expected document references") }
        XCTAssertTrue(copiedPath.hasPrefix("Music/_Imported/"))
        XCTAssertEqual(adoptedPath, "Music/Artist/Album/02 Adopted.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try mediaStore.resolve(tracks[0].mediaReference).path))
        XCTAssertEqual(try Data(contentsOf: adopted), Data("audio".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: mediaStore.documentsIncomingRoot, includingPropertiesForKeys: nil).count, 0)
    }

    func testPartialFailureCommitsVerifiedTracksAndNeverPublishesAnEmptyAlbumShell() async throws {
        let good = root.appendingPathComponent("Partial/01 Good.wav")
        let bad = root.appendingPathComponent("Partial/02 Corrupt.wav")
        try writeAudio(good); try Data("bad".utf8).write(to: bad)
        let tags = AudioTags(title: nil, artist: "Aeon", albumArtist: nil, album: "Partial", year: nil, genre: nil, trackNumber: nil, discNumber: nil, artworkData: nil)
        let importer = makeImporter(reader: StubTagReader(values: [good.lastPathComponent: tags, bad.lastPathComponent: tags]), probe: StubProbe(failures: [bad.lastPathComponent]))

        let result = try await importer.importURLs([good, bad], mode: .single)
        XCTAssertEqual(result.importedAlbums, 1)
        XCTAssertEqual(result.importedTracks, 1)
        XCTAssertEqual(result.failedFiles.map(\.lastPathComponent), [bad.lastPathComponent])
        let album = try XCTUnwrap(repository.albumPage().first)
        XCTAssertEqual(try repository.tracks(albumID: album.id).count, 1)

        let onlyBad = root.appendingPathComponent("Empty/Only Corrupt.wav")
        try writeAudio(onlyBad)
        try Data("bad".utf8).write(to: onlyBad)
        let second = makeImporter(reader: StubTagReader(values: [onlyBad.lastPathComponent: tags]), probe: StubProbe(failures: [onlyBad.lastPathComponent]))
        let empty = try await second.importURLs([onlyBad], mode: .single)
        XCTAssertEqual(empty.importedAlbums, 0)
        XCTAssertEqual(try repository.albumPage().count, 1)
    }

    func testCancellationPersistsGroupCursorAndSameSelectionResumesWithoutDuplicates() async throws {
        let first = root.appendingPathComponent("Folders/First/01 First.wav")
        let second = root.appendingPathComponent("Folders/Second/01 Second.wav")
        try writeAudio(first); try writeAudio(second)
        let reader = StubTagReader(values: [
            first.lastPathComponent: AudioTags(title: "One", artist: "A", albumArtist: nil, album: "First", year: nil, genre: nil, trackNumber: 1, discNumber: nil, artworkData: nil),
            second.lastPathComponent: AudioTags(title: "Two", artist: "B", albumArtist: nil, album: "Second", year: nil, genre: nil, trackNumber: 1, discNumber: nil, artworkData: nil)
        ])
        let token = LibraryImportCancellation()
        let importer = makeImporter(reader: reader, probe: StubProbe())
        var committed = 0
        do {
            _ = try await importer.importURLs([first, second], mode: .folder, cancellation: token) { progress in
                if progress.phase == .committing, progress.completedGroups == 1 { committed += 1; token.cancel() }
            }
            XCTFail("Cancellation must stop before the second group")
        } catch LibraryImportError.cancelled {}
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(try repository.albumPage().count, 1)

        let resumed = try await importer.importURLs([first, second], mode: .folder)
        XCTAssertEqual(resumed.importedAlbums, 1)
        XCTAssertEqual(try repository.albumPage().count, 2)
        XCTAssertEqual(Set(try repository.albumPage().map(\.title)), Set(["First", "Second"]))
    }

    func testDuplicateAlbumRuleSkipsSecondImportAndProbeWorkStaysBounded() async throws {
        let files = (0 ..< 64).map { index -> URL in
            let url = root.appendingPathComponent("Scale/\(index + 1).wav")
            try! writeAudio(url)
            return url
        }
        let tags = Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, AudioTags(title: nil, artist: "Scale", albumArtist: nil, album: "Scale", year: nil, genre: nil, trackNumber: nil, discNumber: nil, artworkData: nil)) })
        let probe = StubProbe()
        let importer = makeImporter(reader: StubTagReader(values: tags), probe: probe)
        let initial = try await importer.importURLs(files, mode: .single)
        XCTAssertEqual(initial.importedAlbums, 1)
        let duplicate = try await importer.importURLs(files, mode: .single)
        XCTAssertEqual(duplicate.importedAlbums, 0)
        XCTAssertEqual(duplicate.skippedDuplicateAlbums, ["Scale"])
        XCTAssertLessThanOrEqual(probe.peakConcurrentCalls, LibraryImporter.maximumConcurrentProbes)
    }

    func testUnreachableSelectionReportsAccessDeniedInsteadOfSucceedingSilently() async throws {
        let missing = root.appendingPathComponent("Gone/01 Missing.wav")
        let importer = makeImporter(reader: StubTagReader(values: [:]), probe: StubProbe())

        do {
            _ = try await importer.importURLs([missing], mode: .smart)
            XCTFail("Expected an access failure")
        } catch {
            XCTAssertEqual(error as? LibraryImportError, .accessDenied)
        }
    }

    func testUndownloadedICloudPlaceholdersAreTreatedAsTheFilesTheyStandForRatherThanSkipped() async throws {
        let folder = root.appendingPathComponent("Cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // What iCloud Drive leaves on disk for a file whose contents are not local.
        try Data().write(to: folder.appendingPathComponent(".01 Remote.flac.icloud"))
        let importer = makeImporter(reader: StubTagReader(values: [:]), probe: StubProbe())

        do {
            _ = try await importer.importURLs([folder], mode: .folder)
            XCTFail("Expected the placeholder to be reported as unavailable")
        } catch {
            // Found, attempted, and reported — not silently skipped into an empty folder.
            XCTAssertEqual(error as? LibraryImportError, .sourceUnavailable)
        }
    }

    func testFolderWithoutAnySupportedAudioStillReportsNoSupportedAudio() async throws {
        let folder = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let importer = makeImporter(reader: StubTagReader(values: [:]), probe: StubProbe())

        do {
            _ = try await importer.importURLs([folder], mode: .folder)
            XCTFail("Expected no supported audio")
        } catch {
            XCTAssertEqual(error as? LibraryImportError, .noSupportedAudio)
        }
    }

    func testNestedFoldersAreDiscoveredRecursivelyWhileHiddenDirectoriesAreLeftAlone() async throws {
        let folder = root.appendingPathComponent("Collection", isDirectory: true)
        let nested = folder.appendingPathComponent("Artist/Album", isDirectory: true)
        let hidden = folder.appendingPathComponent(".Trash", isDirectory: true)
        let track = nested.appendingPathComponent("01 Deep.wav")
        let trashed = hidden.appendingPathComponent("02 Trashed.wav")
        try writeAudio(track); try writeAudio(trashed)
        let tags = AudioTags(title: "Deep", artist: "Artist", albumArtist: nil, album: "Album", year: nil, genre: nil, trackNumber: 1, discNumber: nil, artworkData: nil)
        let importer = makeImporter(
            reader: StubTagReader(values: [track.lastPathComponent: tags, trashed.lastPathComponent: tags]),
            probe: StubProbe()
        )

        let result = try await importer.importURLs([folder], mode: .folder)
        XCTAssertEqual(result.importedTracks, 1)
        let album = try XCTUnwrap(repository.albumPage().first)
        XCTAssertEqual(try repository.tracks(albumID: album.id).map(\.title), ["Deep"])
    }

    func testAdoptMusicLibraryScansUserFoldersInPlaceSkipsManagedRootsAndRescansIdempotently() async throws {
        let first = mediaStore.documentsMusicRoot.appendingPathComponent("Artist One/Album One/01 First.wav")
        let second = mediaStore.documentsMusicRoot.appendingPathComponent("Artist Two/Album Two/01 Second.wav")
        let third = mediaStore.documentsMusicRoot.appendingPathComponent("Artist Three/Album Three/01 Third.wav")
        let managedImported = mediaStore.documentsMusicRoot.appendingPathComponent("_Imported/internal/managed.wav")
        let managedMigrated = mediaStore.documentsMusicRoot.appendingPathComponent("_Migrated/managed.wav")
        let managedRestored = mediaStore.documentsMusicRoot.appendingPathComponent("_Restored/op/managed.wav")
        for url in [first, second, managedImported, managedMigrated, managedRestored] { try writeAudio(url) }

        let reader = StubTagReader(values: [
            first.lastPathComponent: AudioTags(title: "First", artist: "Artist One", albumArtist: nil, album: nil, year: nil, genre: nil, trackNumber: 1, discNumber: nil, artworkData: nil),
            second.lastPathComponent: AudioTags(title: "Second", artist: "Artist Two", albumArtist: nil, album: nil, year: nil, genre: nil, trackNumber: 1, discNumber: nil, artworkData: nil),
            third.lastPathComponent: AudioTags(title: "Third", artist: "Artist Three", albumArtist: nil, album: nil, year: nil, genre: nil, trackNumber: 1, discNumber: nil, artworkData: nil)
        ])
        let probe = StubProbe()
        let importer = makeImporter(reader: reader, probe: probe)

        let initial = try await importer.adoptMusicLibrary()
        XCTAssertEqual(initial.importedAlbums, 2)
        XCTAssertEqual(initial.importedTracks, 2)
        XCTAssertTrue(initial.failedFiles.isEmpty)

        let albums = try repository.albumPage(offset: 0, limit: 10, sort: .title)
        XCTAssertEqual(Set(albums.map(\.title)), Set(["Album One", "Album Two"]))
        var adoptedPaths: [String] = []
        for album in albums {
            for track in try repository.tracks(albumID: album.id) {
                guard case .documents(let path) = track.mediaReference else {
                    return XCTFail("Adopted audio must remain a Documents reference")
                }
                adoptedPaths.append(path)
            }
        }
        XCTAssertEqual(Set(adoptedPaths), Set([
            "Music/Artist One/Album One/01 First.wav",
            "Music/Artist Two/Album Two/01 Second.wav"
        ]))
        XCTAssertEqual(try Data(contentsOf: first), Data("audio".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("audio".utf8))
        let tagReadsAfterInitial = reader.callCount
        let probesAfterInitial = probe.callCount

        // Simulate an upgrade from the pre-index build. Existing Documents references
        // bootstrap the index without decoding the collection one more time.
        try repository.removeSetting(forKey: "library.import.adopted-index.v1")
        let rescan = try await importer.adoptMusicLibrary()
        XCTAssertEqual(rescan.importedAlbums, 0)
        XCTAssertEqual(rescan.importedTracks, 0)
        XCTAssertEqual(rescan.unchangedFiles, 2)
        XCTAssertTrue(rescan.skippedDuplicateAlbums.isEmpty)
        XCTAssertEqual(reader.callCount, tagReadsAfterInitial)
        XCTAssertEqual(probe.callCount, probesAfterInitial)
        XCTAssertEqual(try repository.albumCount(), 2)

        let indexedRescan = try await importer.adoptMusicLibrary()
        XCTAssertEqual(indexedRescan.enumeratedFiles, 0, "unchanged album folders should be reused from the directory index")
        XCTAssertEqual(indexedRescan.unchangedFiles, 2)

        try writeAudio(third)
        let update = try await importer.adoptMusicLibrary()
        XCTAssertEqual(update.importedAlbums, 1)
        XCTAssertEqual(update.importedTracks, 1)
        XCTAssertEqual(update.unchangedFiles, 2)
        XCTAssertEqual(update.enumeratedFiles, 1, "only the newly added album folder should enumerate audio files")
        XCTAssertEqual(reader.callCount - tagReadsAfterInitial, 2, "only the new file should receive tag and artwork reads")
        XCTAssertEqual(probe.callCount - probesAfterInitial, 2, "only the new file should be decoded and verified")
        XCTAssertEqual(try repository.albumCount(), 3)
    }

    func testAdoptIndexRefreshesOnlyModifiedFilesAndPreservesMissingCatalogueEntries() async throws {
        let file = mediaStore.documentsMusicRoot.appendingPathComponent("Artist/Album/01 Track.wav")
        try writeAudio(file)
        let reader = StubTagReader(values: [
            file.lastPathComponent: AudioTags(title: "Track", artist: "Artist", albumArtist: nil, album: "Album", year: nil, genre: nil, trackNumber: 1, discNumber: 1, artworkData: nil)
        ])
        let probe = StubProbe()
        let importer = makeImporter(reader: reader, probe: probe)
        let initial = try await importer.adoptMusicLibrary()
        XCTAssertEqual(initial.importedTracks, 1)
        let album = try XCTUnwrap(repository.albumPage().first)
        let track = try XCTUnwrap(repository.tracks(albumID: album.id).first)
        let reads = reader.callCount
        let probes = probe.callCount

        try Data("audio changed".utf8).write(to: file, options: .atomic)
        let modified = try await importer.adoptMusicLibrary()
        XCTAssertEqual(modified.updatedTracks, 1)
        XCTAssertEqual(modified.importedAlbums, 0)
        XCTAssertEqual(reader.callCount, reads + 1)
        XCTAssertEqual(probe.callCount, probes + 1)
        XCTAssertEqual(try repository.track(id: track.id)?.byteCount, Int64("audio changed".utf8.count))

        try FileManager.default.removeItem(at: file)
        let missing = try await importer.adoptMusicLibrary()
        XCTAssertEqual(missing.missingFiles, 1)
        XCTAssertEqual(try repository.albumCount(), 1)
        XCTAssertNotNil(try repository.track(id: track.id))
    }

    func testAdoptRescanRelinksMovedAlbumWithoutChangingTrackIdentity() async throws {
        let original = mediaStore.documentsMusicRoot.appendingPathComponent("Artist/Original Folder/01 Move Me.wav")
        try writeAudio(original)
        let tags = AudioTags(
            title: "Move Me", artist: "Artist", albumArtist: nil, album: "Stable Album",
            year: nil, genre: nil, trackNumber: 1, discNumber: 1, artworkData: nil
        )
        let importer = makeImporter(
            reader: StubTagReader(values: [original.lastPathComponent: tags]),
            probe: StubProbe()
        )

        let first = try await importer.adoptMusicLibrary()
        XCTAssertEqual(first.importedTracks, 1)
        let album = try XCTUnwrap(repository.albumPage().first)
        let before = try XCTUnwrap(repository.tracks(albumID: album.id).first)
        let beforeID = before.id

        let moved = mediaStore.documentsMusicRoot.appendingPathComponent("Artist/New Folder/01 Move Me.wav")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)

        let repaired = try await importer.adoptMusicLibrary()
        XCTAssertEqual(repaired.importedAlbums, 0)
        XCTAssertEqual(repaired.importedTracks, 0)
        XCTAssertEqual(repaired.repairedTracks, 1)
        let after = try XCTUnwrap(repository.track(id: beforeID))
        XCTAssertEqual(after.id, beforeID)
        guard case .documents(let path) = after.mediaReference else {
            return XCTFail("Repaired adopted audio must remain a Documents reference")
        }
        XCTAssertEqual(path, "Music/Artist/New Folder/01 Move Me.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try mediaStore.resolve(after.mediaReference).path))
        XCTAssertEqual(try repository.albumCount(), 1)
    }

    private func makeImporter(reader: AudioTagReading, probe: MediaProbing) -> LibraryImporter {
        LibraryImporter(
            repository: repository, mediaStore: mediaStore,
            tagReader: reader, artworkProcessor: ArtworkProcessor(store: artworkStore),
            metadataProbe: probe, metadataEnricher: nil,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            downloadTimeout: 0.2
        )
    }

    private func writeAudio(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
    }
}

private final class StubTagReader: AudioTagReading {
    let values: [String: AudioTags]
    private(set) var callCount = 0
    init(values: [String: AudioTags]) { self.values = values }
    func read(url: URL, includeArtwork: Bool) async throws -> AudioTags {
        callCount += 1
        var value = values[url.lastPathComponent] ?? AudioTags(title: nil)
        if !includeArtwork { value.artworkData = nil }
        return value
    }
}

private final class StubProbe: MediaProbing {
    let failures: Set<String>
    private let lock = NSLock()
    private(set) var peakConcurrentCalls = 0
    private(set) var callCount = 0
    private var activeCalls = 0
    init(failures: Set<String> = []) { self.failures = failures }
    func probe(url: URL) -> MediaCapability {
        lock.lock(); callCount += 1; activeCalls += 1; peakConcurrentCalls = max(peakConcurrentCalls, activeCalls); lock.unlock()
        defer { lock.lock(); activeCalls -= 1; lock.unlock() }
        if failures.contains(url.lastPathComponent) { return .decodeFailed(reason: "fixture") }
        return .playable(ProbedMedia(
            url: url,
            descriptor: SourceFormatDescriptor(codec: "pcm_s16le", container: "wav", sampleRate: 48_000, channelCount: 2, bitDepth: 16, duration: 1),
            frameCount: 48_000
        ))
    }
}
