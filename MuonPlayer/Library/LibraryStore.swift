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
    private var scanner: FileScanner

    /// The folders being indexed. iOS has exactly one (Documents); on macOS the
    /// user adds and removes them.
    private(set) var roots: [LibraryRoot]

    /// The single-root convenience the iOS UI browses from. macOS can have zero
    /// roots (before the user adds a folder) or many, so it uses `roots` instead.
    var rootURL: URL { roots.first?.url ?? LibraryRoot.documents.url }

    init(roots: [LibraryRoot] = [.documents]) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dbPath = support.appendingPathComponent("muon-library.sqlite").path
        self.database = Database(path: dbPath)
        self.roots = roots
        self.scanner = FileScanner(roots: roots.map(\.url))
    }

    convenience init(rootURL: URL) {
        self.init(roots: [LibraryRoot(rootURL)])
    }

    /// Re-point the library at a new set of folders and reindex. Tracks under
    /// folders that were removed are pruned by the rescan.
    func setRoots(_ newRoots: [LibraryRoot]) async {
        roots = newRoots
        scanner = FileScanner(roots: newRoots.map(\.url))
        await rescan()
    }

    /// The root `path` lives under, if any.
    private func root(containing path: String) -> LibraryRoot? {
        roots.first { $0.relativePath(of: path) != nil }
    }

    func loadFromDatabase() async {
        #if os(iOS)
        // The data-container UUID changes on every install/update, so every stored
        // absolute path goes stale. Rewrite them to the current container before
        // any path-prefix query runs. macOS roots are user-chosen and stable.
        await database.normalizeContainerPaths(currentDocuments: LibraryRoot.documents.path)
        #endif
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

    /// All tracks under an artist's top-level folder, ordered by album release year
    /// then disc/track (used by the "Repeat Top Folder" playhead and shuffle).
    func artistFolderTracks(for track: Track) async -> [Track] {
        guard let folder = topFolder(for: track) else { return [] }
        let tracks = await database.tracks(underFolder: folder)
        return Self.orderByAlbum(tracks)
    }

    /// All tracks whose (effective) album-artist matches `track`'s, ordered by
    /// album release year then disc/track (used by the "Repeat Artist" playhead).
    func albumArtistTracks(for track: Track) async -> [Track] {
        let tracks = await database.tracks(byAlbumArtist: track.effectiveAlbumArtist)
        return Self.orderByAlbum(tracks)
    }

    /// Absolute path of the root-level folder holding `track` (its artist folder).
    /// Nil when the file sits directly in a root, which therefore has no artist
    /// folder to scope playback to.
    func topFolder(for track: Track) -> String? {
        let path = track.url.path
        return root(containing: path)?.topFolder(of: path)
    }

    /// Order tracks chronologically by album (year, then title), then disc/track,
    /// ignoring where the files live — an artist's discography plays in release
    /// order even when every album sits in one flat folder. Albums with no year
    /// tag anywhere sort last.
    ///
    /// A title is ranked by the *earliest* year on any of its tracks, but tracks
    /// within it are then split by their own year. So an untagged track stays with
    /// its album (nothing else shares the title), while two distinct same-titled
    /// albums — the DB keys albums as artist+title+year — stay separate blocks in
    /// release order rather than interleaving by track number.
    nonisolated static func orderByAlbum(_ tracks: [Track]) -> [Track] {
        var titleYear: [String: Int] = [:]
        for t in tracks {
            guard let y = t.year else { continue }
            titleYear[t.displayAlbum] = min(titleYear[t.displayAlbum] ?? y, y)
        }
        return tracks.sorted { a, b in
            let ya = titleYear[a.displayAlbum] ?? Int.max
            let yb = titleYear[b.displayAlbum] ?? Int.max
            if ya != yb { return ya < yb }
            if a.displayAlbum != b.displayAlbum {
                return a.displayAlbum.localizedStandardCompare(b.displayAlbum) == .orderedAscending
            }
            let tya = a.year ?? Int.max, tyb = b.year ?? Int.max
            if tya != tyb { return tya < tyb }
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

    /// Library tracks that live directly in `folder`, with full metadata.
    func folderTracks(in folder: URL) async -> [Track] {
        await database.tracks(directlyInFolder: LibraryRoot.canonicalPath(of: folder))
    }

    /// Load embedded artwork for a track path, decoded off the main actor.
    func artwork(forPath path: String) async -> PlatformImage? {
        let url = URL(fileURLWithPath: path)
        // Decode on a GCD queue, not the Swift cooperative pool: a rescan fills the
        // pool with non-suspending FFmpeg tasks, so a Task.detached here can wait
        // for a slot and never load while scanning. A .userInitiated GCD thread is
        // scheduled ahead of the .utility scan, so visible covers still appear.
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let meta = FFmpegMetadata.read(url: url, includeArtwork: true)
                cont.resume(returning: meta.artwork.flatMap(PlatformImage.init(data:)))
            }
        }
    }
}
