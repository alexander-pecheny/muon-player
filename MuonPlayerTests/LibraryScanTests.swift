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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return (store, {
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: support.appendingPathComponent(name + suffix))
            }
        })
    }

    @Test("Pruning reports how many rows it deleted")
    func pruneReturnsCount() async {
        let db = Database(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("muon-prune-\(UUID().uuidString).sqlite").path)
        var meta = TrackMetadata(); meta.title = "T"; meta.duration = 100
        for i in 1...3 {
            await db.upsertTrack(path: "/m/\(i).mp3", meta: meta, hasArtwork: false, mtime: 1)
        }
        #expect(await db.pruneMissing(existingPaths: ["/m/1.mp3", "/m/2.mp3", "/m/3.mp3"]) == 0)
        #expect(await db.pruneMissing(existingPaths: ["/m/1.mp3"]) == 2)
        #expect(await db.trackCount() == 1)
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
}
