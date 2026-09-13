import UIKit
import XCTest
@testable import App

final class AudioTagReaderTests: XCTestCase {
    private var root: URL!
    private var fixturesURL: URL {
        Bundle(for: AudioTagReaderTests.self).resourceURL!.appendingPathComponent("audio", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeonAudioTagReaderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSupportedImportFormatsAreExplicit() {
        XCTAssertEqual(
            AudioTagReader.supportedExtensions,
            Set(["mp3", "m4a", "aac", "alac", "flac", "wav", "wave", "aif", "aiff", "caf"])
        )
    }

    func testID3ReadsUnicodePunctuationNumbersAndBoundedArtwork() async throws {
        let art = try jpegData()
        let tagged = root.appendingPathComponent("01 - L’été!.mp3")
        let payload = try Data(contentsOf: fixturesURL.appendingPathComponent("tone-48000.mp3"))
        try (id3Tag([
            textFrame("TIT2", "L’été!"), textFrame("TPE1", "Björk & Guests"),
            textFrame("TPE2", "Björk"), textFrame("TALB", "Signals (Deluxe Edition)"),
            textFrame("TDRC", "2026-04-03"), textFrame("TCON", "Electronic / Ambient"),
            textFrame("TRCK", "1/12"), textFrame("TPOS", "2/2"), pictureFrame(art)
        ]) + payload).write(to: tagged)

        let tags = try await AudioTagReader().read(url: tagged, includeArtwork: true)
        XCTAssertEqual(tags.title, "L’été!")
        XCTAssertEqual(tags.artist, "Björk & Guests")
        XCTAssertEqual(tags.albumArtist, "Björk")
        XCTAssertEqual(tags.album, "Signals (Deluxe Edition)")
        XCTAssertEqual(tags.year, "2026")
        XCTAssertEqual(tags.genre, "Electronic / Ambient")
        XCTAssertEqual(tags.trackNumber, 1)
        XCTAssertEqual(tags.discNumber, 2)
        XCTAssertEqual(tags.artworkData, art)

        let withoutArt = try await AudioTagReader().read(url: tagged, includeArtwork: false)
        XCTAssertNil(withoutArt.artworkData)
    }

    func testFLACSupplementReadsCommentsWithoutAudioPayload() async throws {
        let url = root.appendingPathComponent("tone.flac")
        try flacComments([
            "TITLE=Stone & Glass", "ARTIST=One/Two", "ALBUM=Archive [Remastered]",
            "ALBUMARTIST=Various Artists", "DATE=1999-10-01", "GENRE=Post-Rock",
            "TRACKNUMBER=7/10", "DISCNUMBER=2"
        ]).write(to: url)

        let tags = try await AudioTagReader().read(url: url, includeArtwork: false)
        XCTAssertEqual(tags.title, "Stone & Glass")
        XCTAssertEqual(tags.artist, "One/Two")
        XCTAssertEqual(tags.album, "Archive [Remastered]")
        XCTAssertEqual(tags.albumArtist, "Various Artists")
        XCTAssertEqual(tags.year, "1999")
        XCTAssertEqual(tags.genre, "Post-Rock")
        XCTAssertEqual(tags.trackNumber, 7)
        XCTAssertEqual(tags.discNumber, 2)
    }

    func testMissingTagsUseFilenameAndBadOrOversizedArtDoesNotFailProcessing() async throws {
        let wav = root.appendingPathComponent("03 - Untagged.wav")
        try FileManager.default.copyItem(at: fixturesURL.appendingPathComponent("pcm-44100.wav"), to: wav)
        let tags = try await AudioTagReader().read(url: wav, includeArtwork: true)
        XCTAssertEqual(tags.title, "03 - Untagged")

        let artworkRoot = root.appendingPathComponent("Artwork", isDirectory: true)
        let store = try ArtworkStore(rootURL: artworkRoot, maximumInputBytes: 1_024)
        let processor = ArtworkProcessor(store: store, maximumInputBytes: 1_024, maximumPixelSize: 64)
        XCTAssertNil(processor.process(Data("not an image".utf8), key: "bad"))
        XCTAssertNil(processor.process(Data(repeating: 1, count: 1_025), key: "large"))
        XCTAssertNotNil(processor.process(try jpegData(), key: "valid"))
    }

    func testGroupingPortsSingleFolderSmartMajorityAndDuplicateAlbumRules() {
        let items = [
            candidate("/A/Live/10 Finale.wav", folder: "Live", folderKey: "A/Live", album: "Orbit", artist: "The Æons", albumArtist: "The Æons", year: "2024", genre: "Ambient", track: nil, disc: nil),
            candidate("/A/Live/2 Start.wav", folder: "Live", folderKey: "A/Live", album: "Orbit (Deluxe Edition)", artist: "The Æons", albumArtist: "The Æons", year: "2024", genre: "Ambient", track: nil, disc: nil),
            candidate("/B/Live/B2 Vinyl.wav", folder: "Live", folderKey: "B/Live", album: "Orbit", artist: "Other Artist", albumArtist: "Other Artist", year: "2025", genre: "Rock", track: nil, disc: nil)
        ]
        XCTAssertEqual(ImportGrouper.group(items, mode: .single).count, 2, "different full folder paths split a selection")
        XCTAssertEqual(ImportGrouper.group(items, mode: .folder).count, 2)
        let smart = ImportGrouper.group(items, mode: .smart)
        XCTAssertEqual(smart.count, 2, "title variants merge only for the same normalized artist")
        let aeons = smart.first { $0.contains(where: { $0.tags.albumArtist == "The Æons" }) }!
        XCTAssertEqual(ImportGrouper.sortAlbumItems(aeons).map(\.url.lastPathComponent), ["2 Start.wav", "10 Finale.wav"])
        let fields = ImportGrouper.albumFields(for: aeons, batchLabel: "Ignored")
        XCTAssertEqual(fields.title, "Orbit")
        XCTAssertEqual(fields.artist, "The Æons")
        XCTAssertEqual(fields.year, "2024")
        XCTAssertEqual(fields.genre, "Ambient")
        XCTAssertTrue(ImportGrouper.isDuplicate(
            existingTitle: "Orbit [Remastered]", existingArtist: "The Æons!",
            existingTrackCount: 2, candidate: fields, candidateTrackCount: 2
        ))
    }

    func testOrderingHandlesMultiDiscVinylMissingNumbersAndNaturalNames() {
        let items = [
            candidate("10 Last.wav"), candidate("2 Second.wav"), candidate("B2 Side.wav"),
            candidate("1-04 Disc.wav"), candidate("Loose 20.wav"), candidate("Loose 3.wav"),
            candidate("tagged.wav", track: 1, disc: 2)
        ]
        XCTAssertEqual(
            ImportGrouper.sortAlbumItems(items).map(\.url.lastPathComponent),
            ["2 Second.wav", "10 Last.wav", "Loose 3.wav", "Loose 20.wav", "1-04 Disc.wav", "tagged.wav", "B2 Side.wav"]
        )
        XCTAssertEqual(ImportGrouper.trackNumbers(from: "[2.07] Name.flac"), .init(disc: 2, track: 7))
        XCTAssertEqual(ImportGrouper.trackNumbers(from: "A2 Name.aiff"), .init(disc: 1, track: 2))
    }

    func testCompilationUsesAlbumArtistAndTenThousandCandidatesStayPayloadFree() {
        let compilation = (0 ..< 4).map { index in
            candidate("/Comp/0\(index + 1).wav", folder: "Comp", folderKey: "Comp", album: "Collected", artist: "Artist \(index)", albumArtist: "Various Artists")
        }
        XCTAssertEqual(ImportGrouper.group(compilation, mode: .smart).count, 1)
        XCTAssertEqual(ImportGrouper.albumFields(for: compilation, batchLabel: "").artist, "Various Artists")

        let large = (0 ..< 10_000).map { candidate("/Large/\($0).wav", folder: "Large", folderKey: "Large", album: "Scale", artist: "Aeon") }
        let groups = ImportGrouper.group(large, mode: .smart)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 10_000)
        XCTAssertTrue(groups[0].allSatisfy { $0.tags.artworkData == nil })
    }

    private func candidate(
        _ path: String,
        folder: String = "Album",
        folderKey: String = "Album",
        album: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        year: String? = nil,
        genre: String? = nil,
        track: Int? = nil,
        disc: Int? = nil
    ) -> ImportCandidate {
        ImportCandidate(
            url: URL(fileURLWithPath: path), folder: folder, folderKey: folderKey, batchLabel: folder,
            tags: AudioTags(title: nil, artist: artist, albumArtist: albumArtist, album: album, year: year,
                            genre: genre, trackNumber: track, discNumber: disc, artworkData: nil),
            selectionIndex: 0
        )
    }

    private func textFrame(_ id: String, _ text: String) -> Data {
        var payload = Data([3]); payload.append(Data(text.utf8))
        return frame(id, payload)
    }

    private func pictureFrame(_ image: Data) -> Data {
        var payload = Data([3]); payload.append(Data("image/jpeg".utf8)); payload.append(0); payload.append(3); payload.append(0); payload.append(image)
        return frame("APIC", payload)
    }

    private func frame(_ id: String, _ payload: Data) -> Data {
        var data = Data(id.utf8)
        let size = UInt32(payload.count)
        data.append(contentsOf: [
            UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff), UInt8(size & 0xff), 0, 0
        ])
        data.append(payload)
        return data
    }

    private func id3Tag(_ frames: [Data]) -> Data {
        let body = frames.reduce(into: Data()) { $0.append($1) }
        let size = body.count
        var data = Data([0x49, 0x44, 0x33, 3, 0, 0,
                         UInt8((size >> 21) & 0x7f), UInt8((size >> 14) & 0x7f),
                         UInt8((size >> 7) & 0x7f), UInt8(size & 0x7f)])
        data.append(body)
        return data
    }

    private func flacComments(_ comments: [String]) -> Data {
        var block = Data()
        func appendLE(_ value: UInt32) {
            block.append(contentsOf: [UInt8(value), UInt8(value >> 8), UInt8(value >> 16), UInt8(value >> 24)])
        }
        let vendor = Data("Aeon".utf8)
        appendLE(UInt32(vendor.count)); block.append(vendor); appendLE(UInt32(comments.count))
        for comment in comments { let bytes = Data(comment.utf8); appendLE(UInt32(bytes.count)); block.append(bytes) }
        var data = Data("fLaC".utf8)
        data.append(0x84)
        data.append(contentsOf: [UInt8(block.count >> 16), UInt8(block.count >> 8), UInt8(block.count)])
        data.append(block)
        return data
    }

    private func jpegData() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.85))
    }
}
