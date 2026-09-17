import Testing
import Foundation
@testable import MuonPlayer

/// Deleting from the phone: what goes, what is left, and what is refused.
@Suite("Library Delete")
@MainActor
struct LibraryDeleteTests {

    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muon-del-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(root: URL) -> (LibraryStore, () -> Void) {
        let name = "muon-del-\(UUID().uuidString).sqlite"
        let store = LibraryStore(roots: [LibraryRoot(root)], databaseName: name)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return (store, {
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: support.appendingPathComponent(name + suffix))
            }
            try? fm.removeItem(at: root)
        })
    }

    @Test("Deleting an album takes its folder, its cover and the empty artist folder")
    func albumFolderGoesToo() async throws {
        let root = try makeRoot()
        let (store, cleanup) = makeStore(root: root)
        defer { cleanup() }

        let album = root.appendingPathComponent("Arab Strap/Philophobia")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let files = ["01.mp3", "02.mp3"].map(album.appendingPathComponent)
        for file in files { try Data("x".utf8).write(to: file) }
        try Data("art".utf8).write(to: album.appendingPathComponent("cover.jpg"))

        await store.delete(tracks: files.map { Track(url: $0) })

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: album.path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent("Arab Strap").path))
        #expect(fm.fileExists(atPath: root.path))
    }

    @Test("A folder still holding music is left alone")
    func folderWithMusicSurvives() async throws {
        let root = try makeRoot()
        let (store, cleanup) = makeStore(root: root)
        defer { cleanup() }

        let album = root.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let gone = album.appendingPathComponent("01.mp3")
        let kept = album.appendingPathComponent("02.mp3")
        for file in [gone, kept] { try Data("x".utf8).write(to: file) }

        await store.delete(tracks: [Track(url: gone)])

        #expect(!FileManager.default.fileExists(atPath: gone.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }

    @Test("Deleting a library root is refused")
    func rootIsRefused() async throws {
        let root = try makeRoot()
        let (store, cleanup) = makeStore(root: root)
        defer { cleanup() }
        try Data("x".utf8).write(to: root.appendingPathComponent("loose.mp3"))

        #expect(await store.delete(folder: root) == 0)
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test("A folder prefix match is a range, so a name with a wildcard in it is safe")
    func wildcardFolderNames() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("muon-del-\(UUID().uuidString).sqlite").path
        let db = Database(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        var meta = TrackMetadata(); meta.title = "T"; meta.duration = 100
        for track in ["/m/100%/a.mp3", "/m/100%/b.mp3", "/m/1005/c.mp3", "/m/other/d.mp3"] {
            await db.upsertTrack(path: track, meta: meta, hasArtwork: false, mtime: 1)
        }
        #expect(await db.deleteTracks(underFolder: "/m/100%") == 2)
        #expect(await db.trackCount() == 2)
    }
}
