import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// An album grouping (album + album-artist).
struct Album: Identifiable, Sendable, Hashable {
    var id: String { "\(artist)\u{1}\(title)" }
    let title: String
    let artist: String
    let trackCount: Int
    let year: Int?
    /// A track path we can pull embedded artwork from, if any.
    let artworkPath: String?
}

/// A pending or completed scrobble row.
struct ScrobbleRow: Sendable {
    let id: Int64
    let artist: String
    let album: String?
    let title: String
    let timestamp: Int
    let duration: Int?
}

/// SQLite-backed store. An actor so all database access is serialized; the
/// sqlite handle never escapes it.
actor Database {
    private var db: OpaquePointer?

    init(path: String) {
        var handle: OpaquePointer?
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK {
            db = handle
            exec("PRAGMA journal_mode=WAL;")
            exec("PRAGMA foreign_keys=ON;")
            migrate()
        } else {
            print("sqlite open failed: \(String(cString: sqlite3_errmsg(handle)))")
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Schema

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS tracks (
            id INTEGER PRIMARY KEY,
            path TEXT UNIQUE NOT NULL,
            title TEXT NOT NULL,
            artist TEXT,
            album TEXT,
            album_artist TEXT,
            track_no INTEGER,
            disc_no INTEGER,
            duration REAL,
            year INTEGER,
            has_artwork INTEGER NOT NULL DEFAULT 0,
            date_added REAL NOT NULL,
            mtime REAL
        );
        """)

        // Unicode-aware, case- and diacritic-insensitive full-text index.
        exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(
            title, artist, album, album_artist,
            content='tracks', content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        );
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS tracks_ai AFTER INSERT ON tracks BEGIN
            INSERT INTO tracks_fts(rowid, title, artist, album, album_artist)
            VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
        END;
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS tracks_ad AFTER DELETE ON tracks BEGIN
            INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, album_artist)
            VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
        END;
        """)
        exec("""
        CREATE TRIGGER IF NOT EXISTS tracks_au AFTER UPDATE ON tracks BEGIN
            INSERT INTO tracks_fts(tracks_fts, rowid, title, artist, album, album_artist)
            VALUES ('delete', old.id, old.title, old.artist, old.album, old.album_artist);
            INSERT INTO tracks_fts(rowid, title, artist, album, album_artist)
            VALUES (new.id, new.title, new.artist, new.album, new.album_artist);
        END;
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS scrobbles (
            id INTEGER PRIMARY KEY,
            artist TEXT NOT NULL,
            album TEXT,
            title TEXT NOT NULL,
            timestamp INTEGER NOT NULL,
            duration INTEGER,
            is_scrobbled INTEGER NOT NULL DEFAULT 0
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_scrobbles_pending ON scrobbles(is_scrobbled);")
    }

    // MARK: - Track ingestion

    /// Insert or update a track by path. Returns the row id.
    @discardableResult
    func upsertTrack(path: String, meta: TrackMetadata, hasArtwork: Bool, mtime: Double) -> Int64? {
        let sql = """
        INSERT INTO tracks (path, title, artist, album, album_artist, track_no, disc_no, duration, year, has_artwork, date_added, mtime)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET
            title=excluded.title, artist=excluded.artist, album=excluded.album,
            album_artist=excluded.album_artist, track_no=excluded.track_no, disc_no=excluded.disc_no,
            duration=excluded.duration, year=excluded.year, has_artwork=excluded.has_artwork, mtime=excluded.mtime;
        """
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        let title = meta.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        bindText(stmt, 1, path)
        bindText(stmt, 2, title)
        bindText(stmt, 3, meta.artist)
        bindText(stmt, 4, meta.album)
        bindText(stmt, 5, meta.albumArtist)
        bindInt(stmt, 6, meta.trackNo)
        bindInt(stmt, 7, meta.discNo)
        bindDouble(stmt, 8, meta.duration)
        bindInt(stmt, 9, nil)
        sqlite3_bind_int(stmt, 10, hasArtwork ? 1 : 0)
        sqlite3_bind_double(stmt, 11, Date().timeIntervalSince1970)
        sqlite3_bind_double(stmt, 12, mtime)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    /// Remove tracks whose paths are no longer present.
    func pruneMissing(existingPaths: Set<String>) {
        let all = allTrackPaths()
        for path in all where !existingPaths.contains(path) {
            guard let stmt = prepare("DELETE FROM tracks WHERE path = ?") else { continue }
            bindText(stmt, 1, path)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func knownPathsWithMtime() -> [String: Double] {
        var result: [String: Double] = [:]
        guard let stmt = prepare("SELECT path, mtime FROM tracks") else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            result[path] = sqlite3_column_double(stmt, 1)
        }
        return result
    }

    private func allTrackPaths() -> [String] {
        var paths: [String] = []
        guard let stmt = prepare("SELECT path FROM tracks") else { return paths }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            paths.append(String(cString: sqlite3_column_text(stmt, 0)))
        }
        return paths
    }

    func trackCount() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM tracks") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Queries

    func albums() -> [Album] {
        let sql = """
        SELECT COALESCE(NULLIF(album_artist,''), NULLIF(artist,''), 'Unknown Artist') AS aa,
               COALESCE(NULLIF(album,''), 'Unknown Album') AS al,
               COUNT(*) AS cnt,
               MAX(year),
               MAX(CASE WHEN has_artwork=1 THEN path END)
        FROM tracks
        GROUP BY aa, al
        ORDER BY aa COLLATE NOCASE, al COLLATE NOCASE;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var albums: [Album] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            albums.append(Album(
                title: String(cString: sqlite3_column_text(stmt, 1)),
                artist: String(cString: sqlite3_column_text(stmt, 0)),
                trackCount: Int(sqlite3_column_int64(stmt, 2)),
                year: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3)),
                artworkPath: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 4))
            ))
        }
        return albums
    }

    func tracks(inAlbum album: Album) -> [Track] {
        let sql = """
        SELECT \(trackColumns) FROM tracks
        WHERE COALESCE(NULLIF(album_artist,''), NULLIF(artist,''), 'Unknown Artist') = ?
          AND COALESCE(NULLIF(album,''), 'Unknown Album') = ?
        ORDER BY disc_no, track_no, title COLLATE NOCASE;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, album.artist)
        bindText(stmt, 2, album.title)
        return readTracks(stmt)
    }

    func allTracks() -> [Track] {
        let sql = "SELECT \(trackColumns) FROM tracks ORDER BY title COLLATE NOCASE;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        return readTracks(stmt)
    }

    /// Instant search over title/artist/album. Case- and diacritic-insensitive,
    /// Unicode-aware (works for any language via the unicode61 tokenizer).
    func search(_ query: String) -> [Track] {
        let match = ftsQuery(from: query)
        guard !match.isEmpty else { return [] }
        let sql = """
        SELECT \(trackColumns) FROM tracks
        JOIN tracks_fts ON tracks_fts.rowid = tracks.id
        WHERE tracks_fts MATCH ?
        ORDER BY rank
        LIMIT 500;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, match)
        return readTracks(stmt)
    }

    /// Build an FTS5 prefix query: each token becomes a prefix match, ANDed.
    private func ftsQuery(from query: String) -> String {
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // Fully qualified so the FTS JOIN in search() doesn't hit ambiguous columns.
    private let trackColumns = "tracks.id, tracks.path, tracks.title, tracks.artist, tracks.album, tracks.album_artist, tracks.track_no, tracks.disc_no, tracks.duration, tracks.has_artwork"

    private func readTracks(_ stmt: OpaquePointer) -> [Track] {
        var tracks: [Track] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let path = String(cString: sqlite3_column_text(stmt, 1))
            tracks.append(Track(
                libraryID: id,
                url: URL(fileURLWithPath: path),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                artist: columnText(stmt, 3),
                album: columnText(stmt, 4),
                albumArtist: columnText(stmt, 5),
                trackNo: columnInt(stmt, 6),
                discNo: columnInt(stmt, 7),
                duration: sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8),
                hasArtwork: sqlite3_column_int64(stmt, 9) == 1
            ))
        }
        return tracks
    }

    // MARK: - Scrobbles

    func insertScrobble(artist: String, album: String?, title: String, timestamp: Int, duration: Int?) {
        guard let stmt = prepare("INSERT INTO scrobbles (artist, album, title, timestamp, duration, is_scrobbled) VALUES (?,?,?,?,?,0)") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, artist)
        bindText(stmt, 2, album)
        bindText(stmt, 3, title)
        sqlite3_bind_int64(stmt, 4, Int64(timestamp))
        bindInt(stmt, 5, duration)
        sqlite3_step(stmt)
    }

    func pendingScrobbles(limit: Int = 50) -> [ScrobbleRow] {
        let sql = "SELECT id, artist, album, title, timestamp, duration FROM scrobbles WHERE is_scrobbled=0 ORDER BY timestamp ASC LIMIT ?;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [ScrobbleRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ScrobbleRow(
                id: sqlite3_column_int64(stmt, 0),
                artist: String(cString: sqlite3_column_text(stmt, 1)),
                album: columnText(stmt, 2),
                title: String(cString: sqlite3_column_text(stmt, 3)),
                timestamp: Int(sqlite3_column_int64(stmt, 4)),
                duration: columnInt(stmt, 5)
            ))
        }
        return rows
    }

    func markScrobbled(id: Int64) {
        guard let stmt = prepare("UPDATE scrobbles SET is_scrobbled=1 WHERE id=?") else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    func pendingScrobbleCount() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM scrobbles WHERE is_scrobbled=0") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    // MARK: - Low-level helpers

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
            print("sqlite exec error: \(String(cString: err)) for \(sql.prefix(60))")
            sqlite3_free(err)
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("sqlite prepare error: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindInt(_ stmt: OpaquePointer, _ idx: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int64(stmt, idx, Int64(value)) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func bindDouble(_ stmt: OpaquePointer, _ idx: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, idx, value) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL, let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
    private func columnInt(_ stmt: OpaquePointer, _ idx: Int32) -> Int? {
        sqlite3_column_type(stmt, idx) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, idx))
    }
}
