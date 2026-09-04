import Testing
import Foundation
@testable import MuonPlayer

/// Cover images beside the music, for tracks whose tags carry none.
@Suite("Folder Artwork")
struct FolderArtTests {

    @Test("cover beats folder beats front beats anything else, and non-images do not count")
    func ranking() {
        let rank = FileScanner.FolderArt.rank
        #expect(rank("cover.jpg") == 0)
        #expect(rank("Folder.PNG") == 1)
        #expect(rank("front.jpeg") == 2)
        #expect(rank("AlbumArt.jpg") == 3)
        #expect(rank("back of sleeve.webp") == 4)
        #expect(rank("notes.txt") == nil)
        #expect(rank("01 Track.flac") == nil)
    }

    @Test("The walk picks the best image in each folder")
    func picksBestPerFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muon-art-\(UUID().uuidString)")
        let album = root.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for name in ["01.mp3", "back.jpg", "cover.jpg", "notes.txt"] {
            try Data("x".utf8).write(to: album.appendingPathComponent(name))
        }
        let found = FileScanner(roots: [root]).findAudioFilesAndArt()
        #expect(found.files.count == 1)
        #expect(found.art[album.path]?.hasSuffix("cover.jpg") == true)
    }

    @Test("A disc folder's own cover wins; one without inherits the album's")
    func deeperFolderWins() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("muon-art-\(UUID().uuidString).sqlite").path
        let db = Database(path: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        var meta = TrackMetadata(); meta.title = "T"; meta.duration = 100
        for track in ["/m/Album/CD1/a.mp3", "/m/Album/CD2/b.mp3"] {
            await db.upsertTrack(path: track, meta: meta, hasArtwork: false, mtime: 1)
        }
        let map = ["/m/Album": "/m/Album/cover.jpg", "/m/Album/CD2": "/m/Album/CD2/cover.jpg"]
        _ = await db.setFolderArt(map, under: ["/m"])
        let albums = await db.albums()
        #expect(albums.first?.artworkPath?.hasSuffix("cover.jpg") == true)

        // Re-applying the same walk changes nothing, so a quiet scan stays quiet.
        #expect(await db.setFolderArt(map, under: ["/m"]) == 0)
    }
}
