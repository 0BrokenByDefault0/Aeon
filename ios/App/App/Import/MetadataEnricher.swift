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
        if let cached = try cachedEntry(for: canonical) { return cached.genre }
        let result = try await lookup(canonical: canonical)
        try store(result, canonical: canonical)
        return result.genre
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
        if let response = try? await musicBrainz.genre(for: canonical), let genre = clean(response) {
            return (genre, .musicBrainz)
        }
        if let response = try? await apple.genre(for: canonical), let genre = clean(response) {
            return (genre, .apple)
        }
        return (nil, .noMatch)
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

final class MusicBrainzGenreProvider: ArtistGenreProviding {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

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
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Aeon/1.0 (native music library metadata)", forHTTPHeaderField: "User-Agent")
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
