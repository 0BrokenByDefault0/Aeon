import CryptoKit
import Foundation

protocol ArtistGenreProviding {
    func genre(for canonicalArtist: String) async throws -> String?
}

enum MetadataGenreProvider: String, Codable, Equatable {
    case musicBrainz
    case apple
    case noMatch
}

struct MetadataGenreCacheEntry: Codable, Equatable {
    let canonicalArtist: String
    let genre: String?
    let provider: MetadataGenreProvider
    let checkedAt: Date
}

final class MetadataEnricher {
    static let lookupEnabledKey = "metadata.genre_lookup.enabled"
    private static let cachePrefix = "metadata.genre_cache."

    private let repository: CatalogRepository
    private let musicBrainz: ArtistGenreProviding
    private let apple: ArtistGenreProviding
    private let now: () -> Date
    private let failureLock = NSLock()
    private var failures: [String: Date] = [:]

    init(
        repository: CatalogRepository,
        musicBrainz: ArtistGenreProviding,
        apple: ArtistGenreProviding,
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.musicBrainz = musicBrainz
        self.apple = apple
        self.now = now
    }

    func automaticGenre(for artist: String) async throws -> String? {
        guard try repository.setting(Bool.self, forKey: Self.lookupEnabledKey) == true else { return nil }
        let canonical = ImportGrouper.normalizedPerson(artist)
        guard !canonical.isEmpty else { return nil }
        if let cached = try cachedEntry(for: canonical),
           cached.provider != .noMatch || now().timeIntervalSince(cached.checkedAt) < 86_400 { return cached.genre }
        guard !recentFailure(canonical) else { throw URLError(.notConnectedToInternet) }
        do {
            let result = try await lookup(canonical: canonical)
            try store(result, canonical: canonical)
            rememberFailure(canonical, date: nil)
            return result.genre
        } catch {
            if !(error is CancellationError) { rememberFailure(canonical, date: now()) }
            throw error
        }
    }

    func manualLookup(
        for artist: String,
        confirmReplacement: (String?, String) -> Bool
    ) async throws -> String? {
        let canonical = ImportGrouper.normalizedPerson(artist)
        guard !canonical.isEmpty else { return nil }
        let previous = try cachedEntry(for: canonical)
        let result = try await lookup(canonical: canonical)
        guard let genre = result.genre else {
            if previous == nil { try store(result, canonical: canonical) }
            return nil
        }
        if previous?.genre != genre, previous != nil, !confirmReplacement(previous?.genre, genre) { return nil }
        try store(result, canonical: canonical)
        return genre
    }

    func cachedEntry(for artist: String) throws -> MetadataGenreCacheEntry? {
        let canonical = ImportGrouper.normalizedPerson(artist)
        guard !canonical.isEmpty else { return nil }
        return try repository.setting(MetadataGenreCacheEntry.self, forKey: cacheKey(canonical))
    }

    private func lookup(canonical: String) async throws -> (genre: String?, provider: MetadataGenreProvider) {
        var failure: Error?
        do {
            if let genre = clean(try await musicBrainz.genre(for: canonical)) { return (genre, .musicBrainz) }
        } catch { failure = error }
        try Task.checkCancellation()
        do {
            if let genre = clean(try await apple.genre(for: canonical)) { return (genre, .apple) }
        } catch { failure = failure ?? error }
        try Task.checkCancellation()
        if let failure { throw failure }
        return (nil, .noMatch)
    }

    private func recentFailure(_ artist: String) -> Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        return failures[artist].map { now().timeIntervalSince($0) < 60 } ?? false
    }

    private func rememberFailure(_ artist: String, date: Date?) {
        failureLock.lock()
        failures[artist] = date
        failureLock.unlock()
    }

    private func store(
        _ result: (genre: String?, provider: MetadataGenreProvider),
        canonical: String
    ) throws {
        try repository.setSetting(
            MetadataGenreCacheEntry(
                canonicalArtist: canonical,
                genre: result.genre,
                provider: result.provider,
                checkedAt: now()
            ),
            forKey: cacheKey(canonical),
            at: now()
        )
    }

    private func cacheKey(_ canonical: String) -> String {
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self.cachePrefix + digest
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

/// MusicBrainz asks each application to stay at or below one request per second. Every
/// lookup, automatic or manual, reserves the next free slot before it is sent, so an adopt
/// of a large library cannot burst requests and get the device's address throttled.
actor MusicBrainzRequestGate {
    static let shared = MusicBrainzRequestGate()

    private let interval: TimeInterval
    private var nextSlot = Date.distantPast

    init(interval: TimeInterval = 1.1) { self.interval = interval }

    func waitForTurn() async throws {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }
}

final class MusicBrainzGenreProvider: ArtistGenreProviding {
    /// MusicBrainz identifies clients by application, version and a contact URL.
    static let userAgent = "Aeon/5.0 ( https://github.com/0brokenbydefault0/aeon )"

    private let session: URLSession
    private let gate: MusicBrainzRequestGate

    init(session: URLSession = .shared, gate: MusicBrainzRequestGate = .shared) {
        self.session = session
        self.gate = gate
    }

    func genre(for canonicalArtist: String) async throws -> String? {
        var searchComponents = URLComponents(string: "https://musicbrainz.org/ws/2/artist/")!
        searchComponents.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(canonicalArtist)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1")
        ]
        let searchData = try await data(for: searchComponents.url!)
        guard let id = try JSONDecoder().decode(SearchResponse.self, from: searchData).artists.first?.id else {
            return nil
        }
        var detailComponents = URLComponents(string: "https://musicbrainz.org/ws/2/artist/\(id)")!
        detailComponents.queryItems = [
            URLQueryItem(name: "inc", value: "genres"),
            URLQueryItem(name: "fmt", value: "json")
        ]
        let payload = try JSONDecoder().decode(ArtistDetail.self, from: try await data(for: detailComponents.url!))
        return payload.genres.sorted { ($0.count ?? 0) > ($1.count ?? 0) }.first?.name
    }

    private func data(for url: URL) async throws -> Data {
        try await gate.waitForTurn()
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private struct SearchResponse: Decodable {
        let artists: [ArtistHit]
    }

    private struct ArtistHit: Decodable {
        let id: String
    }

    private struct ArtistDetail: Decodable {
        let genres: [Genre]
    }

    private struct Genre: Decodable {
        let name: String
        let count: Int?
    }
}

final class AppleGenreProvider: ArtistGenreProviding {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func genre(for canonicalArtist: String) async throws -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: canonicalArtist),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).results.first?.primaryGenreName
    }

    private struct Response: Decodable {
        let results: [Artist]
    }

    private struct Artist: Decodable {
        let primaryGenreName: String?
    }
}
