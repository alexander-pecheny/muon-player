import Testing
import Foundation
@testable import MuonPlayer

@Suite("Album Search Index")
struct AlbumSearchIndexTests {

    private func album(_ title: String, _ artist: String, artwork: String? = nil) -> Album {
        Album(title: title, artist: artist, trackCount: 10, year: 2001, artworkPath: artwork)
    }

    private var index: [AlbumSearchEntry] {
        [album("Kid A", "Radiohead", artwork: nil),
         album("In Rainbows", "Radiohead", artwork: "/art.jpg"),
         album("Björk's Best", "Björk"),
         album("Loveless", "My Bloody Valentine")].map(AlbumSearchEntry.init)
    }

    @Test("Matches title and artist, case- and diacritic-insensitively")
    func matching() {
        let (artists, albums) = AlbumSearchEntry.match("bjork", in: index)
        #expect(artists.map(\.name) == ["Björk"])
        #expect(albums.map(\.title) == ["Björk's Best"])

        let (_, byTitle) = AlbumSearchEntry.match("LOVE", in: index)
        #expect(byTitle.map(\.title) == ["Loveless"])
    }

    @Test("An artist takes the artwork of its first album that has any")
    func artistArtwork() {
        let (artists, albums) = AlbumSearchEntry.match("radiohead", in: index)
        #expect(artists.map(\.name) == ["Radiohead"])
        #expect(artists.first?.artworkPath == "/art.jpg")
        #expect(albums.count == 2)
    }

    @Test("An empty query matches nothing")
    func emptyQuery() {
        let (artists, albums) = AlbumSearchEntry.match("  ", in: index)
        #expect(artists.isEmpty)
        #expect(albums.isEmpty)
    }
}
