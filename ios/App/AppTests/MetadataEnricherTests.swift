import XCTest
@testable import App

final class MetadataEnricherTests: XCTestCase {
    private var root: URL!
    private var database: CatalogDatabase!
    private var repository: CatalogRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AeonMetadataEnricherTests/\(UUID().uuidString)", isDirectory: true)
        database = try CatalogDatabase(rootURL: root)
        repository = CatalogRepository(database: database)
    }

    override func tearDown() {
        database?.close(); database = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAutomaticLookupIsOffByDefault() async throws {
        let first = StubGenreProvider(result: "Ambient")
        let enricher = MetadataEnricher(repository: repository, musicBrainz: first, apple: StubGenreProvider(result: "Electronic"))
        let genre = try await enricher.automaticGenre(for: "Stars of the Lid")
        XCTAssertNil(genre)
        XCTAssertEqual(first.calls, [])
    }

    func testMusicBrainzWinsAndSuccessfulCanonicalArtistIsPermanent() async throws {
        try repository.setSetting(true, forKey: MetadataEnricher.lookupEnabledKey)
        let musicBrainz = StubGenreProvider(result: "Ambient")
        let apple = StubGenreProvider(result: "Electronic")
        let enricher = MetadataEnricher(repository: repository, musicBrainz: musicBrainz, apple: apple, now: { Date(timeIntervalSince1970: 100) })

        let firstGenre = try await enricher.automaticGenre(for: "Björk!")
        let cachedGenre = try await enricher.automaticGenre(for: "  bjork  ")
        XCTAssertEqual(firstGenre, "Ambient")
        XCTAssertEqual(cachedGenre, "Ambient")
        XCTAssertEqual(musicBrainz.calls, ["bjork"])
        XCTAssertEqual(apple.calls, [])
        XCTAssertEqual(try enricher.cachedEntry(for: "BJÖRK")?.provider, .musicBrainz)
    }

    func testAppleIsSecondAndNoMatchDoesNotRetryAutomatically() async throws {
        try repository.setSetting(true, forKey: MetadataEnricher.lookupEnabledKey)
        let musicBrainz = StubGenreProvider(result: nil)
        let apple = StubGenreProvider(result: "Alternative")
        let enricher = MetadataEnricher(repository: repository, musicBrainz: musicBrainz, apple: apple)
        let fallbackGenre = try await enricher.automaticGenre(for: "Artist")
        XCTAssertEqual(fallbackGenre, "Alternative")
        XCTAssertEqual(musicBrainz.calls.count, 1)
        XCTAssertEqual(apple.calls.count, 1)

        let noneFirst = StubGenreProvider(result: nil)
        let noneSecond = StubGenreProvider(result: nil)
        let noMatch = MetadataEnricher(repository: repository, musicBrainz: noneFirst, apple: noneSecond)
        let firstMiss = try await noMatch.automaticGenre(for: "Unknown Name")
        let cachedMiss = try await noMatch.automaticGenre(for: "Unknown Name")
        XCTAssertNil(firstMiss)
        XCTAssertNil(cachedMiss)
        XCTAssertEqual(noneFirst.calls.count, 1)
        XCTAssertEqual(noneSecond.calls.count, 1)
    }

    func testProviderFailureFallsThroughAndCachesTheAnswer() async throws {
        try repository.setSetting(true, forKey: MetadataEnricher.lookupEnabledKey)
        let apple = StubGenreProvider(result: "Soul")
        let enricher = MetadataEnricher(
            repository: repository,
            musicBrainz: ThrowingGenreProvider(),
            apple: apple
        )
        let genre = try await enricher.automaticGenre(for: "Artist")
        let cached = try await enricher.automaticGenre(for: "Artist")
        XCTAssertEqual(genre, "Soul")
        XCTAssertEqual(cached, "Soul")
        XCTAssertEqual(apple.calls.count, 1)
    }

    func testManualLookupCanReplaceCacheOnlyAfterStarMoveConfirmation() async throws {
        try repository.setSetting(true, forKey: MetadataEnricher.lookupEnabledKey)
        let initial = MetadataEnricher(repository: repository, musicBrainz: StubGenreProvider(result: "Rock"), apple: StubGenreProvider(result: nil))
        let initialGenre = try await initial.automaticGenre(for: "Aeon")
        XCTAssertEqual(initialGenre, "Rock")

        let replacement = MetadataEnricher(repository: repository, musicBrainz: StubGenreProvider(result: "Electronic"), apple: StubGenreProvider(result: nil))
        var confirmations: [(String?, String)] = []
        let rejected = try await replacement.manualLookup(for: "Aeon") { old, new in
            confirmations.append((old, new)); return false
        }
        XCTAssertNil(rejected)
        XCTAssertEqual(try replacement.cachedEntry(for: "Aeon")?.genre, "Rock")
        let accepted = try await replacement.manualLookup(for: "Aeon") { old, new in
            confirmations.append((old, new)); return true
        }
        XCTAssertEqual(accepted, "Electronic")
        XCTAssertEqual(try replacement.cachedEntry(for: "Aeon")?.genre, "Electronic")
        XCTAssertEqual(confirmations.map { $0.1 }, ["Electronic", "Electronic"])
    }

    func testMusicBrainzGateSpacesConsecutiveRequests() async throws {
        let gate = MusicBrainzRequestGate(interval: 0.3)
        let start = Date()
        try await gate.waitForTurn()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25)
        try await gate.waitForTurn()
        try await gate.waitForTurn()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.55)
    }

    func testMusicBrainzUserAgentCarriesContactURL() {
        XCTAssertTrue(MusicBrainzGenreProvider.userAgent.hasPrefix("Aeon/"))
        XCTAssertTrue(MusicBrainzGenreProvider.userAgent.contains("( https://"))
    }
}

private final class StubGenreProvider: ArtistGenreProviding {
    let result: String?
    private(set) var calls: [String] = []
    init(result: String?) { self.result = result }
    func genre(for canonicalArtist: String) async throws -> String? { calls.append(canonicalArtist); return result }
}

private final class ThrowingGenreProvider: ArtistGenreProviding {
    func genre(for canonicalArtist: String) async throws -> String? { throw URLError(.timedOut) }
}
