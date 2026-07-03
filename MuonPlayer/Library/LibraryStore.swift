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
    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false; scanProgress = nil }

        let files = scanner.findAudioFiles()
        let known = await database.knownPathsWithMtime()
        let existingPaths = Set(files.map { $0.path })

        var processed = 0
        scanProgress = (0, files.count)
        for url in files {
            let path = url.path
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
            processed += 1
            defer { scanProgress = (processed, files.count) }

            if let knownMtime = known[path], abs(knownMtime - (mtime ?? 0)) < 1 {
                continue // unchanged
            }
            let effectiveMtime = mtime ?? 0
            let meta = await readMetadata(url: url)
            await database.upsertTrack(path: path, meta: meta, hasArtwork: meta.hasArtwork, mtime: effectiveMtime)
        }

        await database.pruneMissing(existingPaths: existingPaths)
        await loadFromDatabase()
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
