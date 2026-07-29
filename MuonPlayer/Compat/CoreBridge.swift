import Foundation

/// One album as the Android list needs it. `Album` itself is not public, and the
/// index is what the view passes back to say "play this one".
public struct AlbumItem: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let artist: String
    public let trackCount: Int
    public let year: Int?
    public let artworkPath: String?
}

public struct TrackItem: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let duration: Double
    public let codec: String
}

#if os(Android)
import CFFmpeg
import CSQLite

/// What the Android UI can ask of the core. Everything below delegates to the same
/// LibraryStore, Player and FFmpeg the Apple apps use; nothing here re-implements
/// library behaviour, it only flattens it into values a SwiftUI view can hold.
public enum MuonCore {
    public static var ffmpegVersion: String {
        let v = avcodec_version()
        return "\(v >> 16).\((v >> 8) & 0xff).\(v & 0xff)"
    }

    public static var sqliteVersion: String {
        String(cString: sqlite3_libversion())
    }

    public static var supportedExtensions: [String] {
        AudioFormat.supportedExtensions.sorted()
    }

    @MainActor
    public static let library = LibraryBridge()
}

@MainActor
public final class LibraryBridge {
    private var store = LibraryStore(roots: [])
    private var player = Player()
    private var albums: [Album] = []
    private var albumTracks: [Track] = []

    public private(set) var rootPath: String = ""
    public private(set) var status: String = "No folder chosen"

    // MARK: - Folders

    /// The directories under `path`, so the picker can walk the device without the
    /// Storage Access Framework — which would hand back content:// URLs that
    /// FileScanner, being FileManager-based, cannot walk.
    public nonisolated func subfolders(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.path }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// What the shared FileScanner sees under `path`, and whether the first file
    /// can actually be opened. Shared storage hands out directory listings freely
    /// and then refuses the reads, so "found" and "readable" are separate answers.
    public nonisolated func probe(_ path: String) -> String {
        let files = FileScanner(roots: [URL(fileURLWithPath: path)]).findAudioFiles()
        guard let first = files.first else { return "0 audio files" }
        let readable = FileManager.default.isReadableFile(atPath: first.path)
        let opened = (try? FileHandle(forReadingFrom: first)) != nil
        return "\(files.count) files · readable \(readable) · open \(opened)"
    }

    /// Walk the same pipeline the scan does, one stage at a time, and report where
    /// it stops. The scan is several awaits deep behind a detached task, so a stage
    /// that silently yields nothing is otherwise indistinguishable from an empty
    /// folder.
    public func diagnose(_ path: String) async -> String {
        var out: [String] = []
        let url = URL(fileURLWithPath: path)
        let root = LibraryRoot(url)
        out.append("root.path \(root.path)")

        // Everything the core persists — volume, repeat mode, the Last.fm session —
        // goes through Prefs, so one round-trip answers for all of it. Raw
        // UserDefaults is shown alongside because that is what silently loses it.
        let prefsSeen = Prefs.string(forKey: "muon.probe") != nil
        let defaultsSeen = UserDefaults.standard.string(forKey: "muon.probe") != nil
        Prefs.set("x", forKey: "muon.probe")
        UserDefaults.standard.set("x", forKey: "muon.probe")
        out.append("persisted prefs=\(prefsSeen) userdefaults=\(defaultsSeen)")
        out.append("saved root \(Prefs.string(forKey: Self.rootKey) ?? "-")")

        let files = FileScanner(roots: [url]).findAudioFiles()
        out.append("scanner \(files.count)")
        guard let first = files.first else { return out.joined(separator: "\n") }

        let meta = FFmpegMetadata.read(url: first, includeArtwork: false)
        out.append("tags \(meta.artist ?? "-") / \(meta.album ?? "-") / \(meta.title ?? "-")")

        let detached = await Task.detached(priority: .utility) { files.count }.value
        out.append("detached \(detached)")

        let known = await store.database.knownPathsWithMtime()
        out.append("known \(known.count)")

        let id = await store.database.upsertTrack(path: first.path, meta: meta,
                                                  hasArtwork: false, mtime: 1)
        out.append("upsert \(id.map(String.init) ?? "nil")")
        out.append(await store.database.selfTest())
        out.append("rows \(await store.database.trackCount())")
        out.append("albums \(await store.database.albums().count)")
        return out.joined(separator: "\n")
    }

    private static let rootKey = "androidLibraryRoot"

    /// Point the library at a folder and index it. This is the app's real scan:
    /// FileScanner walks it, FFmpegMetadata reads every tag, and the rows land in
    /// SQLite, followed by the detached seam pass that measures gapless trims.
    public func openFolder(_ path: String) async {
        rootPath = path
        Prefs.set(path, forKey: Self.rootKey)
        status = "Scanning…"
        await store.setRoots([LibraryRoot(URL(fileURLWithPath: path))])
        await publish(emptyMessage: "No albums found in \(path)")
    }

    /// Bring back the library the app already indexed. The rows are in SQLite, so
    /// a relaunch should show them without re-reading every tag; the folder is
    /// rescanned only when the user asks.
    public func restore() async {
        guard albums.isEmpty, let path = Prefs.string(forKey: Self.rootKey) else { return }
        rootPath = path
        store = LibraryStore(roots: [LibraryRoot(URL(fileURLWithPath: path))])
        await store.loadFromDatabase()
        await publish(emptyMessage: "No albums indexed yet")
    }

    private func publish(emptyMessage: String) async {
        albums = store.albums
        status = albums.isEmpty
            ? emptyMessage
            : "\(albums.count) albums, \(await store.allTracks().count) tracks"
    }

    public var scanStatus: String {
        if case .idle = store.scanPhase { return status }
        return store.scanPhase.label
    }

    public var albumRows: [AlbumItem] {
        albums.enumerated().map { i, a in
            AlbumItem(id: i, title: a.title, artist: a.artist,
                     trackCount: a.trackCount, year: a.year, artworkPath: a.artworkPath)
        }
    }

    // MARK: - Playback

    public func openAlbum(_ index: Int) async -> [TrackItem] {
        guard albums.indices.contains(index) else { return [] }
        albumTracks = await store.tracks(in: albums[index])
        return albumTracks.enumerated().map { i, t in
            TrackItem(id: i, title: t.title, duration: t.duration ?? 0, codec: t.format.rawValue)
        }
    }

    public func play(trackAt index: Int) {
        guard albumTracks.indices.contains(index) else { return }
        player.play(track: albumTracks[index], context: albumTracks)
    }

    public func togglePlayPause() { player.togglePlayPause() }
    public func next() { player.next() }
    public func previous() { player.previous() }
    public func stop() { player.stop() }

    public var isPlaying: Bool { player.isPlaying }
    public var currentTitle: String { player.currentTrack?.title ?? "" }
    public var currentArtist: String { player.currentTrack?.displayArtist ?? "" }
    public var currentTime: Double { player.currentTime }
    public var duration: Double { player.duration }

    /// Embedded cover bytes for a track path, decoded by the view with
    /// BitmapFactory — see PlatformImage in ImageCompat.
    public nonisolated func artworkData(forPath path: String) -> Data? {
        FFmpegMetadata.read(url: URL(fileURLWithPath: path), includeArtwork: true).artwork
    }
}
#endif
