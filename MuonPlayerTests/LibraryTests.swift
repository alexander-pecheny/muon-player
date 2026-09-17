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

    @Test("Container path normalization rewrites stale prefixes, preserving mtime")
    func normalizeContainerPaths() async {
        let db = makeDB()
        let oldDocs = "/var/mobile/.../Application/AAAA-1111/Documents"
        let newDocs = "/var/mobile/.../Application/BBBB-2222/Documents"
        await db.upsertTrack(path: "\(oldDocs)/Artist/Album/01.mp3", meta: meta(title: "One"), hasArtwork: false, mtime: 42)
        await db.upsertTrack(path: "\(oldDocs)/root.mp3", meta: meta(title: "Root"), hasArtwork: false, mtime: 7)

        await db.normalizeContainerPaths(currentDocuments: newDocs)

        let known = await db.knownPathsWithMtime()
        #expect(known["\(newDocs)/Artist/Album/01.mp3"] == 42)  // prefix rewritten
        #expect(known["\(newDocs)/root.mp3"] == 7)              // file directly in Documents
        #expect(known["\(oldDocs)/Artist/Album/01.mp3"] == nil) // old path gone
        #expect(known.count == 2)                               // no duplicate rows

        // Idempotent: a second call with the same Documents dir changes nothing.
        await db.normalizeContainerPaths(currentDocuments: newDocs)
        #expect(await db.trackCount() == 2)
        #expect(await db.knownPathsWithMtime()["\(newDocs)/root.mp3"] == 7)
    }

    @Test("Normalization repairs the /var vs /private/var mismatch")
    func normalizePrivateVarMismatch() async {
        // The directory enumerator yields canonical /private/var paths, but stored
        // rows (and an un-canonicalized Documents dir) can be plain /var. Passing the
        // canonical dir must rewrite every row to match, or the mtime diff re-reads
        // the whole library every launch.
        let db = makeDB()
        let stored = "/var/mobile/Containers/Data/Application/CCCC-3333/Documents"
        let canonical = "/private/var/mobile/Containers/Data/Application/CCCC-3333/Documents"
        await db.upsertTrack(path: "\(stored)/Artist/01.mp3", meta: meta(title: "One"), hasArtwork: false, mtime: 11)

        await db.normalizeContainerPaths(currentDocuments: canonical)

        let known = await db.knownPathsWithMtime()
        #expect(known["\(canonical)/Artist/01.mp3"] == 11)
        #expect(known["\(stored)/Artist/01.mp3"] == nil)
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

    @Test("Album tracks group by folder, so two rips of one release don't interleave")
    func albumTracksGroupByFolder() async throws {
        let db = makeDB()
        // The same release ripped twice. Both fold into one album row (identity is
        // artist+title+year), so ordering by track number alone would interleave
        // them: 1, 1, 2, 2, 3, 3.
        for (folder, codec) in [("/m/Album [FLAC]", "flac"), ("/m/Album [MP3]", "mp3")] {
            for no in 1...3 {
                var m = meta(title: "Song \(no)", artist: "Band", album: "Album")
                m.trackNo = no
                await db.upsertTrack(path: "\(folder)/0\(no).\(codec)", meta: m, hasArtwork: false, mtime: 1)
            }
        }

        let album = try #require(await db.albums().first { $0.title == "Album" })
        let tracks = await db.tracks(inAlbum: album)
        let folders = tracks.map { $0.url.deletingLastPathComponent().lastPathComponent }

        #expect(tracks.map(\.title) == ["Song 1", "Song 2", "Song 3", "Song 1", "Song 2", "Song 3"])
        #expect(folders == ["Album [FLAC]", "Album [FLAC]", "Album [FLAC]",
                            "Album [MP3]", "Album [MP3]", "Album [MP3]"])
    }

    @Test("A play is saved at start, refreshed as it goes, and settled at the end")
    func historyFollowsThePlay() async {
        let db = makeDB()
        let id = await db.insertHistory(path: "/m/3.mp3", artist: "Queen", album: nil, title: "Innuendo",
                                        playedAt: 1_000, state: .ineligible, duration: 390, listened: 0)
        await db.updateHistory(id: id, listened: 5, position: 5, state: nil)
        var row = await db.history(limit: 1).first
        #expect(row?.listened == 5)
        #expect(row?.position == 5)
        #expect(row?.scrobbleState == .ineligible)

        await db.updateHistory(id: id, listened: 200, position: nil, state: .pending)
        row = await db.history(limit: 1).first
        #expect(row?.listened == 200)
        #expect(row?.position == nil)
        #expect(row?.scrobbleState == .pending)

        await db.deleteHistory(id: id)
        #expect(await db.history(limit: 1).isEmpty)
    }
}

/// "Repeat Artist" walks an artist's discography in release order, independent of
/// how the files are laid out on disk.
@Suite("Repeat Artist ordering")
struct AlbumArtistOrderTests {

    private func track(_ file: String, album: String, year: Int?, no: Int, disc: Int? = nil) -> Track {
        Track(url: URL(fileURLWithPath: "/m/Lumen/\(file).mp3"),
              artist: "Lumen", album: album, albumArtist: "Lumen",
              trackNo: no, discNo: disc, year: year)
    }

    @Test("Flat folder: albums play in year order, tracks stay in album order")
    func flatFolderFollowsReleaseYear() {
        // Every file in one folder — the layout that used to interleave albums by
        // track number, so track 10 of one album was followed by track 11 of another.
        let tracks = [
            track("10 Lumen - Назови мне своё имя", album: "Правда?", year: 2005, no: 10),
            track("11 Lumen - Никто не знает", album: "Правда?", year: 2005, no: 11),
            track("11 Lumen - Катёнки", album: "Три пути", year: 2007, no: 11),
            track("01 Lumen - Сид и Нэнси", album: "Три пути", year: 2007, no: 1),
            track("01 Lumen - Гореть", album: "Правда?", year: 2005, no: 1),
        ]

        let ordered = LibraryStore.orderByAlbum(tracks).map(\.title)
        #expect(ordered == [
            "01 Lumen - Гореть",
            "10 Lumen - Назови мне своё имя",
            "11 Lumen - Никто не знает",
            "01 Lumen - Сид и Нэнси",
            "11 Lumen - Катёнки",
        ])
    }

    @Test("Same year: albums ordered by title, discs before tracks")
    func sameYearAndMultiDisc() {
        let tracks = [
            track("b2", album: "B", year: 2010, no: 2, disc: 1),
            track("b1", album: "B", year: 2010, no: 1, disc: 2),
            track("a1", album: "A", year: 2010, no: 1),
        ]
        #expect(LibraryStore.orderByAlbum(tracks).map(\.title) == ["a1", "b2", "b1"])
    }

    @Test("Same title, different years: distinct albums stay separate blocks")
    func sameTitleDifferentYears() {
        // e.g. an album and its later re-recording. The DB keys albums as
        // artist+title+year, so these are two albums and must not interleave.
        let tracks = [
            track("orig2", album: "Правда?", year: 2005, no: 2),
            track("redo1", album: "Правда?", year: 2015, no: 1),
            track("orig1", album: "Правда?", year: 2005, no: 1),
            track("redo2", album: "Правда?", year: 2015, no: 2),
        ]
        #expect(LibraryStore.orderByAlbum(tracks).map(\.title) == ["orig1", "orig2", "redo1", "redo2"])
    }

    @Test("A track with a missing year stays with its album")
    func partiallyTaggedAlbumStaysTogether() {
        let tracks = [
            track("early1", album: "Early", year: 2000, no: 1),
            track("late1", album: "Late", year: 2020, no: 1),
            track("late2", album: "Late", year: nil, no: 2),
        ]
        #expect(LibraryStore.orderByAlbum(tracks).map(\.title) == ["early1", "late1", "late2"])
    }

    @Test("Albums without a year tag sort last")
    func untaggedYearSortsLast() {
        let tracks = [
            track("untagged", album: "Bootleg", year: nil, no: 1),
            track("late", album: "Late", year: 2020, no: 1),
        ]
        #expect(LibraryStore.orderByAlbum(tracks).map(\.title) == ["late", "untagged"])
    }

    private func rip(_ folder: String, _ file: String, no: Int, duration: TimeInterval) -> Track {
        Track(url: URL(fileURLWithPath: "/m/Lumen/\(folder)/\(file)"),
              title: "\(folder)-\(no)", artist: "Lumen", album: "Правда?", albumArtist: "Lumen",
              trackNo: no, year: 2005, duration: duration)
    }

    @Test("Two rips of one album play as blocks, not alternating copies")
    func ripsStayInTheirOwnFolder() {
        // The lengths differ by more than the old duplicate collapse tolerated, so
        // this is the case that used to follow track 5 of the FLAC rip with track 5
        // of the OPUS one.
        let tracks = [
            rip("Правда? OPUS", "05.opus", no: 5, duration: 370.3),
            rip("Правда? FLAC", "05.flac", no: 5, duration: 375.9),
            rip("Правда? FLAC", "06.flac", no: 6, duration: 200.1),
            rip("Правда? OPUS", "06.opus", no: 6, duration: 194.4),
        ]
        #expect(LibraryStore.orderByAlbum(tracks).map(\.title) == [
            "Правда? FLAC-5", "Правда? FLAC-6", "Правда? OPUS-5", "Правда? OPUS-6",
        ])
    }

    @Test("One album spread over one folder still orders by track")
    func singleFolderIsUnaffectedByTheFolderTier() {
        let tracks = [
            rip("Правда?", "02.flac", no: 2, duration: 100),
            rip("Правда?", "01.flac", no: 1, duration: 100),
        ]
        #expect(LibraryStore.orderByAlbum(tracks).map(\.trackNo) == [1, 2])
    }

    @Test("A folder per disc plays in disc order, whatever the folders are called")
    func discFoldersOutrankTheirNames() {
        let tracks = [
            Track(url: URL(fileURLWithPath: "/m/L/Studio/01.flac"), title: "d1t1",
                  album: "B", albumArtist: "L", trackNo: 1, discNo: 1, year: 2005),
            Track(url: URL(fileURLWithPath: "/m/L/Live Sessions/01.flac"), title: "d2t1",
                  album: "B", albumArtist: "L", trackNo: 1, discNo: 2, year: 2005),
        ]
        #expect(LibraryStore.orderByAlbum(tracks).map(\.title) == ["d1t1", "d2t1"])
    }
}

@Suite("Rip grouping")
struct RipGroupTests {

    private func track(_ folder: String, no: Int, disc: Int?) -> Track {
        Track(url: URL(fileURLWithPath: "/m/A/\(folder)/\(no).flac"),
              album: "X", albumArtist: "A", trackNo: no, discNo: disc)
    }

    private func groups(_ tracks: [Track]) -> [(folder: String, tracks: [Track])] {
        LibraryStore.ripGroups(tracks) { $0.url.deletingLastPathComponent().lastPathComponent }
    }

    @Test("Two rips of one album are two groups")
    func ripsSplit() {
        let tracks = [track("FLAC", no: 1, disc: nil), track("FLAC", no: 2, disc: nil),
                      track("MP3", no: 1, disc: nil), track("MP3", no: 2, disc: nil)]
        #expect(groups(tracks).map(\.folder) == ["FLAC", "MP3"])
    }

    @Test("A folder per disc is one album, not one rip per disc")
    func discFoldersStayWhole() {
        let tracks = [track("CD1", no: 1, disc: 1), track("CD1", no: 2, disc: 1),
                      track("CD2", no: 1, disc: 2), track("CD2", no: 2, disc: 2)]
        let result = groups(tracks)
        #expect(result.count == 1)
        #expect(result.first?.tracks.count == 4)
    }

    @Test("Both rips of a two-disc album still split by folder")
    func discsWithinRipsSplit() {
        let tracks = [track("FLAC", no: 1, disc: 1), track("FLAC", no: 1, disc: 2),
                      track("MP3", no: 1, disc: 1), track("MP3", no: 1, disc: 2)]
        #expect(groups(tracks).count == 2)
    }
}
