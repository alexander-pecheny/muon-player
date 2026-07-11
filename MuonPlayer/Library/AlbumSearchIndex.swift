import Foundation

/// An album with its title and artist pre-folded for matching, so a keystroke
/// costs a plain substring search rather than an ICU collation over the whole
/// library.
struct AlbumSearchEntry: Sendable {
    let album: Album
    let foldedTitle: String
    let foldedArtist: String

    init(_ album: Album) {
        self.album = album
        self.foldedTitle = Self.fold(album.title)
        self.foldedArtist = Self.fold(album.artist)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Artists and albums matching `query`, in display order. Runs off the main
    /// actor — the caller hands it a snapshot of the index.
    static func match(_ query: String, in index: [AlbumSearchEntry]) -> ([ArtistResult], [Album]) {
        let q = fold(query)
        guard !q.isEmpty else { return ([], []) }

        var albums: [Album] = []
        var artistArtwork: [String: String?] = [:]
        for entry in index {
            let artistHit = entry.foldedArtist.contains(q)
            if artistHit || entry.foldedTitle.contains(q) { albums.append(entry.album) }
            if artistHit {
                // First album of the artist that has a cover wins.
                if artistArtwork[entry.album.artist] == nil || artistArtwork[entry.album.artist]! == nil {
                    artistArtwork[entry.album.artist] = entry.album.artworkPath
                }
            }
        }

        let artists = artistArtwork.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ArtistResult(name: $0, artworkPath: artistArtwork[$0] ?? nil) }

        return (artists, albums)
    }
}
