import Testing
import Foundation
@testable import MuonPlayer

/// The scan's three decisions: what it prunes, when it reloads, and when it
/// stops looking.
@Suite("Library Scan Tests")
@MainActor
struct LibraryScanTests {

    private func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muon-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func addTrack(_ name: String, to dir: URL) throws {
        try Data("dummy".utf8).write(to: dir.appendingPathComponent(name))
    }

    /// A store on a throwaway database. `LibraryStore` puts it in Application
    /// Support, so the caller has to take the file away again.
    private func makeStore(roots: [URL]) -> (LibraryStore, () -> Void) {
        let name = "muon-scan-\(UUID().uuidString).sqlite"
        let store = LibraryStore(roots: roots.map(LibraryRoot.init), databaseName: name)
        store.settleDelay = .milliseconds(100)
        store.folderMinAge = 0
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return (store, {
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: support.appendingPathComponent(name + suffix))
            }
        })
    }

    private func makeDatabase(tracks paths: [String]) async -> Database {
        let db = Database(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("muon-prune-\(UUID().uuidString).sqlite").path)
        var meta = TrackMetadata(); meta.title = "T"; meta.duration = 100
        for path in paths {
            await db.upsertTrack(path: path, meta: meta, hasArtwork: false, mtime: 1)
        }
        return db
    }

    @Test("Pruning a folder reports how many rows it deleted, and spares deeper ones")
    func pruneFolderReturnsCount() async {
        let db = await makeDatabase(tracks: ["/m/1.mp3", "/m/2.mp3", "/m/deep/3.mp3"])
        #expect(await db.pruneTracks(directlyIn: "/m", keeping: ["1.mp3", "2.mp3"]) == 0)
        #expect(await db.pruneTracks(directlyIn: "/m", keeping: ["1.mp3"]) == 1)
        #expect(await db.trackCount() == 2)
    }

    @Test("Pruning a subtree spares a sibling that merely shares its prefix")
    func pruneUnderStopsAtTheSeparator() async {
        let db = await makeDatabase(tracks: ["/m/live/1.mp3", "/m/livex/2.mp3"])
        await db.upsertFolders([("/m/live", 1), ("/m/live/set", 2), ("/m/livex", 3)])
        #expect(await db.pruneUnder(prefix: "/m/live") == 1)
        #expect(await db.trackCount() == 1)
        #expect(await db.knownFolders().keys.sorted() == ["/m/livex"])
    }

    @Test("A scan that changes nothing does not reload the library")
    func idleScanDoesNotReload() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: dir)

        #expect(await store.rescan() == .changed)
        let version = store.version

        #expect(await store.rescan() == .unchanged)
        #expect(store.version == version)
    }

    @Test("A new file is picked up and reloads the library")
    func newFileIsPickedUp() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: dir)
        await store.rescan()
        let version = store.version

        try addTrack("b.mp3", to: dir)
        #expect(await store.rescan() == .changed)
        #expect(await store.database.trackCount() == 2)
        #expect(store.version > version)
    }

    @Test("An unreachable root keeps its tracks")
    func unreachableRootIsNotPruned() async throws {
        let kept = try makeFolder()
        let doomed = try makeFolder()
        let (store, cleanup) = makeStore(roots: [kept, doomed])
        defer { cleanup(); try? FileManager.default.removeItem(at: kept) }
        try addTrack("a.mp3", to: kept)
        try addTrack("b.mp3", to: doomed)

        await store.rescan()
        #expect(await store.database.trackCount() == 2)

        // The drive goes away.
        try FileManager.default.removeItem(at: doomed)
        #expect(await store.rescan() == .unchanged)
        #expect(await store.database.trackCount() == 2)
    }

    @Test("Every root unreachable scans nothing at all")
    func allRootsUnreachable() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup() }
        try addTrack("a.mp3", to: dir)

        await store.rescan()
        #expect(await store.database.trackCount() == 1)

        try FileManager.default.removeItem(at: dir)
        #expect(await store.rescan() == .unchanged)
        #expect(await store.database.trackCount() == 1)
    }

    @Test("A deleted file is pruned")
    func deletedFileIsPruned() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: dir)
        try addTrack("b.mp3", to: dir)
        await store.rescan()
        #expect(await store.database.trackCount() == 2)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.mp3"))
        #expect(await store.rescan() == .changed)
        #expect(await store.database.trackCount() == 1)
    }

    @Test("The settle loop keeps looking while files are still arriving")
    func settleLoopCatchesLateFiles() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: dir)

        // Lands during the first pause between passes, as the tail of a copy does.
        let late = Task.detached {
            try? await Task.sleep(for: .milliseconds(50))
            try? Data("dummy".utf8).write(to: dir.appendingPathComponent("b.mp3"))
        }
        await store.rescanUntilSettled()
        await late.value

        #expect(await store.database.trackCount() == 2)
        #expect(store.isScanning == false)
    }

    @Test("The settle loop returns when there is nothing to do")
    func settleLoopTerminates() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: dir)

        await store.rescanUntilSettled()
        await store.rescanUntilSettled()
        #expect(await store.database.trackCount() == 1)
    }

    // MARK: - The folder index

    @Test("A settled library is stat'ed, not listed")
    func secondPassListsNothing() async throws {
        let dir = try makeFolder()
        let sub = dir.appendingPathComponent("Artist")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: sub)

        await store.rescan()
        #expect(await store.rescan() == .unchanged)
        #expect(store.lastScan?.foldersStatted == 2)
        #expect(store.lastScan?.foldersListed == 0)
        #expect(store.lastScan?.filesRead == 0)
    }

    @Test("Only the folder that changed is listed")
    func onlyTheChangedFolderIsListed() async throws {
        let dir = try makeFolder()
        let a = dir.appendingPathComponent("A"), b = dir.appendingPathComponent("B")
        for sub in [a, b] {
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try addTrack("1.mp3", to: sub)
        }
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        await store.rescan()

        try addTrack("2.mp3", to: b)
        #expect(await store.rescan() == .changed)
        #expect(store.lastScan?.foldersListed == 1)
        #expect(await store.database.trackCount() == 3)
    }

    @Test("A subfolder created inside an indexed folder is walked")
    func newSubfolderIsWalked() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: dir)
        await store.rescan()

        let sub = dir.appendingPathComponent("New/Deeper")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try addTrack("b.mp3", to: sub)

        #expect(await store.rescan() == .changed)
        #expect(await store.database.trackCount() == 2)
    }

    @Test("A renamed folder moves its tracks and its index row")
    func renamedFolderIsReindexed() async throws {
        let dir = try makeFolder()
        let old = dir.appendingPathComponent("Old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: old)
        await store.rescan()

        let new = dir.appendingPathComponent("New")
        try FileManager.default.moveItem(at: old, to: new)
        #expect(await store.rescan() == .changed)

        let paths = await store.database.knownPathsWithMtime().keys
        #expect(paths.count == 1)
        #expect(paths.first?.hasSuffix("/New/a.mp3") == true)
        let folders = await store.database.knownFolders().keys
        #expect(folders.contains { $0.hasSuffix("/New") })
        #expect(!folders.contains { $0.hasSuffix("/Old") })
    }

    @Test("A removed folder takes its whole subtree with it")
    func removedFolderPrunesItsSubtree() async throws {
        let dir = try makeFolder()
        let deep = dir.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: deep)
        try addTrack("b.mp3", to: dir)
        await store.rescan()
        #expect(await store.database.trackCount() == 2)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("Artist"))
        #expect(await store.rescan() == .changed)
        #expect(await store.database.trackCount() == 1)
        #expect(await store.database.knownFolders().count == 1)
    }

    @Test("A folder too young to record is still listed on the next pass")
    func youngFolderIsListedAgain() async throws {
        let dir = try makeFolder()
        let album = dir.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        store.folderMinAge = 60
        try addTrack("01.mp3", to: album)
        let old = Date(timeIntervalSinceNow: -3600)
        for folder in [dir, dir.appendingPathComponent("Artist")] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: folder.path)
        }
        await store.rescan()

        try addTrack("02.mp3", to: album)
        #expect(await store.rescan() == .changed)
        #expect(await store.database.trackCount() == 2)
    }

    @Test("A file replaced in place is re-read")
    func replacedFileIsReRead() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.mp3")
        try addTrack("a.mp3", to: dir)
        await store.rescan()

        try FileManager.default.removeItem(at: file)
        try addTrack("a.mp3", to: dir)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: file.path)

        #expect(await store.rescan() == .changed)
        #expect(store.lastScan?.filesRead == 1)
        #expect(await store.database.trackCount() == 1)
    }

    @Test("Refresh re-reads a folder even though nothing moved")
    func refreshReReadsEverything() async throws {
        let dir = try makeFolder()
        let (store, cleanup) = makeStore(roots: [dir])
        defer { cleanup(); try? FileManager.default.removeItem(at: dir) }
        try addTrack("a.mp3", to: dir)
        await store.rescan()
        #expect(await store.rescan() == .unchanged)

        await store.refresh(folders: [dir])
        #expect(store.lastScan?.filesRead == 1)
        #expect(await store.database.trackCount() == 1)
    }

    @Test("Dropping a root prunes its tracks")
    func droppedRootIsPruned() async throws {
        let kept = try makeFolder(), dropped = try makeFolder()
        let (store, cleanup) = makeStore(roots: [kept, dropped])
        defer { cleanup(); try? FileManager.default.removeItem(at: kept)
                try? FileManager.default.removeItem(at: dropped) }
        try addTrack("a.mp3", to: kept)
        try addTrack("b.mp3", to: dropped)
        await store.rescan()
        #expect(await store.database.trackCount() == 2)

        await store.setRoots([LibraryRoot(kept)])
        #expect(await store.database.trackCount() == 1)
        #expect(store.trackCount == 1)
    }
}
