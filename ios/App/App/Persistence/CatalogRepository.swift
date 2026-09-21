import Foundation
import SQLite3

enum CatalogRepositoryError: Error, Equatable {
    case invalidStableID
    case invalidRecord
    case invalidPage
    case duplicateStableID(String)
    case missingReference(String)
    case decodeFailed(String)
}

final class CatalogObservation {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    func cancel() {
        lock.lock()
        let action = cancellation
        cancellation = nil
        lock.unlock()
        action?()
    }

    deinit { cancel() }
}

final class CatalogRepository {
    let database: CatalogDatabase

    private typealias Observer = (CatalogSnapshot) -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let observerLock = NSLock()
    private var observers: [UUID: Observer] = [:]

    init(database: CatalogDatabase) {
        self.database = database
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func insertAlbum(_ album: CatalogAlbum, tracks: [CatalogTrack]) throws {
        try insertAlbums([(album, tracks)])
    }

    func insertAlbums(_ records: [(CatalogAlbum, [CatalogTrack])]) throws {
        var albumIDs = Set<String>()
        var trackIDs = Set<String>()
        for (album, tracks) in records {
            try validate(album)
            guard albumIDs.insert(album.id).inserted else { throw CatalogRepositoryError.duplicateStableID(album.id) }
            for track in tracks {
                try validate(track, expectedAlbumID: album.id)
                guard trackIDs.insert(track.id).inserted else { throw CatalogRepositoryError.duplicateStableID(track.id) }
            }
        }

        try database.transaction {
            for id in albumIDs where try recordExists(table: "albums", id: id) {
                throw CatalogRepositoryError.duplicateStableID(id)
            }
            for id in trackIDs where try recordExists(table: "tracks", id: id) {
                throw CatalogRepositoryError.duplicateStableID(id)
            }
            for (album, tracks) in records {
                try insert(album)
                for track in tracks { try insert(track) }
            }
        }
        notifyObservers()
    }

    func updateAlbum(_ album: CatalogAlbum) throws {
        try validate(album)
        try updateAlbumRow(album)
        notifyObservers()
    }

    /// Incremental adoption extends a proven album without replacing its metadata,
    /// existing track identities, listening history or playlist references.
    func appendTracks(_ tracks: [CatalogTrack], toAlbumID albumID: String) throws {
        try validateID(albumID)
        for track in tracks { try validate(track, expectedAlbumID: albumID) }
        try database.transaction {
            guard try recordExists(table: "albums", id: albumID) else {
                throw CatalogRepositoryError.missingReference(albumID)
            }
            for track in tracks {
                guard try !recordExists(table: "tracks", id: track.id) else {
                    throw CatalogRepositoryError.duplicateStableID(track.id)
                }
                try insert(track)
            }
        }
        notifyObservers()
    }

    func updateAlbumAndSky(
        _ album: CatalogAlbum,
        records: [SkyRecord],
        deletingSkyRecordIDs: [String]
    ) throws {
        try validate(album)
        try validateSkyRewrite(records: records, deletingIDs: deletingSkyRecordIDs)
        try database.transaction {
            try updateAlbumRow(album)
            try rewriteSkyRows(records: records, deletingIDs: deletingSkyRecordIDs)
        }
        notifyObservers()
    }

    @discardableResult
    func deleteAlbum(id: String) throws -> Bool {
        try validateID(id)
        let changed = try database.transaction {
            try database.execute("DELETE FROM albums WHERE id = ?", [.text(id)])
        }
        if changed > 0 { notifyObservers() }
        return changed > 0
    }

    @discardableResult
    func deleteAlbumAndRewriteSky(
        id: String,
        records: [SkyRecord],
        deletingSkyRecordIDs: [String]
    ) throws -> Bool {
        try validateID(id)
        try validateSkyRewrite(records: records, deletingIDs: deletingSkyRecordIDs)
        let changed = try database.transaction {
            let changed = try database.execute("DELETE FROM albums WHERE id = ?", [.text(id)])
            guard changed == 1 else { return 0 }
            try rewriteSkyRows(records: records, deletingIDs: deletingSkyRecordIDs)
            return changed
        }
        if changed > 0 { notifyObservers() }
        return changed > 0
    }

    func album(id: String) throws -> CatalogAlbum? {
        try validateID(id)
        return try database.query(
            "SELECT * FROM albums WHERE id = ?", [.text(id)]
        ).first.map(try decodeAlbum)
    }

    func albumSummary(id: String) throws -> CatalogAlbumSummary? {
        try validateID(id)
        return try database.query(
            """
            SELECT a.id, a.sequence, a.title, a.artist, a.year, a.genre, a.artwork_key,
                   a.imported_at, COUNT(t.id) AS track_count,
                   COALESCE(SUM(l.play_count), 0) AS play_count,
                   MAX(l.last_played_at) AS last_played_at
            FROM albums a
            LEFT JOIN tracks t ON t.album_id = a.id
            LEFT JOIN listening l ON l.track_id = t.id
            WHERE a.id = ?
            GROUP BY a.id
            """,
            [.text(id)]
        ).first.map(try decodeAlbumSummary)
    }

    func albumPage(offset: Int = 0, limit: Int = 48, sort: CatalogAlbumSort = .recentlyAdded) throws -> [CatalogAlbumSummary] {
        try validatePage(offset: offset, limit: limit)
        let order: String
        switch sort {
        case .recentlyAdded: order = "a.sequence DESC, a.id"
        case .artist: order = "CASE WHEN a.normalized_artist = '' THEN 1 ELSE 0 END, a.normalized_artist, a.sequence, a.id"
        case .title: order = "CASE WHEN a.normalized_title = '' THEN 1 ELSE 0 END, a.normalized_title, a.sequence, a.id"
        case .year: order = "CASE WHEN TRIM(a.year) = '' THEN 1 ELSE 0 END, CAST(a.year AS INTEGER) DESC, a.year DESC, a.sequence, a.id"
        case .mostPlayed: order = "CASE WHEN MAX(l.last_played_at) IS NULL THEN 1 ELSE 0 END, MAX(l.last_played_at) DESC, play_count DESC, a.sequence, a.id"
        }
        return try database.query(
            """
            SELECT a.id, a.sequence, a.title, a.artist, a.year, a.genre, a.artwork_key,
                   a.imported_at, COUNT(t.id) AS track_count,
                   COALESCE(SUM(l.play_count), 0) AS play_count,
                   MAX(l.last_played_at) AS last_played_at
            FROM albums a
            LEFT JOIN tracks t ON t.album_id = a.id
            LEFT JOIN listening l ON l.track_id = t.id
            GROUP BY a.id
            ORDER BY \(order)
            LIMIT ? OFFSET ?
            """,
            [.integer(Int64(limit)), .integer(Int64(offset))]
        ).map(try decodeAlbumSummary)
    }

    func albumCount() throws -> Int {
        Int(try database.scalar("SELECT COUNT(*) AS value FROM albums")?.int64 ?? 0)
    }

    func tracks(albumID: String, offset: Int = 0, limit: Int = CatalogDatabase.maximumPageSize) throws -> [CatalogTrack] {
        try validateID(albumID)
        try validatePage(offset: offset, limit: limit)
        return try database.query(
            """
            SELECT * FROM tracks
            WHERE album_id = ?
            ORDER BY COALESCE(disc_number, 1),
                     CASE WHEN track_number IS NULL THEN 1 ELSE 0 END,
                     track_number, sequence, normalized_title, id
            LIMIT ? OFFSET ?
            """,
            [.text(albumID), .integer(Int64(limit)), .integer(Int64(offset))]
        ).map(try decodeTrack)
    }

    func track(id: String) throws -> CatalogTrack? {
        try validateID(id)
        return try database.query("SELECT * FROM tracks WHERE id = ?", [.text(id)]).first.map(try decodeTrack)
    }

    func updateTrack(_ track: CatalogTrack) throws {
        try validate(track, expectedAlbumID: track.albumID)
        guard try recordExists(table: "albums", id: track.albumID) else {
            throw CatalogRepositoryError.missingReference(track.albumID)
        }
        let media = try encodeMediaReference(track.mediaReference, expectedTrackID: track.id)
        let changed = try database.execute(
            """
            UPDATE tracks SET album_id = ?, sequence = ?, disc_number = ?, track_number = ?,
                title = ?, artist = ?, normalized_title = ?, normalized_artist = ?, duration = ?,
                byte_count = ?, media_kind = ?, media_path = ?, media_bookmark = ?, imported_at = ?
            WHERE id = ?
            """,
            [
                .text(track.albumID), .integer(Int64(track.sequence)),
                track.discNumber.map { .integer(Int64($0)) } ?? .null,
                track.trackNumber.map { .integer(Int64($0)) } ?? .null,
                .text(track.title), .text(track.artist), .text(Self.normalize(track.title)),
                .text(Self.normalize(track.artist)), track.duration.map(SQLiteValue.real) ?? .null,
                .integer(track.byteCount), .text(media.0), media.1, media.2,
                .real(track.importedAt.timeIntervalSince1970), .text(track.id)
            ]
        )
        guard changed == 1 else { throw CatalogRepositoryError.missingReference(track.id) }
        notifyObservers()
    }

    @discardableResult
    func deleteTrack(id: String) throws -> Bool {
        try validateID(id)
        let changed = try database.execute("DELETE FROM tracks WHERE id = ?", [.text(id)])
        if changed > 0 { notifyObservers() }
        return changed > 0
    }

    func search(_ query: String, limit: Int = 48) throws -> CatalogSearchResults {
        try validatePage(offset: 0, limit: limit)
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty else { return CatalogSearchResults(albums: [], artists: [], tracks: []) }
        let pattern = "%" + Self.escapeLike(normalized) + "%"
        let bindings: [SQLiteValue] = [.text(pattern), .text(pattern), .text(pattern), .integer(Int64(limit))]
        let albums = try database.query(
            """
            SELECT a.id, a.sequence, a.title, a.artist, a.year, a.genre, a.artwork_key,
                   a.imported_at, COUNT(t.id) AS track_count,
                   COALESCE(SUM(l.play_count), 0) AS play_count,
                   MAX(l.last_played_at) AS last_played_at
            FROM albums a
            LEFT JOIN tracks t ON t.album_id = a.id
            LEFT JOIN listening l ON l.track_id = t.id
            WHERE a.normalized_title LIKE ? ESCAPE '\\'
               OR a.normalized_artist LIKE ? ESCAPE '\\'
               OR a.normalized_genre LIKE ? ESCAPE '\\'
            GROUP BY a.id
            ORDER BY a.sequence DESC, a.id
            LIMIT ?
            """,
            bindings
        ).map(try decodeAlbumSummary)
        let artists = try database.query(
            """
            SELECT artist FROM (
                SELECT artist, normalized_artist FROM albums
                UNION
                SELECT artist, normalized_artist FROM tracks WHERE artist != ''
            )
            WHERE normalized_artist LIKE ? ESCAPE '\\'
            ORDER BY normalized_artist, artist
            LIMIT ?
            """,
            [.text(pattern), .integer(Int64(limit))]
        ).compactMap { $0.string("artist") }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let tracks = try database.query(
            """
            SELECT t.id AS track_id, t.album_id, t.title AS track_title,
                   a.title AS album_title,
                   CASE WHEN t.artist = '' THEN a.artist ELSE t.artist END AS artist
            FROM tracks t JOIN albums a ON a.id = t.album_id
            WHERE t.normalized_title LIKE ? ESCAPE '\\'
               OR t.normalized_artist LIKE ? ESCAPE '\\'
               OR a.normalized_artist LIKE ? ESCAPE '\\'
            ORDER BY a.sequence DESC, COALESCE(t.disc_number, 1), t.track_number, t.sequence, t.id
            LIMIT ?
            """,
            bindings
        ).map { row in
            guard let trackID = row.string("track_id"), let albumID = row.string("album_id"),
                  let trackTitle = row.string("track_title"), let albumTitle = row.string("album_title"),
                  let artist = row.string("artist") else {
                throw CatalogRepositoryError.decodeFailed("search_track")
            }
            return CatalogSearchResults.TrackHit(
                trackID: trackID,
                albumID: albumID,
                trackTitle: trackTitle,
                albumTitle: albumTitle,
                artist: artist
            )
        }
        return CatalogSearchResults(albums: albums, artists: artists, tracks: tracks)
    }

    func createPlaylist(_ playlist: CatalogPlaylist) throws {
        try validateID(playlist.id)
        guard !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogRepositoryError.invalidRecord
        }
        if try recordExists(table: "playlists", id: playlist.id) {
            throw CatalogRepositoryError.duplicateStableID(playlist.id)
        }
        try database.execute(
            "INSERT INTO playlists(id, name, created_at, updated_at) VALUES(?, ?, ?, ?)",
            [.text(playlist.id), .text(playlist.name), .real(playlist.createdAt.timeIntervalSince1970),
             .real(playlist.updatedAt.timeIntervalSince1970)]
        )
        notifyObservers()
    }

    @discardableResult
    func createPlaylist(
        name: String,
        trackIDs: [String],
        id: String = UUID().uuidString,
        at date: Date = Date()
    ) throws -> CatalogPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateID(id)
        guard !trimmed.isEmpty, !trackIDs.isEmpty else { throw CatalogRepositoryError.invalidRecord }
        for trackID in trackIDs { try validateID(trackID) }
        let playlist = CatalogPlaylist(id: id, name: trimmed, createdAt: date, updatedAt: date)
        try database.transaction {
            guard !(try recordExists(table: "playlists", id: id)) else {
                throw CatalogRepositoryError.duplicateStableID(id)
            }
            for trackID in trackIDs where !(try recordExists(table: "tracks", id: trackID)) {
                throw CatalogRepositoryError.missingReference(trackID)
            }
            try database.execute(
                "INSERT INTO playlists(id, name, created_at, updated_at) VALUES(?, ?, ?, ?)",
                [.text(id), .text(trimmed), .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970)]
            )
            for (position, trackID) in trackIDs.enumerated() {
                try database.execute(
                    "INSERT INTO playlist_items(playlist_id, position, track_id) VALUES(?, ?, ?)",
                    [.text(id), .integer(Int64(position)), .text(trackID)]
                )
            }
        }
        notifyObservers()
        return playlist
    }

    func playlists(offset: Int = 0, limit: Int = CatalogDatabase.maximumPageSize) throws -> [CatalogPlaylist] {
        try validatePage(offset: offset, limit: limit)
        return try database.query(
            "SELECT * FROM playlists ORDER BY created_at, id LIMIT ? OFFSET ?",
            [.integer(Int64(limit)), .integer(Int64(offset))]
        ).map { row in
            guard let id = row.string("id"), let name = row.string("name"),
                  let created = row.double("created_at"), let updated = row.double("updated_at") else {
                throw CatalogRepositoryError.decodeFailed("playlist")
            }
            return CatalogPlaylist(
                id: id,
                name: name,
                createdAt: Date(timeIntervalSince1970: created),
                updatedAt: Date(timeIntervalSince1970: updated)
            )
        }
    }

    func renamePlaylist(id: String, name: String, updatedAt: Date = Date()) throws {
        try validateID(id)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogRepositoryError.invalidRecord
        }
        let changed = try database.execute(
            "UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?",
            [.text(name), .real(updatedAt.timeIntervalSince1970), .text(id)]
        )
        guard changed == 1 else { throw CatalogRepositoryError.missingReference(id) }
        notifyObservers()
    }

    @discardableResult
    func deletePlaylist(id: String) throws -> Bool {
        try validateID(id)
        let changed = try database.execute("DELETE FROM playlists WHERE id = ?", [.text(id)])
        if changed > 0 { notifyObservers() }
        return changed > 0
    }

    func replacePlaylistItems(playlistID: String, trackIDs: [String], updatedAt: Date = Date()) throws {
        try validateID(playlistID)
        for trackID in trackIDs { try validateID(trackID) }
        try database.transaction {
            guard try recordExists(table: "playlists", id: playlistID) else {
                throw CatalogRepositoryError.missingReference(playlistID)
            }
            for trackID in trackIDs where !(try recordExists(table: "tracks", id: trackID)) {
                throw CatalogRepositoryError.missingReference(trackID)
            }
            try database.execute("DELETE FROM playlist_items WHERE playlist_id = ?", [.text(playlistID)])
            for (position, trackID) in trackIDs.enumerated() {
                try database.execute(
                    "INSERT INTO playlist_items(playlist_id, position, track_id) VALUES(?, ?, ?)",
                    [.text(playlistID), .integer(Int64(position)), .text(trackID)]
                )
            }
            try database.execute(
                "UPDATE playlists SET updated_at = ? WHERE id = ?",
                [.real(updatedAt.timeIntervalSince1970), .text(playlistID)]
            )
        }
        notifyObservers()
    }

    func playlistItems(playlistID: String, offset: Int = 0, limit: Int = CatalogDatabase.maximumPageSize) throws -> [CatalogPlaylistItem] {
        try validateID(playlistID)
        try validatePage(offset: offset, limit: limit)
        return try database.query(
            """
            SELECT pi.playlist_id, pi.position, t.id AS track_id, a.id AS album_id,
                   t.title AS track_title, a.title AS album_title,
                   CASE WHEN t.artist = '' THEN a.artist ELSE t.artist END AS artist
            FROM playlist_items pi
            JOIN tracks t ON t.id = pi.track_id
            JOIN albums a ON a.id = t.album_id
            WHERE pi.playlist_id = ?
            ORDER BY pi.position
            LIMIT ? OFFSET ?
            """,
            [.text(playlistID), .integer(Int64(limit)), .integer(Int64(offset))]
        ).map { row in
            guard let resolvedPlaylistID = row.string("playlist_id"), let position = row.int("position"),
                  let trackID = row.string("track_id"), let albumID = row.string("album_id"),
                  let trackTitle = row.string("track_title"), let albumTitle = row.string("album_title"),
                  let artist = row.string("artist") else {
                throw CatalogRepositoryError.decodeFailed("playlist_item")
            }
            return CatalogPlaylistItem(
                playlistID: resolvedPlaylistID,
                position: position,
                trackID: trackID,
                albumID: albumID,
                trackTitle: trackTitle,
                albumTitle: albumTitle,
                artist: artist
            )
        }
    }

    func recordPlay(
        trackID: String,
        completed: Bool = false,
        lastPosition: TimeInterval = 0,
        at date: Date = Date()
    ) throws {
        try validateID(trackID)
        guard lastPosition.isFinite, lastPosition >= 0 else { throw CatalogRepositoryError.invalidRecord }
        guard try recordExists(table: "tracks", id: trackID) else {
            throw CatalogRepositoryError.missingReference(trackID)
        }
        try database.execute(
            """
            INSERT INTO listening(track_id, play_count, completed_count, last_position, last_played_at)
            VALUES(?, 1, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                play_count = listening.play_count + 1,
                completed_count = listening.completed_count + excluded.completed_count,
                last_position = excluded.last_position,
                last_played_at = MAX(COALESCE(listening.last_played_at, 0), excluded.last_played_at)
            """,
            [.text(trackID), .integer(completed ? 1 : 0), .real(lastPosition), .real(date.timeIntervalSince1970)]
        )
        notifyObservers()
    }

    func mergeListening(
        trackID: String,
        playCount: Int64,
        completedCount: Int64 = 0,
        lastPosition: TimeInterval = 0,
        lastPlayedAt: Date? = nil
    ) throws {
        try validateID(trackID)
        guard playCount >= 0, completedCount >= 0, lastPosition.isFinite, lastPosition >= 0 else {
            throw CatalogRepositoryError.invalidRecord
        }
        guard try recordExists(table: "tracks", id: trackID) else {
            throw CatalogRepositoryError.missingReference(trackID)
        }
        try database.execute(
            """
            INSERT INTO listening(track_id, play_count, completed_count, last_position, last_played_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(track_id) DO UPDATE SET
                play_count = MAX(listening.play_count, excluded.play_count),
                completed_count = MAX(listening.completed_count, excluded.completed_count),
                last_position = excluded.last_position,
                last_played_at = CASE
                    WHEN excluded.last_played_at IS NULL THEN listening.last_played_at
                    WHEN listening.last_played_at IS NULL THEN excluded.last_played_at
                    ELSE MAX(listening.last_played_at, excluded.last_played_at)
                END
            """,
            [
                .text(trackID), .integer(playCount), .integer(completedCount), .real(lastPosition),
                lastPlayedAt.map { .real($0.timeIntervalSince1970) } ?? .null
            ]
        )
        notifyObservers()
    }

    func listeningState(trackID: String) throws -> CatalogListeningState? {
        try validateID(trackID)
        guard let row = try database.query("SELECT * FROM listening WHERE track_id = ?", [.text(trackID)]).first else {
            return nil
        }
        guard let resolvedID = row.string("track_id"), let plays = row.int64("play_count"),
              let completed = row.int64("completed_count"), let position = row.double("last_position") else {
            throw CatalogRepositoryError.decodeFailed("listening")
        }
        return CatalogListeningState(
            trackID: resolvedID,
            playCount: plays,
            completedCount: completed,
            lastPosition: position,
            lastPlayedAt: row.double("last_played_at").map(Date.init(timeIntervalSince1970:))
        )
    }

    func listeningStates(offset: Int = 0, limit: Int = CatalogDatabase.maximumPageSize) throws -> [CatalogListeningState] {
        try validatePage(offset: offset, limit: limit)
        return try database.query(
            "SELECT * FROM listening ORDER BY track_id LIMIT ? OFFSET ?",
            [.integer(Int64(limit)), .integer(Int64(offset))]
        ).map { row in
            guard let trackID = row.string("track_id"), let plays = row.int64("play_count"),
                  let completed = row.int64("completed_count"), let position = row.double("last_position") else {
                throw CatalogRepositoryError.decodeFailed("listening")
            }
            return CatalogListeningState(
                trackID: trackID,
                playCount: plays,
                completedCount: completed,
                lastPosition: position,
                lastPlayedAt: row.double("last_played_at").map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func setSetting<Value: Encodable>(_ value: Value, forKey key: String, at date: Date = Date()) throws {
        try validateSettingKey(key)
        let data = try encoder.encode(value)
        try database.execute(
            """
            INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """,
            [.text(key), .blob(data), .real(date.timeIntervalSince1970)]
        )
    }

    func setting<Value: Decodable>(_ type: Value.Type, forKey key: String) throws -> Value? {
        try validateSettingKey(key)
        guard let data = try database.query(
            "SELECT value FROM settings WHERE key = ?", [.text(key)]
        ).first?.data("value") else { return nil }
        do { return try decoder.decode(type, from: data) }
        catch { throw CatalogRepositoryError.decodeFailed("setting:\(key)") }
    }

    func removeSetting(forKey key: String) throws {
        try validateSettingKey(key)
        try database.execute("DELETE FROM settings WHERE key = ?", [.text(key)])
    }

    func settingRecords(offset: Int = 0, limit: Int = CatalogDatabase.maximumPageSize) throws -> [CatalogSettingRecord] {
        try validatePage(offset: offset, limit: limit)
        return try database.query(
            "SELECT key, value, updated_at FROM settings ORDER BY key LIMIT ? OFFSET ?",
            [.integer(Int64(limit)), .integer(Int64(offset))]
        ).map { row in
            guard let key = row.string("key"), let value = row.data("value"), let updated = row.double("updated_at") else {
                throw CatalogRepositoryError.decodeFailed("setting")
            }
            return CatalogSettingRecord(key: key, value: value, updatedAt: Date(timeIntervalSince1970: updated))
        }
    }

    func upsertSkyRecord(_ record: SkyRecord) throws {
        try validateID(record.id)
        try database.execute(
            """
            INSERT INTO sky_records(id, kind, sequence, payload, updated_at) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, sequence = excluded.sequence,
                payload = excluded.payload, updated_at = excluded.updated_at
            """,
            [.text(record.id), .text(record.kind.rawValue), .integer(record.sequence),
             .blob(record.payload), .real(record.updatedAt.timeIntervalSince1970)]
        )
    }

    func skyRecords(kind: SkyRecordKind, offset: Int = 0, limit: Int = CatalogDatabase.maximumPageSize) throws -> [SkyRecord] {
        try validatePage(offset: offset, limit: limit)
        return try database.query(
            "SELECT * FROM sky_records WHERE kind = ? ORDER BY sequence, id LIMIT ? OFFSET ?",
            [.text(kind.rawValue), .integer(Int64(limit)), .integer(Int64(offset))]
        ).map { row in
            guard let id = row.string("id"), let rawKind = row.string("kind"),
                  let resolvedKind = SkyRecordKind(rawValue: rawKind), let sequence = row.int64("sequence"),
                  let payload = row.data("payload"), let updated = row.double("updated_at") else {
                throw CatalogRepositoryError.decodeFailed("sky_record")
            }
            return SkyRecord(
                id: id,
                kind: resolvedKind,
                sequence: sequence,
                payload: payload,
                updatedAt: Date(timeIntervalSince1970: updated)
            )
        }
    }

    func deleteSkyRecord(id: String) throws {
        try validateID(id)
        try database.execute("DELETE FROM sky_records WHERE id = ?", [.text(id)])
    }

    func stageMigrationRecord(_ record: MigrationStageRecord) throws {
        try validateID(record.sourceStore)
        try validateID(record.sourceID)
        try database.execute(
            """
            INSERT INTO migration_staging(source_store, source_id, status, payload, updated_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(source_store, source_id) DO UPDATE SET status = excluded.status,
                payload = excluded.payload, updated_at = excluded.updated_at
            """,
            [.text(record.sourceStore), .text(record.sourceID), .text(record.status.rawValue),
             .blob(record.payload), .real(record.updatedAt.timeIntervalSince1970)]
        )
    }

    func migrationRecords(
        status: MigrationStageStatus,
        offset: Int = 0,
        limit: Int = CatalogDatabase.maximumPageSize
    ) throws -> [MigrationStageRecord] {
        try validatePage(offset: offset, limit: limit)
        return try database.query(
            """
            SELECT * FROM migration_staging WHERE status = ?
            ORDER BY source_store, source_id LIMIT ? OFFSET ?
            """,
            [.text(status.rawValue), .integer(Int64(limit)), .integer(Int64(offset))]
        ).map { row in
            guard let store = row.string("source_store"), let id = row.string("source_id"),
                  let rawStatus = row.string("status"), let resolvedStatus = MigrationStageStatus(rawValue: rawStatus),
                  let payload = row.data("payload"), let updated = row.double("updated_at") else {
                throw CatalogRepositoryError.decodeFailed("migration_record")
            }
            return MigrationStageRecord(
                sourceStore: store,
                sourceID: id,
                status: resolvedStatus,
                payload: payload,
                updatedAt: Date(timeIntervalSince1970: updated)
            )
        }
    }

    func migrationRecord(sourceStore: String, sourceID: String) throws -> MigrationStageRecord? {
        try validateID(sourceStore)
        try validateID(sourceID)
        guard let row = try database.query(
            "SELECT * FROM migration_staging WHERE source_store = ? AND source_id = ?",
            [.text(sourceStore), .text(sourceID)]
        ).first else { return nil }
        guard let store = row.string("source_store"), let id = row.string("source_id"),
              let rawStatus = row.string("status"), let status = MigrationStageStatus(rawValue: rawStatus),
              let payload = row.data("payload"), let updated = row.double("updated_at") else {
            throw CatalogRepositoryError.decodeFailed("migration_record")
        }
        return MigrationStageRecord(
            sourceStore: store,
            sourceID: id,
            status: status,
            payload: payload,
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    func completeLegacyAudioMigration(track: CatalogTrack, stage: MigrationStageRecord) throws {
        try validate(track, expectedAlbumID: track.albumID)
        try validateID(stage.sourceStore)
        try validateID(stage.sourceID)
        guard stage.status == .complete else { throw CatalogRepositoryError.invalidRecord }
        let media = try encodeMediaReference(track.mediaReference, expectedTrackID: track.id)
        try database.transaction {
            let changed = try database.execute(
                """
                UPDATE tracks SET album_id = ?, sequence = ?, disc_number = ?, track_number = ?,
                    title = ?, artist = ?, normalized_title = ?, normalized_artist = ?, duration = ?,
                    byte_count = ?, media_kind = ?, media_path = ?, media_bookmark = ?, imported_at = ?
                WHERE id = ?
                """,
                [
                    .text(track.albumID), .integer(Int64(track.sequence)),
                    track.discNumber.map { .integer(Int64($0)) } ?? .null,
                    track.trackNumber.map { .integer(Int64($0)) } ?? .null,
                    .text(track.title), .text(track.artist), .text(Self.normalize(track.title)),
                    .text(Self.normalize(track.artist)), track.duration.map(SQLiteValue.real) ?? .null,
                    .integer(track.byteCount), .text(media.0), media.1, media.2,
                    .real(track.importedAt.timeIntervalSince1970), .text(track.id)
                ]
            )
            guard changed == 1 else { throw CatalogRepositoryError.missingReference(track.id) }
            try database.execute(
                """
                INSERT INTO migration_staging(source_store, source_id, status, payload, updated_at)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(source_store, source_id) DO UPDATE SET status = excluded.status,
                    payload = excluded.payload, updated_at = excluded.updated_at
                """,
                [.text(stage.sourceStore), .text(stage.sourceID), .text(stage.status.rawValue),
                 .blob(stage.payload), .real(stage.updatedAt.timeIntervalSince1970)]
            )
        }
        notifyObservers()
    }

    @discardableResult
    func publishLegacyImport(_ payload: LegacyCatalogImport, marker: String) throws -> Bool {
        try validateSettingKey(marker)
        let published = try database.transaction { () -> Bool in
            if try database.scalar("SELECT 1 AS value FROM settings WHERE key = ?", [.text(marker)])?.int64 == 1 {
                return false
            }
            for (album, tracks) in payload.albums {
                try validate(album)
                guard !(try recordExists(table: "albums", id: album.id)) else {
                    throw CatalogRepositoryError.duplicateStableID(album.id)
                }
                try insert(album)
                for track in tracks {
                    try validate(track, expectedAlbumID: album.id)
                    guard !(try recordExists(table: "tracks", id: track.id)) else {
                        throw CatalogRepositoryError.duplicateStableID(track.id)
                    }
                    try insert(track)
                }
            }
            for value in payload.playlists {
                try validateID(value.playlist.id)
                guard !(try recordExists(table: "playlists", id: value.playlist.id)) else {
                    throw CatalogRepositoryError.duplicateStableID(value.playlist.id)
                }
                try database.execute(
                    "INSERT INTO playlists(id, name, created_at, updated_at) VALUES(?, ?, ?, ?)",
                    [.text(value.playlist.id), .text(value.playlist.name),
                     .real(value.playlist.createdAt.timeIntervalSince1970),
                     .real(value.playlist.updatedAt.timeIntervalSince1970)]
                )
                for (position, trackID) in value.trackIDs.enumerated() {
                    guard try recordExists(table: "tracks", id: trackID) else {
                        throw CatalogRepositoryError.missingReference(trackID)
                    }
                    try database.execute(
                        "INSERT INTO playlist_items(playlist_id, position, track_id) VALUES(?, ?, ?)",
                        [.text(value.playlist.id), .integer(Int64(position)), .text(trackID)]
                    )
                }
            }
            for value in payload.listening where value.playCount > 0 {
                guard try recordExists(table: "tracks", id: value.trackID) else { continue }
                try database.execute(
                    "INSERT INTO listening(track_id, play_count, completed_count, last_position) VALUES(?, ?, 0, 0)",
                    [.text(value.trackID), .integer(value.playCount)]
                )
            }
            let now = Date().timeIntervalSince1970
            for (key, data) in payload.settings {
                try validateSettingKey(key)
                try database.execute(
                    "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)",
                    [.text(key), .blob(data), .real(now)]
                )
            }
            try database.execute(
                "INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)",
                [.text(marker), .blob(Data("true".utf8)), .real(now)]
            )
            return true
        }
        if published { notifyObservers() }
        return published
    }

    func restoreArchive(
        _ archive: AeonArchiveCatalog,
        mediaReferences: [String: MediaReference],
        artworkKeys: [String: String]
    ) throws {
        guard archive.v == AeonArchiveCatalog.version else { throw CatalogRepositoryError.invalidRecord }
        let existingAlbums = try database.query("SELECT id, sequence, artwork_key FROM albums ORDER BY sequence")
        let existingSequences = Dictionary(uniqueKeysWithValues: existingAlbums.compactMap { row -> (String, Int64)? in
            guard let id = row.string("id"), let sequence = row.int64("sequence") else { return nil }
            return (id, sequence)
        })
        let replacingIDs = Set(archive.albums.map(\.id))
        let existingArtwork = Dictionary(uniqueKeysWithValues: existingAlbums.compactMap { row -> (String, String)? in
            guard let id = row.string("id"), let key = row.string("artwork_key") else { return nil }
            return (id, key)
        })
        var reserved = Set(existingSequences.compactMap { replacingIDs.contains($0.key) ? nil : $0.value })
        var nextSequence = max(existingSequences.values.max() ?? 0, archive.albums.map(\.sequence).max() ?? 0) + 1
        var resolvedSequences: [String: Int64] = [:]
        for album in archive.albums.sorted(by: { ($0.sequence, $0.id) < ($1.sequence, $1.id) }) {
            let sequence: Int64
            if let existing = existingSequences[album.id] { sequence = existing }
            else if album.sequence > 0, !reserved.contains(album.sequence) { sequence = album.sequence }
            else {
                while reserved.contains(nextSequence) { nextSequence += 1 }
                sequence = nextSequence
                nextSequence += 1
            }
            reserved.insert(sequence)
            resolvedSequences[album.id] = sequence
        }

        for album in archive.albums {
            try validateID(album.id)
            for track in album.tracks {
                try validateID(track.id)
                guard track.albumID == album.id, mediaReferences[track.id] != nil else {
                    throw CatalogRepositoryError.missingReference(track.id)
                }
                if let row = try database.query("SELECT album_id FROM tracks WHERE id = ?", [.text(track.id)]).first,
                   row.string("album_id") != album.id {
                    throw CatalogRepositoryError.duplicateStableID(track.id)
                }
            }
        }

        try database.transaction {
            for value in archive.albums {
                let album = CatalogAlbum(
                    id: value.id,
                    sequence: resolvedSequences[value.id]!,
                    title: value.title,
                    artist: value.artist,
                    year: value.year,
                    genre: value.genre,
                    artworkKey: artworkKeys[value.id] ?? existingArtwork[value.id],
                    importedAt: Date(timeIntervalSince1970: value.importedAt),
                    updatedAt: Date(timeIntervalSince1970: value.updatedAt)
                )
                try validate(album)
                if existingSequences[album.id] == nil { try insert(album) }
                else { try updateAlbumRow(album) }

                if existingSequences[album.id] != nil {
                    let maximum = try database.scalar(
                        "SELECT COALESCE(MAX(sequence), 0) AS value FROM tracks WHERE album_id = ?",
                        [.text(album.id)]
                    )?.int64 ?? 0
                    if maximum > 0 {
                        try database.execute(
                            "UPDATE tracks SET sequence = sequence + ? WHERE album_id = ?",
                            [.integer(maximum + Int64(value.tracks.count) + 1), .text(album.id)]
                        )
                    }
                }
                for archivedTrack in value.tracks {
                    let track = CatalogTrack(
                        id: archivedTrack.id,
                        albumID: album.id,
                        sequence: archivedTrack.sequence,
                        discNumber: archivedTrack.discNumber,
                        trackNumber: archivedTrack.trackNumber,
                        title: archivedTrack.title,
                        artist: archivedTrack.artist,
                        duration: archivedTrack.duration,
                        byteCount: archivedTrack.byteCount,
                        mediaReference: mediaReferences[archivedTrack.id]!,
                        importedAt: Date(timeIntervalSince1970: archivedTrack.importedAt)
                    )
                    try validate(track, expectedAlbumID: album.id)
                    let media = try encodeMediaReference(track.mediaReference, expectedTrackID: track.id)
                    try database.execute(
                        """
                        INSERT INTO tracks(
                            id, album_id, sequence, disc_number, track_number, title, artist,
                            normalized_title, normalized_artist, duration, byte_count,
                            media_kind, media_path, media_bookmark, imported_at
                        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET album_id = excluded.album_id,
                            sequence = excluded.sequence, disc_number = excluded.disc_number,
                            track_number = excluded.track_number, title = excluded.title,
                            artist = excluded.artist, normalized_title = excluded.normalized_title,
                            normalized_artist = excluded.normalized_artist, duration = excluded.duration,
                            byte_count = excluded.byte_count, media_kind = excluded.media_kind,
                            media_path = excluded.media_path, media_bookmark = excluded.media_bookmark,
                            imported_at = excluded.imported_at
                        """,
                        [
                            .text(track.id), .text(track.albumID), .integer(Int64(track.sequence)),
                            track.discNumber.map { .integer(Int64($0)) } ?? .null,
                            track.trackNumber.map { .integer(Int64($0)) } ?? .null,
                            .text(track.title), .text(track.artist), .text(Self.normalize(track.title)),
                            .text(Self.normalize(track.artist)), track.duration.map(SQLiteValue.real) ?? .null,
                            .integer(track.byteCount), .text(media.0), media.1, media.2,
                            .real(track.importedAt.timeIntervalSince1970)
                        ]
                    )
                }
                let restoredTrackIDs = Set(value.tracks.map(\.id))
                let obsoleteRows = try database.query(
                    "SELECT id FROM tracks WHERE album_id = ?",
                    [.text(album.id)]
                )
                for row in obsoleteRows {
                    guard let id = row.string("id"), !restoredTrackIDs.contains(id) else { continue }
                    try database.execute("DELETE FROM tracks WHERE id = ?", [.text(id)])
                }
            }

            for playlist in archive.playlists {
                try validateID(playlist.id)
                guard !playlist.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CatalogRepositoryError.invalidRecord
                }
                try database.execute(
                    """
                    INSERT INTO playlists(id, name, created_at, updated_at) VALUES(?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, updated_at = excluded.updated_at
                    """,
                    [.text(playlist.id), .text(playlist.name), .real(playlist.createdAt), .real(playlist.updatedAt)]
                )
                try database.execute("DELETE FROM playlist_items WHERE playlist_id = ?", [.text(playlist.id)])
                for (position, trackID) in playlist.trackIDs.enumerated() {
                    guard try recordExists(table: "tracks", id: trackID) else {
                        throw CatalogRepositoryError.missingReference(trackID)
                    }
                    try database.execute(
                        "INSERT INTO playlist_items(playlist_id, position, track_id) VALUES(?, ?, ?)",
                        [.text(playlist.id), .integer(Int64(position)), .text(trackID)]
                    )
                }
            }

            for listening in archive.listening {
                guard try recordExists(table: "tracks", id: listening.trackID) else {
                    throw CatalogRepositoryError.missingReference(listening.trackID)
                }
                try database.execute(
                    """
                    INSERT INTO listening(track_id, play_count, completed_count, last_position, last_played_at)
                    VALUES(?, ?, ?, ?, ?)
                    ON CONFLICT(track_id) DO UPDATE SET
                        play_count = MAX(listening.play_count, excluded.play_count),
                        completed_count = MAX(listening.completed_count, excluded.completed_count),
                        last_position = CASE WHEN excluded.last_played_at >= COALESCE(listening.last_played_at, 0)
                            THEN excluded.last_position ELSE listening.last_position END,
                        last_played_at = CASE
                            WHEN excluded.last_played_at IS NULL THEN listening.last_played_at
                            WHEN listening.last_played_at IS NULL THEN excluded.last_played_at
                            ELSE MAX(listening.last_played_at, excluded.last_played_at) END
                    """,
                    [
                        .text(listening.trackID), .integer(listening.playCount), .integer(listening.completedCount),
                        .real(listening.lastPosition), listening.lastPlayedAt.map(SQLiteValue.real) ?? .null
                    ]
                )
            }

            for setting in archive.settings {
                try validateSettingKey(setting.key)
                try database.execute(
                    """
                    INSERT INTO settings(key, value, updated_at) VALUES(?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """,
                    [.text(setting.key), .blob(setting.value), .real(setting.updatedAt)]
                )
            }
            if let seed = archive.skySeed {
                try database.execute(
                    """
                    INSERT INTO settings(key, value, updated_at) VALUES('sky.seed', ?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                    """,
                    [.blob(try encoder.encode(seed)), .real(archive.exportedAt)]
                )
            }
            for record in archive.skyRecords {
                try validateID(record.id)
                try database.execute(
                    """
                    INSERT INTO sky_records(id, kind, sequence, payload, updated_at) VALUES(?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, sequence = excluded.sequence,
                        payload = excluded.payload, updated_at = excluded.updated_at
                    """,
                    [.text(record.id), .text(record.kind.rawValue), .integer(record.sequence),
                     .blob(record.payload), .real(record.updatedAt)]
                )
            }
        }
        notifyObservers()
    }

    func observeLibrary(_ observer: @escaping (CatalogSnapshot) -> Void) -> CatalogObservation {
        let id = UUID()
        observerLock.lock()
        observers[id] = observer
        observerLock.unlock()
        deliverSnapshot(to: [observer])
        return CatalogObservation { [weak self] in
            self?.observerLock.lock()
            self?.observers.removeValue(forKey: id)
            self?.observerLock.unlock()
        }
    }

    static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func insert(_ album: CatalogAlbum) throws {
        try database.execute(
            """
            INSERT INTO albums(
                id, sequence, title, artist, year, genre, normalized_title, normalized_artist,
                artwork_key, imported_at, updated_at, normalized_genre
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(album.id), .integer(album.sequence), .text(album.title), .text(album.artist),
                .text(album.year), .text(album.genre), .text(Self.normalize(album.title)),
                .text(Self.normalize(album.artist)), album.artworkKey.map(SQLiteValue.text) ?? .null,
                .real(album.importedAt.timeIntervalSince1970), .real(album.updatedAt.timeIntervalSince1970),
                .text(Self.normalize(album.genre))
            ]
        )
    }

    private func insert(_ track: CatalogTrack) throws {
        let media = try encodeMediaReference(track.mediaReference, expectedTrackID: track.id)
        try database.execute(
            """
            INSERT INTO tracks(
                id, album_id, sequence, disc_number, track_number, title, artist,
                normalized_title, normalized_artist, duration, byte_count,
                media_kind, media_path, media_bookmark, imported_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(track.id), .text(track.albumID), .integer(Int64(track.sequence)),
                track.discNumber.map { .integer(Int64($0)) } ?? .null,
                track.trackNumber.map { .integer(Int64($0)) } ?? .null,
                .text(track.title), .text(track.artist), .text(Self.normalize(track.title)),
                .text(Self.normalize(track.artist)), track.duration.map(SQLiteValue.real) ?? .null,
                .integer(track.byteCount), .text(media.0), media.1, media.2,
                .real(track.importedAt.timeIntervalSince1970)
            ]
        )
    }

    private func decodeAlbum(_ row: CatalogRow) throws -> CatalogAlbum {
        guard let id = row.string("id"), let sequence = row.int64("sequence"),
              let title = row.string("title"), let artist = row.string("artist"),
              let year = row.string("year"), let genre = row.string("genre"),
              let imported = row.double("imported_at"), let updated = row.double("updated_at") else {
            throw CatalogRepositoryError.decodeFailed("album")
        }
        return CatalogAlbum(
            id: id,
            sequence: sequence,
            title: title,
            artist: artist,
            year: year,
            genre: genre,
            artworkKey: row.string("artwork_key"),
            importedAt: Date(timeIntervalSince1970: imported),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    private func decodeAlbumSummary(_ row: CatalogRow) throws -> CatalogAlbumSummary {
        guard let id = row.string("id"), let sequence = row.int64("sequence"),
              let title = row.string("title"), let artist = row.string("artist"),
              let year = row.string("year"), let genre = row.string("genre"),
              let trackCount = row.int("track_count"), let playCount = row.int64("play_count"),
              let imported = row.double("imported_at") else {
            throw CatalogRepositoryError.decodeFailed("album_summary")
        }
        return CatalogAlbumSummary(
            id: id,
            sequence: sequence,
            title: title,
            artist: artist,
            year: year,
            genre: genre,
            artworkKey: row.string("artwork_key"),
            trackCount: trackCount,
            playCount: playCount,
            lastPlayedAt: row.double("last_played_at").map(Date.init(timeIntervalSince1970:)),
            importedAt: Date(timeIntervalSince1970: imported)
        )
    }

    private func updateAlbumRow(_ album: CatalogAlbum) throws {
        let changed = try database.execute(
            """
            UPDATE albums
            SET sequence = ?, title = ?, artist = ?, year = ?, genre = ?,
                normalized_title = ?, normalized_artist = ?, normalized_genre = ?,
                artwork_key = ?, updated_at = ?
            WHERE id = ?
            """,
            [
                .integer(album.sequence), .text(album.title), .text(album.artist), .text(album.year),
                .text(album.genre), .text(Self.normalize(album.title)), .text(Self.normalize(album.artist)),
                .text(Self.normalize(album.genre)), album.artworkKey.map(SQLiteValue.text) ?? .null,
                .real(album.updatedAt.timeIntervalSince1970), .text(album.id)
            ]
        )
        guard changed == 1 else { throw CatalogRepositoryError.missingReference(album.id) }
    }

    private func validateSkyRewrite(records: [SkyRecord], deletingIDs: [String]) throws {
        var ids = Set<String>()
        for record in records {
            try validateID(record.id)
            guard ids.insert(record.id).inserted else { throw CatalogRepositoryError.duplicateStableID(record.id) }
        }
        for id in deletingIDs { try validateID(id) }
    }

    private func rewriteSkyRows(records: [SkyRecord], deletingIDs: [String]) throws {
        for id in deletingIDs {
            try database.execute("DELETE FROM sky_records WHERE id = ?", [.text(id)])
        }
        for record in records {
            try database.execute(
                """
                INSERT INTO sky_records(id, kind, sequence, payload, updated_at) VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, sequence = excluded.sequence,
                    payload = excluded.payload, updated_at = excluded.updated_at
                """,
                [.text(record.id), .text(record.kind.rawValue), .integer(record.sequence),
                 .blob(record.payload), .real(record.updatedAt.timeIntervalSince1970)]
            )
        }
    }

    private func decodeTrack(_ row: CatalogRow) throws -> CatalogTrack {
        guard let id = row.string("id"), let albumID = row.string("album_id"),
              let sequence = row.int("sequence"), let title = row.string("title"),
              let artist = row.string("artist"), let bytes = row.int64("byte_count"),
              let kind = row.string("media_kind"), let imported = row.double("imported_at") else {
            throw CatalogRepositoryError.decodeFailed("track")
        }
        let mediaReference: MediaReference
        switch kind {
        case "native":
            guard let path = row.string("media_path") else { throw CatalogRepositoryError.decodeFailed("native_media") }
            mediaReference = .native(relativePath: path)
        case "documents":
            guard let path = row.string("media_path") else { throw CatalogRepositoryError.decodeFailed("documents_media") }
            mediaReference = .documents(relativePath: path)
        case "bookmark":
            guard let data = row.data("media_bookmark") else { throw CatalogRepositoryError.decodeFailed("bookmark_media") }
            mediaReference = .externalBookmark(data)
        case "legacyBlob":
            mediaReference = .legacyBlob(trackID: row.string("media_path") ?? id)
        case "unavailable":
            mediaReference = .unavailable(trackID: row.string("media_path") ?? id)
        default:
            throw CatalogRepositoryError.decodeFailed("media_kind")
        }
        return CatalogTrack(
            id: id,
            albumID: albumID,
            sequence: sequence,
            discNumber: row.int("disc_number"),
            trackNumber: row.int("track_number"),
            title: title,
            artist: artist,
            duration: row.double("duration"),
            byteCount: bytes,
            mediaReference: mediaReference,
            importedAt: Date(timeIntervalSince1970: imported)
        )
    }

    private func validate(_ album: CatalogAlbum) throws {
        try validateID(album.id)
        guard album.sequence > 0,
              !album.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !album.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              album.importedAt.timeIntervalSince1970.isFinite,
              album.updatedAt.timeIntervalSince1970.isFinite else {
            throw CatalogRepositoryError.invalidRecord
        }
        if let artworkKey = album.artworkKey {
            let ext = (artworkKey as NSString).pathExtension.lowercased()
            let base = (artworkKey as NSString).deletingPathExtension
            guard artworkKey.utf8.count <= 133, (ext == "jpg" || ext == "heic"), !base.isEmpty,
                  base.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else {
                throw CatalogRepositoryError.invalidRecord
            }
        }
    }

    private func validate(_ track: CatalogTrack, expectedAlbumID: String) throws {
        try validateID(track.id)
        try validateID(track.albumID)
        guard track.albumID == expectedAlbumID,
              track.sequence > 0,
              track.discNumber.map({ $0 > 0 }) ?? true,
              track.trackNumber.map({ $0 > 0 }) ?? true,
              !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              track.duration.map({ $0.isFinite && $0 >= 0 }) ?? true,
              track.byteCount >= 0,
              track.importedAt.timeIntervalSince1970.isFinite else {
            throw CatalogRepositoryError.invalidRecord
        }
        _ = try encodeMediaReference(track.mediaReference, expectedTrackID: track.id)
    }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 512, !id.contains("\0") else {
            throw CatalogRepositoryError.invalidStableID
        }
    }

    private func validateSettingKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 128, !key.contains("\0") else {
            throw CatalogRepositoryError.invalidRecord
        }
    }

    private func validatePage(offset: Int, limit: Int) throws {
        guard offset >= 0, limit > 0, limit <= CatalogDatabase.maximumPageSize else {
            throw CatalogRepositoryError.invalidPage
        }
    }

    private func recordExists(table: String, id: String) throws -> Bool {
        let sql: String
        switch table {
        case "albums": sql = "SELECT 1 AS value FROM albums WHERE id = ? LIMIT 1"
        case "tracks": sql = "SELECT 1 AS value FROM tracks WHERE id = ? LIMIT 1"
        case "playlists": sql = "SELECT 1 AS value FROM playlists WHERE id = ? LIMIT 1"
        default: throw CatalogRepositoryError.invalidRecord
        }
        return try database.scalar(sql, [.text(id)])?.int64 == 1
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func encodeMediaReference(
        _ reference: MediaReference,
        expectedTrackID: String
    ) throws -> (String, SQLiteValue, SQLiteValue) {
        switch reference {
        case .native(let path):
            try validateRelativeMediaPath(path)
            return ("native", .text(path), .null)
        case .documents(let path):
            try validateRelativeMediaPath(path)
            return ("documents", .text(path), .null)
        case .externalBookmark(let data):
            guard !data.isEmpty, data.count <= 1_048_576 else { throw CatalogRepositoryError.invalidRecord }
            return ("bookmark", .null, .blob(data))
        case .legacyBlob(let trackID):
            guard trackID == expectedTrackID else { throw CatalogRepositoryError.invalidRecord }
            return ("legacyBlob", .text(trackID), .null)
        case .unavailable(let trackID):
            guard trackID == expectedTrackID else { throw CatalogRepositoryError.invalidRecord }
            return ("unavailable", .text(trackID), .null)
        }
    }

    private func validateRelativeMediaPath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CatalogRepositoryError.invalidRecord
        }
    }

    private func notifyObservers() {
        observerLock.lock()
        let callbacks = Array(observers.values)
        observerLock.unlock()
        deliverSnapshot(to: callbacks)
    }

    private func deliverSnapshot(to callbacks: [Observer]) {
        guard !callbacks.isEmpty else { return }
        do {
            let snapshot = CatalogSnapshot(
                albums: try albumPage(limit: CatalogDatabase.maximumPageSize),
                playlists: try playlists()
            )
            DispatchQueue.main.async { callbacks.forEach { $0(snapshot) } }
        } catch {
            // A failed observation read does not mutate the catalogue. Startup and explicit operations
            // retain the actionable database error; observers receive the next successful snapshot.
        }
    }
}
