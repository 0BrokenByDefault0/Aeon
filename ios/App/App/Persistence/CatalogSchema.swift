import Foundation

enum CatalogSchema {
    static let currentVersion = 2

    static let versionOne = [
        """
        CREATE TABLE albums (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) BETWEEN 1 AND 512),
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            year TEXT NOT NULL DEFAULT '',
            genre TEXT NOT NULL DEFAULT '',
            normalized_title TEXT NOT NULL,
            normalized_artist TEXT NOT NULL,
            artwork_key TEXT,
            imported_at REAL NOT NULL,
            updated_at REAL NOT NULL
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE tracks (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) BETWEEN 1 AND 512),
            album_id TEXT NOT NULL,
            sequence INTEGER NOT NULL CHECK(sequence > 0),
            disc_number INTEGER CHECK(disc_number IS NULL OR disc_number > 0),
            track_number INTEGER CHECK(track_number IS NULL OR track_number > 0),
            title TEXT NOT NULL,
            artist TEXT NOT NULL DEFAULT '',
            normalized_title TEXT NOT NULL,
            normalized_artist TEXT NOT NULL,
            duration REAL CHECK(duration IS NULL OR duration >= 0),
            byte_count INTEGER NOT NULL DEFAULT 0 CHECK(byte_count >= 0),
            media_kind TEXT NOT NULL CHECK(media_kind IN ('native', 'bookmark', 'legacyBlob')),
            media_path TEXT,
            media_bookmark BLOB,
            imported_at REAL NOT NULL,
            FOREIGN KEY(album_id) REFERENCES albums(id) ON DELETE CASCADE,
            UNIQUE(album_id, sequence)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE playlists (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) BETWEEN 1 AND 512),
            name TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE playlist_items (
            playlist_id TEXT NOT NULL,
            position INTEGER NOT NULL CHECK(position >= 0),
            track_id TEXT NOT NULL,
            PRIMARY KEY(playlist_id, position),
            FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
            FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE listening (
            track_id TEXT PRIMARY KEY NOT NULL,
            play_count INTEGER NOT NULL DEFAULT 0 CHECK(play_count >= 0),
            completed_count INTEGER NOT NULL DEFAULT 0 CHECK(completed_count >= 0),
            last_position REAL NOT NULL DEFAULT 0 CHECK(last_position >= 0),
            last_played_at REAL,
            FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
        "CREATE INDEX albums_sequence_idx ON albums(sequence DESC)",
        "CREATE INDEX albums_artist_idx ON albums(normalized_artist, sequence)",
        "CREATE INDEX albums_title_idx ON albums(normalized_title, sequence)",
        "CREATE INDEX tracks_album_order_idx ON tracks(album_id, disc_number, track_number, sequence)",
        "CREATE INDEX tracks_title_idx ON tracks(normalized_title, album_id)",
        "CREATE INDEX tracks_artist_idx ON tracks(normalized_artist, album_id)",
        "CREATE INDEX playlist_items_track_idx ON playlist_items(track_id)",
        "CREATE INDEX listening_recent_idx ON listening(last_played_at DESC)"
    ]

    static let versionTwo = [
        "ALTER TABLE albums ADD COLUMN normalized_genre TEXT NOT NULL DEFAULT ''",
        "CREATE INDEX albums_genre_idx ON albums(normalized_genre, sequence)",
        """
        CREATE TABLE settings (
            key TEXT PRIMARY KEY NOT NULL CHECK(length(key) BETWEEN 1 AND 128),
            value BLOB NOT NULL,
            updated_at REAL NOT NULL
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE sky_records (
            id TEXT PRIMARY KEY NOT NULL CHECK(length(id) BETWEEN 1 AND 512),
            kind TEXT NOT NULL CHECK(kind IN ('region', 'constellation', 'planet', 'camera')),
            sequence INTEGER NOT NULL,
            payload BLOB NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(kind, sequence)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE migration_staging (
            source_store TEXT NOT NULL,
            source_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('pending', 'materializing', 'complete', 'failed')),
            payload BLOB NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(source_store, source_id)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX sky_records_kind_idx ON sky_records(kind, sequence)",
        "CREATE INDEX migration_staging_status_idx ON migration_staging(status, source_store, source_id)"
    ]
}
