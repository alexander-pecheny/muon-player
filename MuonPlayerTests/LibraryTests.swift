import Testing
import Foundation
@testable import MuonPlayer

/// Exercises the SQLite library: Unicode/case-insensitive search and the
/// scrobble retry queue.
@Suite("Library Database Tests")
struct LibraryTests {

    private func makeDB() -> Database {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("muon-test-\(UUID().uuidString).sqlite").path
        return Database(path: path)
    }

    private func meta(title: String, artist: String? = nil, album: String? = nil) -> TrackMetadata {
        var m = TrackMetadata()
        m.title = title; m.artist = artist; m.album = album; m.duration = 200
        return m
    }

    @Test("Search is case-insensitive (ASCII)")
    func caseInsensitiveAscii() async {
        let db = makeDB()
        await db.upsertTrack(path: "/m/1.mp3", meta: meta(title: "Bohemian Rhapsody", artist: "Queen"), hasArtwork: false, mtime: 1)
        #expect(await db.search("bohemian").count == 1)
        #expect(await db.search("BOHEMIAN").count == 1)
        #expect(await db.search("queen").count == 1)
        #expect(await db.search("QuEeN").count == 1)
    }

    @Test("Search works for Cyrillic, case-insensitively")
    func cyrillic() async {
        let db = makeDB()
        await db.upsertTrack(path: "/m/2.mp3", meta: meta(title: "Привет Мир", artist: "Кино"), hasArtwork: false, mtime: 1)
        #expect(await db.search("привет").count == 1)   // lowercase query
        #expect(await db.search("ПРИВЕТ").count == 1)   // uppercase query
        #expect(await db.search("кино").count == 1)
        #expect(await db.search("мир").count == 1)
    }

    @Test("Search works for CJK")
    func cjk() async {
        let db = makeDB()
        await db.upsertTrack(path: "/m/3.mp3", meta: meta(title: "東京は夜の七時", artist: "ピチカート・ファイヴ"), hasArtwork: false, mtime: 1)
        #expect(await db.search("東京").count == 1)
    }

    @Test("Search is diacritic-insensitive")
    func diacritics() async {
        let db = makeDB()
        await db.upsertTrack(path: "/m/4.mp3", meta: meta(title: "Jóga", artist: "Björk"), hasArtwork: false, mtime: 1)
        #expect(await db.search("bjork").count == 1)    // no diacritic
        #expect(await db.search("björk").count == 1)
        #expect(await db.search("BJÖRK").count == 1)
    }

    @Test("Search matches word prefixes for instant results")
    func prefix() async {
        let db = makeDB()
        await db.upsertTrack(path: "/m/5.mp3", meta: meta(title: "Paranoid Android", artist: "Radiohead"), hasArtwork: false, mtime: 1)
        #expect(await db.search("para").count == 1)
        #expect(await db.search("radio").count == 1)
    }

    @Test("Upsert dedupes by path")
    func upsertDedupe() async {
        let db = makeDB()
        await db.upsertTrack(path: "/m/6.mp3", meta: meta(title: "Old Title"), hasArtwork: false, mtime: 1)
        await db.upsertTrack(path: "/m/6.mp3", meta: meta(title: "New Title"), hasArtwork: false, mtime: 2)
        #expect(await db.trackCount() == 1)
        #expect(await db.search("new").count == 1)
        #expect(await db.search("old").count == 0)
    }

    @Test("Scrobble queue: insert → pending → mark scrobbled")
    func scrobbleQueue() async {
        let db = makeDB()
        #expect(await db.pendingScrobbleCount() == 0)
        await db.insertScrobble(artist: "A", album: "B", title: "C", timestamp: 1000, duration: 200)
        await db.insertScrobble(artist: "D", album: nil, title: "E", timestamp: 1001, duration: 180)
        #expect(await db.pendingScrobbleCount() == 2)

        let pending = await db.pendingScrobbles()
        #expect(pending.count == 2)
        #expect(pending.first?.timestamp == 1000) // ordered oldest first

        await db.markScrobbled(id: pending[0].id)
        #expect(await db.pendingScrobbleCount() == 1)
        await db.markScrobbled(id: pending[1].id)
        #expect(await db.pendingScrobbleCount() == 0)
    }
}
