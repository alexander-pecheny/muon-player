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

    /// Bumped every time the library's contents are reloaded from SQLite. Views
    /// holding a derived snapshot — a track list, the recently-added shelf — key
    /// their reload on this. `trackCount` is not enough: editing tags regroups the
    /// albums without changing how many tracks there are, which is precisely when
    /// a stale snapshot is most visible.
    private(set) var version = 0

    /// What the scan is doing right now. Walking the folders is its own long
    /// phase on a big library — it has no total to count against, so it reports
    /// how many files it has found so far rather than showing a bare spinner.
    enum ScanPhase: Equatable {
        case idle
        case findingFiles(found: Int)
        case readingTags(done: Int, total: Int)

        var label: String {
            switch self {
            case .idle: return ""
            case .findingFiles(let n): return "Finding music… \(n) file\(n == 1 ? "" : "s")"
            case .readingTags(let done, let total): return "Reading tags \(done) / \(total)"
            }
        }

        /// 0…1 while reading tags; nil while walking folders (no known total).
        var fraction: Double? {
            guard case .readingTags(let done, let total) = self, total > 0 else { return nil }
            return Double(done) / Double(total)
        }
    }

    private(set) var scanPhase: ScanPhase = .idle

    let database: Database

    /// The folders being indexed. iOS has exactly one (Documents); on macOS the
    /// user adds and removes them.
    private(set) var roots: [LibraryRoot]

    /// The single-root convenience the iOS UI browses from. macOS can have zero
    /// roots (before the user adds a folder) or many, so it uses `roots` instead.
    var rootURL: URL { roots.first?.url ?? LibraryRoot.documents.url }

    init(roots: [LibraryRoot] = [.documents], databaseName: String = "muon-library.sqlite") {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let dbPath = support.appendingPathComponent(databaseName).path
        self.database = Database(path: dbPath)
        self.roots = roots
    }

    convenience init(rootURL: URL) {
        self.init(roots: [LibraryRoot(rootURL)])
    }

    /// Re-point the library at a new set of folders and reindex. Tracks under
    /// folders that were removed are pruned by the rescan.
    func setRoots(_ newRoots: [LibraryRoot]) async {
        roots = newRoots
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
        reindexAlbums()
        trackCount = await database.trackCount()
        GaplessTrims.shared.replaceAll(await database.gaplessTrims())
        version &+= 1
    }

    /// The seam scan: measure the encoder delay/padding stranded at each album transition
    /// and record it, so the decoder can trim it away.
    ///
    /// It runs *after* the library is up, detached and at background priority. The fast
    /// scan is what the user is waiting for — this only decides how the music will sound
    /// once they press play, and a track already measured is never measured again, so on
    /// an ordinary relaunch it finds nothing to do and costs nothing.
    private var gaplessTask: Task<Void, Never>?

    private func startGaplessMaintenance() {
        gaplessTask?.cancel()
        let database = self.database
        gaplessTask = Task.detached(priority: .utility) {
            await GaplessMaintenance.run(database: database)
        }
    }

    /// Lookup tables derived from `albums`, rebuilt whenever it is reloaded.
    ///
    /// `album(for:)` runs in the body of every track row and the search filter runs
    /// on every keystroke; both scanned the whole album list, which a 14k-track
    /// library feels. The folded keys also keep the filter off ICU's collation —
    /// `localizedCaseInsensitiveContains` is an order of magnitude dearer than
    /// `contains` on a pre-folded string.
    private var albumsByIdentity: [String: Album] = [:]
    private var albumsByArtistTitle: [String: Album] = [:]
    private var searchIndex: [AlbumSearchEntry] = []

    private func reindexAlbums() {
        albumsByIdentity = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        albumsByArtistTitle = Dictionary(albums.map { (Self.artistTitleKey($0.artist, $0.title), $0) },
                                         uniquingKeysWith: { a, _ in a })
        searchIndex = albums.map(AlbumSearchEntry.init)
    }

    private static func artistTitleKey(_ artist: String, _ title: String) -> String {
        "\(artist)\u{1}\(title)"
    }

    /// Incrementally scan the library folder: read metadata for new/changed
    /// files, upsert into SQLite, prune deleted files.
    ///
    /// The library persists in Application Support and survives app updates, so a
    /// normal relaunch does *no* metadata work — the mtime diff below finds
    /// nothing to read and the scan UI never appears. Files are only re-read when
    /// they actually change on disk, or when `kScannerVersion` is bumped because
    /// the metadata-reading logic itself changed (a rare, deliberate event).
    /// `busy` is deliberately not `unchanged`: the settle loop stops on
    /// `unchanged`, and a pass that merely collided with another scan has learnt
    /// nothing about whether the library is still moving.
    enum ScanOutcome { case busy, unchanged, changed }

    @discardableResult
    func rescan() async -> ScanOutcome {
        guard !isScanning else { return .busy }
        // If the metadata-reading logic changed since this DB was populated,
        // re-read every file (repairs libraries scanned by the buggy tag reader).
        let forceReadAll = await database.scannerVersion() < kScannerVersion
        let changed = await scan(folders: roots.map(\.url), pruneScope: nil, forceReadAll: forceReadAll)
        if forceReadAll { await database.setScannerVersion(kScannerVersion) }
        return changed ? .changed : .unchanged
    }

    /// Seconds between passes of the settle loop. A test shortens it.
    var settleDelay: Duration = .seconds(5)

    /// True while `rescanUntilSettled` is looping, so `scan` holds the seam pass
    /// back rather than starting it once per pass.
    private var settling = false

    /// Rescan, and keep rescanning until a pass finds nothing.
    ///
    /// One scan of a folder still being copied into sees half an album — the rest
    /// of the files are not there yet, and the ones that are may be truncated.
    /// Their mtimes change as the copy finishes, so successive passes pick up what
    /// the last one missed and the loop stops on the first quiet pass.
    func rescanUntilSettled() async {
        guard !settling else { return }
        settling = true
        defer { settling = false }

        var changed = false
        loop: while true {
            switch await rescan() {
            case .changed: changed = true
            case .busy: break            // wait for the other scan and look again
            case .unchanged: break loop
            }
            // A cancelled sleep throws, which is the loop's only way out from
            // under a folder whose files never stop changing.
            guard (try? await Task.sleep(for: settleDelay)) != nil else { return }
        }
        if changed { startGaplessMaintenance() }
    }

    /// Rescan because the app came to the front — the moment after the user was
    /// off in Finder or the Files app adding music.
    func rescanOnActivation() {
        Task { await rescanUntilSettled() }
    }

    /// Re-read just these folders — what the album screen's Refresh button does
    /// after the files were changed by some other app. Every file is read rather
    /// than mtime-diffed, since an outside tag editor may preserve the mtime, and
    /// only rows beneath `folders` are pruned.
    func refresh(folders: [URL]) async {
        guard !isScanning else { return }
        await scan(folders: folders, pruneScope: folders, forceReadAll: true)
    }

    /// Returns whether the library changed — files read, or rows pruned.
    @discardableResult
    private func scan(folders: [URL], pruneScope: [URL]?, forceReadAll: Bool) async -> Bool {
        // A root on an unmounted drive — or one the sandbox will not open — walks
        // as empty, and an unscoped prune would then delete every track on it: a
        // library silently emptied by pulling a cable, and a full re-read of the
        // drive when it comes back. Walk only what is readable, prune only that.
        let fm = FileManager.default
        let reachable = folders.filter { fm.isReadableFile(atPath: $0.path) }
        guard !reachable.isEmpty else { return false }
        let pruneScope = pruneScope ?? (reachable.count == folders.count ? nil : reachable)
        let folders = reachable

        isScanning = true
        scanPhase = .findingFiles(found: 0)
        defer { isScanning = false; scanProgress = nil; scanPhase = .idle }

        let known = await database.knownPathsWithMtime()
        let scanner = FileScanner(roots: folders)

        // Enumerate the folder and diff against the DB off the main actor — for a
        // large library this is thousands of stat() calls we don't want blocking
        // the UI. Returns every current path (for pruning) and just the subset
        // whose metadata needs (re)reading.
        let (existingPaths, toRead) = await Task.detached(priority: .utility) { [scanner] in
            let files = scanner.findAudioFiles { found in
                Task { @MainActor [weak self] in
                    guard let self, self.isScanning else { return }
                    self.scanPhase = .findingFiles(found: found)
                }
            }
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

        let removed = await database.pruneMissing(existingPaths: existingPaths,
                                                  underFolders: pruneScope?.map(LibraryRoot.canonicalPath(of:)))

        // Reloading means re-running the album grouping over the whole library and
        // rebuilding every view that holds a snapshot of it. A scan that found
        // nothing — every launch, and every activation but the interesting one —
        // has no business doing that.
        // Unconditional, so a seam pass cut short by quitting resumes on the next
        // launch even though that launch finds nothing to index. Inside the settle
        // loop it is held back and started once, at the end.
        if !settling { startGaplessMaintenance() }

        guard !toRead.isEmpty || removed > 0 else { return false }
        await loadFromDatabase()
        return true
    }

    /// Read metadata for the given files concurrently and upsert the results.
    ///
    /// Reading one file's tags costs ~2ms, so a 14k-track library should index in
    /// seconds. What made it take minutes was per-file work in *this* loop: each
    /// `await` on the database actor handed the main actor back to SwiftUI, which
    /// then re-rendered whatever the freshly-published progress had invalidated.
    ///
    /// Batching the upserts removes almost all of those hand-offs, and throttling
    /// progress bounds how often the UI can redraw. The third leg is on the view
    /// side — see ScanStatusView, which keeps the invalidation off the root view.
    private func readAndUpsert(_ items: [(path: String, url: URL, mtime: Double)]) async {
        let total = items.count
        var processed = 0
        publishProgress(done: 0, total: total)

        var batch: [TrackUpsert] = []
        batch.reserveCapacity(Self.batchSize)

        func flush() async {
            guard !batch.isEmpty else { return }
            await database.upsertTracks(batch)
            batch.removeAll(keepingCapacity: true)
        }

        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: TrackUpsert.self) { group in
            var next = 0
            func addTask() {
                guard next < items.count else { return }
                let item = items[next]; next += 1
                group.addTask(priority: .utility) {
                    let meta = FFmpegMetadata.read(url: item.url, includeArtwork: false)
                    return TrackUpsert(path: item.path, meta: meta, hasArtwork: meta.hasArtwork, mtime: item.mtime)
                }
            }
            for _ in 0..<min(maxConcurrent, items.count) { addTask() }

            while let result = await group.next() {
                batch.append(result)
                processed += 1
                if batch.count >= Self.batchSize { await flush() }
                publishProgress(done: processed, total: total)
                addTask()
            }
        }
        await flush()
        publishProgress(done: total, total: total, force: true)
    }

    private static let batchSize = 200

    /// Rate-limits progress publication to ~10 Hz.
    private var lastProgressPublish = Date.distantPast
    private func publishProgress(done: Int, total: Int, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastProgressPublish) > 0.1 else { return }
        lastProgressPublish = Date()
        scanProgress = (done, total)
        scanPhase = .readingTags(done: done, total: total)
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

    /// The album a track is filed under, as the album list groups them. The year
    /// is part of an album's identity, but a track can carry a different one from
    /// the release it sits in, so fall back to artist + title.
    func album(for track: Track) -> Album? {
        let artist = track.effectiveAlbumArtist, title = track.displayAlbum
        let identity = "\(artist)\u{1}\(title)\u{1}\(track.year.map(String.init) ?? "")"
        return albumsByIdentity[identity]
            ?? albumsByArtistTitle[Self.artistTitleKey(artist, title)]
    }

    /// The album that now holds the file at `path`. This is how the album screen
    /// follows itself across a tag edit that rewrote the very fields its identity
    /// is built from — the file's path is the one thing tag editing never changes.
    func album(containingPath path: String) async -> Album? {
        guard let track = await database.track(atPath: path) else { return nil }
        return album(for: track)
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

        let index = searchIndex
        async let songs = database.search(q)
        async let grouped = Task.detached(priority: .userInitiated) {
            AlbumSearchEntry.match(q, in: index)
        }.value

        let (artists, matchedAlbums) = await grouped
        return SearchResults(artists: artists, albums: matchedAlbums, songs: await songs)
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
    ///
    /// Unlike the folder-scoped orders, this one reaches across roots, so a lossy
    /// mirror of an album lands right beside the lossless original — same album,
    /// same track number — and the same song would play twice in a row. The
    /// duplicates are collapsed to one copy each.
    func albumArtistTracks(for track: Track) async -> [Track] {
        let tracks = await database.tracks(byAlbumArtist: track.effectiveAlbumArtist)
        return Self.collapseDuplicates(Self.orderByAlbum(tracks), preferring: track)
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

    /// Keep one file per recording, in the order given. `anchor` — the track that
    /// is playing — always survives, so rebuilding the timeline around it never
    /// drops the playhead's own file out from under it.
    nonisolated static func collapseDuplicates(_ tracks: [Track], preferring anchor: Track?) -> [Track] {
        var kept: [Track] = []
        var slot: [String: Int] = [:]
        for track in tracks {
            let key = recordingKey(track)
            if let i = slot[key], sameLength(kept[i], track) {
                if isBetterCopy(track, than: kept[i], anchor: anchor) { kept[i] = track }
            } else {
                slot[key] = kept.count
                kept.append(track)
            }
        }
        return kept
    }

    /// Where the tags place a track within its album. Two files agreeing on all of
    /// it are the same song; what differs is only which encode of it you have.
    private nonisolated static func recordingKey(_ t: Track) -> String {
        [t.displayAlbum.lowercased(), String(t.discNo ?? 1),
         t.trackNo.map(String.init) ?? "", t.title.lowercased()].joined(separator: "\u{1}")
    }

    /// A transcode differs from its source by the encoder's priming delay — a few
    /// milliseconds. A second of slack is still far tighter than any alternate
    /// take, remaster or live version that might share the same tags.
    private nonisolated static func sameLength(_ a: Track, _ b: Track) -> Bool {
        guard let da = a.duration, let db = b.duration else { return false }
        return abs(da - db) <= 1
    }

    private static let losslessCodecs: Set<String> = [
        "flac", "alac", "wavpack", "ape", "tta",
        "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f32be", "pcm_s16be", "pcm_u8",
    ]

    private nonisolated static func isBetterCopy(_ a: Track, than b: Track, anchor: Track?) -> Bool {
        if let anchor {
            if a.url == anchor.url { return true }
            if b.url == anchor.url { return false }
        }
        let la = losslessCodecs.contains(a.codec ?? ""), lb = losslessCodecs.contains(b.codec ?? "")
        if la != lb { return la }
        return (a.bitrate ?? 0) > (b.bitrate ?? 0)
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

    /// The track's folder, relative to whichever library root holds it — what to
    /// show when two rips of one album (say FLAC and MP3) need telling apart.
    /// Falls back to the root's own name for a file sitting directly in it.
    func relativeFolder(for track: Track) -> String {
        let folder = track.url.deletingLastPathComponent().path
        guard let root = root(containing: track.url.path) else { return folder }
        return root.relativePath(of: folder) ?? root.name
    }

    /// Library tracks that live directly in `folder`, with full metadata.
    func folderTracks(in folder: URL) async -> [Track] {
        await database.tracks(directlyInFolder: LibraryRoot.canonicalPath(of: folder))
    }

    /// Load embedded artwork for a track path, decoded off the main actor.
    ///
    /// `maxPixel` caps the decoded size — grid cells ask for a thumbnail rather
    /// than a full 1500²-pixel cover, which is the difference between a smooth
    /// scroll and a stuttering one. Pass a large value for full-size art.
    func artwork(forPath path: String, maxPixel: Int = 400) async -> PlatformImage? {
        let url = URL(fileURLWithPath: path)
        // Decode on a GCD queue, not the Swift cooperative pool: a rescan fills the
        // pool with non-suspending FFmpeg tasks, so a Task.detached here can wait
        // for a slot and never load while scanning. A .userInitiated GCD thread is
        // scheduled ahead of the .utility scan, so visible covers still appear.
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let meta = FFmpegMetadata.read(url: url, includeArtwork: true)
                guard let data = meta.artwork else { cont.resume(returning: nil); return }
                cont.resume(returning: PlatformImage.thumbnail(from: data, maxPixel: maxPixel))
            }
        }
    }
}
