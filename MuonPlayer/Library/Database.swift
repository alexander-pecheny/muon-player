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

/// A locally-played history entry with its scrobble outcome.
struct HistoryEntry: Identifiable, Sendable {
    enum ScrobbleState: String, Sendable {
        case scrobbled, pending, ineligible
    }
    let id: Int64
    let artist: String
    let album: String?
    let title: String
    let playedAt: Int          // unix seconds
    let scrobbleState: ScrobbleState
    let duration: Int?         // track length, seconds
    let listened: Int?         // seconds actually played
}

/// Fields a user can override via tag editing (stored in the DB, layered over
/// the file's own tags so the source files are never modified).
struct TagEdits: Sendable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNo: Int?
    var composer: String?
    var year: Int?
}

/// The current metadata-reading logic version. Bump to force a full re-read of
/// every file on next launch (used to repair libraries scanned by a buggy
/// reader — e.g. the AV_DICT_IGNORE_SUFFIX album/album_artist collision).
let kScannerVersion: Int32 = 4

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

        // Columns added after the initial schema. Each is nullable so older DBs
        // upgrade in place without a rebuild.
        addColumn("tracks", "composer", "TEXT")
        addColumn("tracks", "bitrate", "INTEGER")
        addColumn("tracks", "codec", "TEXT")
        // User tag overrides (never touched by the file scanner).
        addColumn("tracks", "ov_title", "TEXT")
        addColumn("tracks", "ov_artist", "TEXT")
        addColumn("tracks", "ov_album", "TEXT")
        addColumn("tracks", "ov_album_artist", "TEXT")
        addColumn("tracks", "ov_composer", "TEXT")
        addColumn("tracks", "ov_track_no", "INTEGER")

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

        // Unlimited local play history. `scrobble_state` records the eligibility
        // outcome at play time: scrobbled / pending / ineligible.
        exec("""
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY,
            path TEXT,
            artist TEXT NOT NULL,
            album TEXT,
            title TEXT NOT NULL,
            played_at INTEGER NOT NULL,
            scrobble_state TEXT NOT NULL DEFAULT 'ineligible',
            scrobble_id INTEGER
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_history_played ON history(played_at DESC);")
        // Track length + how many seconds were actually played (added later).
        addColumn("history", "duration", "INTEGER")
        addColumn("history", "listened", "INTEGER")
    }

    /// Add a column if the table doesn't already have it (poor-man's migration).
    private func addColumn(_ table: String, _ name: String, _ type: String) {
        guard let stmt = prepare("PRAGMA table_info(\(table))") else { return }
        var exists = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == name { exists = true; break }
        }
        sqlite3_finalize(stmt)
        if !exists { exec("ALTER TABLE \(table) ADD COLUMN \(name) \(type);") }
    }

    // MARK: - Scanner version

    /// PRAGMA user_version stores the scanner version the DB was last populated
    /// with. If it lags `kScannerVersion`, the store forces a full re-read.
    func scannerVersion() -> Int32 {
        guard let stmt = prepare("PRAGMA user_version") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    func setScannerVersion(_ v: Int32) {
        exec("PRAGMA user_version = \(v);")
    }

    // MARK: - Track ingestion

    /// Insert or update a track by path. Returns the row id.
    @discardableResult
    func upsertTrack(path: String, meta: TrackMetadata, hasArtwork: Bool, mtime: Double) -> Int64? {
        // Only file-derived columns are written here; ov_* override columns are
        // deliberately left untouched so user tag edits survive rescans.
        let sql = """
        INSERT INTO tracks (path, title, artist, album, album_artist, composer, track_no, disc_no, duration, bitrate, codec, year, has_artwork, date_added, mtime)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(path) DO UPDATE SET
            title=excluded.title, artist=excluded.artist, album=excluded.album,
            album_artist=excluded.album_artist, composer=excluded.composer,
            track_no=excluded.track_no, disc_no=excluded.disc_no,
            duration=excluded.duration, bitrate=excluded.bitrate, codec=excluded.codec,
            year=excluded.year, has_artwork=excluded.has_artwork, mtime=excluded.mtime;
        """
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        let title = meta.title ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        bindText(stmt, 1, path)
        bindText(stmt, 2, title)
        bindText(stmt, 3, meta.artist)
        bindText(stmt, 4, meta.album)
        bindText(stmt, 5, meta.albumArtist)
        bindText(stmt, 6, meta.composer)
        bindInt(stmt, 7, meta.trackNo)
        bindInt(stmt, 8, meta.discNo)
        bindDouble(stmt, 9, meta.duration)
        bindInt(stmt, 10, meta.bitrate)
        bindText(stmt, 11, meta.codec)
        bindInt(stmt, 12, meta.year)
        sqlite3_bind_int(stmt, 13, hasArtwork ? 1 : 0)
        sqlite3_bind_double(stmt, 14, Date().timeIntervalSince1970)
        sqlite3_bind_double(stmt, 15, mtime)
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

    // Effective (override-aware) field expressions used across queries. An empty
    // override string counts as "no override" so clearing an edit is possible.
    // Base columns are qualified with `tracks.` so the FTS JOIN in search()
    // (whose virtual table also has title/artist/album columns) stays unambiguous.
    private let effTitle = "COALESCE(NULLIF(tracks.ov_title,''), tracks.title)"
    private let effArtist = "COALESCE(NULLIF(tracks.ov_artist,''), tracks.artist)"
    private let effAlbumArtist = "COALESCE(NULLIF(tracks.ov_album_artist,''), tracks.album_artist)"
    private let effComposer = "COALESCE(NULLIF(tracks.ov_composer,''), tracks.composer)"
    private let effTrackNo = "COALESCE(tracks.ov_track_no, tracks.track_no)"
    private let effAlbum = "COALESCE(NULLIF(tracks.ov_album,''), tracks.album)"
    private let effAlbumArtistGroup = "COALESCE(NULLIF(tracks.ov_album_artist,''), NULLIF(tracks.album_artist,''), NULLIF(tracks.ov_artist,''), NULLIF(tracks.artist,''), 'Unknown Artist')"
    private let effAlbumGroup = "COALESCE(NULLIF(tracks.ov_album,''), NULLIF(tracks.album,''), 'Unknown Album')"

    func albums() -> [Album] {
        let sql = """
        SELECT \(effAlbumArtistGroup) AS aa,
               \(effAlbumGroup) AS al,
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

    /// Albums most recently added to the library (newest track wins), for the
    /// Home tab's "Recently Added" shelf.
    func recentAlbums(limit: Int) -> [Album] {
        let sql = """
        SELECT \(effAlbumArtistGroup) AS aa,
               \(effAlbumGroup) AS al,
               COUNT(*) AS cnt,
               MAX(year),
               MAX(CASE WHEN has_artwork=1 THEN path END),
               MAX(date_added) AS added
        FROM tracks
        GROUP BY aa, al
        ORDER BY added DESC
        LIMIT ?;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
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
        WHERE \(effAlbumArtistGroup) = ?
          AND \(effAlbumGroup) = ?
        ORDER BY disc_no, \(effTrackNo), \(effTitle) COLLATE NOCASE;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, album.artist)
        bindText(stmt, 2, album.title)
        return readTracks(stmt)
    }

    func allTracks() -> [Track] {
        let sql = "SELECT \(trackColumns) FROM tracks ORDER BY \(effTitle) COLLATE NOCASE;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        return readTracks(stmt)
    }

    /// All tracks under a Documents-relative top folder (the artist folder).
    /// Matched via `%/Documents/<folder>/%` so it's robust to `/var` vs
    /// `/private/var` and to app-container UUID changes. Used by the playhead.
    func tracks(underRelativeTopFolder folder: String) -> [Track] {
        let sql = """
        SELECT \(trackColumns) FROM tracks
        WHERE path LIKE ? ESCAPE '\\'
        ORDER BY path COLLATE NOCASE;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, "%/Documents/" + escapeLike(folder + "/") + "%")
        return readTracks(stmt)
    }

    /// All tracks whose effective album-artist equals `artist` (used by the
    /// "Repeat Artist" playhead — tag-based, so it spans folders).
    func tracks(byAlbumArtist artist: String) -> [Track] {
        let sql = """
        SELECT \(trackColumns) FROM tracks
        WHERE \(effAlbumArtistGroup) = ?
        ORDER BY path COLLATE NOCASE;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, artist)
        return readTracks(stmt)
    }

    /// Library tracks that are direct children of a Documents-relative folder
    /// (used by the Folders browser). `rel` is "" for the Documents root. Matched
    /// via `%/Documents/<rel>/…` so it's robust to `/var` vs `/private/var` and
    /// container-UUID changes.
    func tracks(inRelativeFolder rel: String) -> [Track] {
        let base = rel.isEmpty ? "" : (rel.hasSuffix("/") ? rel : rel + "/")
        let prefix = "%/Documents/" + escapeLike(base)
        let sql = """
        SELECT \(trackColumns) FROM tracks
        WHERE path LIKE ? ESCAPE '\\' AND path NOT LIKE ? ESCAPE '\\'
        ORDER BY path COLLATE NOCASE;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, prefix + "%")
        bindText(stmt, 2, prefix + "%/%")
        return readTracks(stmt)
    }

    private func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
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

    // Fully qualified / effective columns so the FTS JOIN in search() doesn't
    // hit ambiguous columns and so user overrides are applied on read.
    private var trackColumns: String {
        "tracks.id, tracks.path, \(effTitle), \(effArtist), \(effAlbum), \(effAlbumArtist), \(effComposer), \(effTrackNo), tracks.disc_no, tracks.duration, tracks.bitrate, tracks.codec, tracks.has_artwork, tracks.year"
    }

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
                composer: columnText(stmt, 6),
                trackNo: columnInt(stmt, 7),
                discNo: columnInt(stmt, 8),
                year: columnInt(stmt, 13),
                duration: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 9),
                bitrate: columnInt(stmt, 10),
                codec: columnText(stmt, 11),
                hasArtwork: sqlite3_column_int64(stmt, 12) == 1
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

    /// State of the scrobble matching this play: `true` = already accepted by
    /// Last.fm, `false` = queued but still pending, `nil` = none was ever queued.
    /// Lets a history row be written with the correct state even when the
    /// scrobble was accepted before the row existed.
    func scrobbleState(artist: String, title: String, timestamp: Int) -> Bool? {
        guard let stmt = prepare("""
        SELECT is_scrobbled FROM scrobbles
        WHERE artist=? AND title=? AND ABS(timestamp-?)<=2
        ORDER BY ABS(timestamp-?) LIMIT 1;
        """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, artist)
        bindText(stmt, 2, title)
        sqlite3_bind_int64(stmt, 3, Int64(timestamp))
        sqlite3_bind_int64(stmt, 4, Int64(timestamp))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0) == 1
    }

    // MARK: - Tag editing (non-destructive overrides)

    /// Apply overrides to a single track. A non-nil field is written as-is (an
    /// empty string clears the override); a nil field is left unchanged.
    func setTrackOverrides(id: Int64, _ edits: TagEdits) {
        var sets: [String] = []
        var binders: [(OpaquePointer) -> Void] = []
        func str(_ col: String, _ v: String?) {
            guard let v else { return }
            sets.append("\(col)=?")
            binders.append { self.bindText($0, Int32(binders.count + 1), v) }
        }
        str("ov_title", edits.title)
        str("ov_artist", edits.artist)
        str("ov_album", edits.album)
        str("ov_album_artist", edits.albumArtist)
        str("ov_composer", edits.composer)
        if let t = edits.trackNo {
            sets.append("ov_track_no=?")
            binders.append { self.bindInt($0, Int32(binders.count + 1), t) }
        }
        guard !sets.isEmpty else { return }
        let sql = "UPDATE tracks SET \(sets.joined(separator: ", ")) WHERE id=?;"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }
        for b in binders { b(stmt) }
        sqlite3_bind_int64(stmt, Int32(binders.count + 1), id)
        sqlite3_step(stmt)
    }

    /// Apply album-wide overrides (album title / artist / album-artist / composer)
    /// to every track currently grouped under `album`.
    func setAlbumOverrides(album: Album, _ edits: TagEdits) {
        let ids = trackIDs(inAlbum: album)
        for id in ids { setTrackOverrides(id: id, edits) }
    }

    private func trackIDs(inAlbum album: Album) -> [Int64] {
        let sql = """
        SELECT tracks.id FROM tracks
        WHERE \(effAlbumArtistGroup) = ? AND \(effAlbumGroup) = ?;
        """
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, album.artist)
        bindText(stmt, 2, album.title)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    // MARK: - Play history

    func insertHistory(path: String?, artist: String, album: String?, title: String,
                       playedAt: Int, state: HistoryEntry.ScrobbleState,
                       duration: Int?, listened: Int?) {
        guard let stmt = prepare("INSERT INTO history (path, artist, album, title, played_at, scrobble_state, duration, listened) VALUES (?,?,?,?,?,?,?,?)") else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, path)
        bindText(stmt, 2, artist)
        bindText(stmt, 3, album)
        bindText(stmt, 4, title)
        sqlite3_bind_int64(stmt, 5, Int64(playedAt))
        bindText(stmt, 6, state.rawValue)
        bindInt(stmt, 7, duration)
        bindInt(stmt, 8, listened)
        sqlite3_step(stmt)
    }

    /// Mark the most recent matching history row as scrobbled once Last.fm accepts
    /// it (pending → scrobbled).
    func markHistoryScrobbled(artist: String, title: String, playedAt: Int) {
        guard let stmt = prepare("""
        UPDATE history SET scrobble_state='scrobbled'
        WHERE id = (SELECT id FROM history WHERE artist=? AND title=? AND ABS(played_at-?)<=2 AND scrobble_state='pending'
                    ORDER BY ABS(played_at-?) LIMIT 1);
        """) else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, artist)
        bindText(stmt, 2, title)
        sqlite3_bind_int64(stmt, 3, Int64(playedAt))
        sqlite3_bind_int64(stmt, 4, Int64(playedAt))
        sqlite3_step(stmt)
    }

    func history(limit: Int = 1000) -> [HistoryEntry] {
        let sql = "SELECT id, artist, album, title, played_at, scrobble_state, duration, listened FROM history ORDER BY played_at DESC, id DESC LIMIT ?;"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var rows: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(HistoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                artist: String(cString: sqlite3_column_text(stmt, 1)),
                album: columnText(stmt, 2),
                title: String(cString: sqlite3_column_text(stmt, 3)),
                playedAt: Int(sqlite3_column_int64(stmt, 4)),
                scrobbleState: HistoryEntry.ScrobbleState(rawValue: columnText(stmt, 5) ?? "ineligible") ?? .ineligible,
                duration: columnInt(stmt, 6),
                listened: columnInt(stmt, 7)
            ))
        }
        return rows
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
