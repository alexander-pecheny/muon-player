import Foundation
import Observation

/// Owns the music library: scans files, extracts metadata via FFmpeg, persists
/// to SQLite, and exposes observable state for the UI.
@MainActor
@Observable
final class LibraryStore {
    private(set) var albums: [Album] = []
    private(set) var isScanning = false
    private(set) var trackCount = 0
    private(set) var scanProgress: (done: Int, total: Int)?

    let database: Database
    private let scanner: FileScanner

    /// Root folder of the music library (topmost folder = artist, per playhead).
    /// Symlinks are resolved so its path matches the `/private/var/…` form stored
    /// for track files (otherwise folder/playhead path prefixes never match).
    var rootURL: URL { scanner.rootURL.resolvingSymlinksInPath() }

    init(rootURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dbPath = support.appendingPathComponent("muon-library.sqlite").path
        self.database = Database(path: dbPath)
        self.scanner = FileScanner(rootURL: rootURL)
    }

    func loadFromDatabase() async {
        albums = await database.albums()
        trackCount = await database.trackCount()
    }

    /// Incrementally scan the library folder: read metadata for new/changed
    /// files, upsert into SQLite, prune deleted files.
    ///
    /// The library persists in Application Support and survives app updates, so a
    /// normal relaunch does *no* metadata work — the mtime diff below finds
    /// nothing to read and the scan UI never appears. Files are only re-read when
    /// they actually change on disk, or when `kScannerVersion` is bumped because
    /// the metadata-reading logic itself changed (a rare, deliberate event).
    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false; scanProgress = nil }

        // If the metadata-reading logic changed since this DB was populated,
        // re-read every file (repairs libraries scanned by the buggy tag reader).
        let dbVersion = await database.scannerVersion()
        let forceReadAll = dbVersion < kScannerVersion
        let known = await database.knownPathsWithMtime()

        // Enumerate the folder and diff against the DB off the main actor — for a
        // large library this is thousands of stat() calls we don't want blocking
        // the UI. Returns every current path (for pruning) and just the subset
        // whose metadata needs (re)reading.
        let (existingPaths, toRead) = await Task.detached(priority: .utility) { [scanner] in
            let files = scanner.findAudioFiles()
            let existingPaths = Set(files.map(\.path))
            var toRead: [(path: String, url: URL, mtime: Double)] = []
            for url in files {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate?.timeIntervalSince1970) ?? 0 ?? 0
                if !forceReadAll, let knownMtime = known[url.path], abs(knownMtime - mtime) < 1 {
                    continue // unchanged
                }
                toRead.append((url.path, url, mtime))
            }
            return (existingPaths, toRead)
        }.value

        // Only surface the scanning UI when there's genuine work to do, so an
        // ordinary relaunch (nothing changed) doesn't flash a progress indicator.
        if !toRead.isEmpty {
            await readAndUpsert(toRead)
        }

        await database.pruneMissing(existingPaths: existingPaths)
        if forceReadAll { await database.setScannerVersion(kScannerVersion) }
        await loadFromDatabase()
    }

    /// Read metadata for the given files concurrently (FFmpeg decode dominates the
    /// scan, so parallelism across cores is the big win) and upsert each result
    /// as it arrives. Upserts stay serialized through the Database actor.
    private func readAndUpsert(_ items: [(path: String, url: URL, mtime: Double)]) async {
        let total = items.count
        var processed = 0
        scanProgress = (0, total)

        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: (String, TrackMetadata, Double).self) { group in
            var next = 0
            func addTask() {
                guard next < items.count else { return }
                let item = items[next]; next += 1
                group.addTask(priority: .utility) {
                    (item.path, FFmpegMetadata.read(url: item.url, includeArtwork: false), item.mtime)
                }
            }
            for _ in 0..<min(maxConcurrent, items.count) { addTask() }

            while let (path, meta, mtime) = await group.next() {
                await database.upsertTrack(path: path, meta: meta, hasArtwork: meta.hasArtwork, mtime: mtime)
                processed += 1
                scanProgress = (processed, total)
                addTask()
            }
        }
    }

    private func readMetadata(url: URL) async -> TrackMetadata {
        await Task.detached(priority: .utility) {
            FFmpegMetadata.read(url: url, includeArtwork: false)
        }.value
    }

    // MARK: - Queries for UI

    func tracks(in album: Album) async -> [Track] {
        await database.tracks(inAlbum: album)
    }

    func allTracks() async -> [Track] {
        await database.allTracks()
    }

    func search(_ query: String) async -> [Track] {
        await database.search(query)
    }

    /// Albums most recently added to the library (for the Home tab).
    func recentAlbums(limit: Int = 30) async -> [Album] {
        await database.recentAlbums(limit: limit)
    }

    /// Grouped search: matching artists, albums, then songs. Artists and albums
    /// are filtered from the in-memory album list (already override-aware); songs
    /// use the SQLite full-text index.
    func searchAll(_ query: String) async -> SearchResults {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return SearchResults() }

        let songs = await database.search(q)

        let artistNames = Set(albums.map(\.artist)).filter { $0.localizedCaseInsensitiveContains(q) }
        let artists = artistNames
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                ArtistResult(name: name,
                             artworkPath: albums.first { $0.artist == name && $0.artworkPath != nil }?.artworkPath)
            }

        let matchedAlbums = albums
            .filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) }

        return SearchResults(artists: artists, albums: matchedAlbums, songs: songs)
    }

    /// All tracks under an artist's top-level folder, ordered by album subfolder
    /// then disc/track (used by the "Repeat Top Folder" playhead).
    func artistFolderTracks(for track: Track) async -> [Track] {
        guard let folder = topFolder(for: track) else { return [] }
        let tracks = await database.tracks(underRelativeTopFolder: folder)
        return orderByFolder(tracks)
    }

    /// All tracks whose (effective) album-artist matches `track`'s, ordered by
    /// album subfolder then disc/track (used by the "Repeat Artist" playhead).
    func albumArtistTracks(for track: Track) async -> [Track] {
        let tracks = await database.tracks(byAlbumArtist: track.effectiveAlbumArtist)
        return orderByFolder(tracks)
    }

    /// The first folder component of `track` under the app's Documents dir (its
    /// artist folder). Derived from the "/Documents/" marker in the stored path,
    /// so it doesn't depend on `/var` vs `/private/var` normalization.
    func topFolder(for track: Track) -> String? {
        let path = track.url.path
        guard let r = path.range(of: "/Documents/") else { return nil }
        let comps = path[r.upperBound...].split(separator: "/")
        // Need folder/.../file — a file directly in Documents has no artist folder.
        return comps.count >= 2 ? String(comps[0]) : nil
    }

    /// Order tracks by their album subfolder name, then disc/track/filename, so
    /// the playhead walks albums in folder order and tracks in play order.
    private func orderByFolder(_ tracks: [Track]) -> [Track] {
        tracks.sorted { a, b in
            let da = a.url.deletingLastPathComponent().path
            let db = b.url.deletingLastPathComponent().path
            if da != db { return da.localizedStandardCompare(db) == .orderedAscending }
            let dna = a.discNo ?? 0, dnb = b.discNo ?? 0
            if dna != dnb { return dna < dnb }
            let tna = a.trackNo ?? Int.max, tnb = b.trackNo ?? Int.max
            if tna != tnb { return tna < tnb }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: - Tag editing (writes tags into the actual files)

    /// Write the edits into the track's file, then re-index it. Returns an error
    /// message on failure, else nil.
    @discardableResult
    func applyTrackEdits(_ edits: TagEdits, to track: Track) async -> String? {
        let url = track.url
        do {
            try await Task.detached(priority: .userInitiated) { try TagWriter.write(edits, to: url) }.value
        } catch {
            return "\(error)"
        }
        await reindex(path: url.path)
        await loadFromDatabase()
        return nil
    }

    /// Apply album-wide edits to every track's file. Returns an error message if
    /// any track failed (others still applied).
    @discardableResult
    func applyAlbumEdits(_ edits: TagEdits, to album: Album) async -> String? {
        let tracks = await database.tracks(inAlbum: album)
        var firstError: String?
        for track in tracks {
            let url = track.url
            do {
                try await Task.detached(priority: .userInitiated) { try TagWriter.write(edits, to: url) }.value
                await reindex(path: url.path)
            } catch {
                if firstError == nil { firstError = "\(error)" }
            }
        }
        await loadFromDatabase()
        return firstError
    }

    /// Re-read one file's metadata into the library (after its tags changed).
    private func reindex(path: String) async {
        let url = URL(fileURLWithPath: path)
        let meta = await readMetadata(url: url)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? 0
        await database.upsertTrack(path: path, meta: meta, hasArtwork: meta.hasArtwork, mtime: mtime ?? 0)
    }

    // MARK: - History

    func history(limit: Int = 1000) async -> [HistoryEntry] {
        await database.history(limit: limit)
    }

    // MARK: - Folder browsing

    /// Library tracks that live directly in `folder`, with full metadata. Matched
    /// by the folder's path relative to the app's Documents dir.
    func folderTracks(in folder: URL) async -> [Track] {
        let path = folder.path
        let rel = path.range(of: "/Documents/").map { String(path[$0.upperBound...]) } ?? ""
        return await database.tracks(inRelativeFolder: rel)
    }

    /// Load embedded artwork for a track path, decoded off the main actor.
    func artwork(forPath path: String) async -> PlatformImage? {
        let url = URL(fileURLWithPath: path)
        return await Task.detached(priority: .utility) { () -> PlatformImage? in
            let meta = FFmpegMetadata.read(url: url, includeArtwork: true)
            guard let data = meta.artwork else { return nil }
            return PlatformImage(data: data)
        }.value
    }
}
