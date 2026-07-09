import Observation

/// Backs the tag editors on both platforms: loads the current values, tracks
/// which fields the user changed, and writes only those back into the files.
@MainActor
@Observable
final class TagEditModel {
    enum Scope {
        case track(Track)
        case album(Album)
    }

    /// Shown in a field when the tracks in an album disagree on its value. Left
    /// unchanged, it is never written back (see `edits()`).
    static let multipleValues = "(Multiple Values)"

    let scope: Scope

    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var trackNo = ""
    var composer = ""
    var year = ""

    private(set) var loaded = false
    var saving = false
    var errorMessage: String?

    private var initial: [String: String] = [:]

    init(scope: Scope) { self.scope = scope }

    var isTrack: Bool { if case .track = scope { return true }; return false }

    /// Whether `field` differs from what was loaded (i.e. it will be written).
    func isChanged(_ key: String) -> Bool {
        loaded && value(for: key) != (initial[key] ?? "")
    }

    private func value(for key: String) -> String {
        switch key {
        case "title": return title
        case "artist": return artist
        case "album": return album
        case "albumArtist": return albumArtist
        case "trackNo": return trackNo
        case "composer": return composer
        case "year": return year
        default: return ""
        }
    }

    func load(from library: LibraryStore) async {
        switch scope {
        case .track(let t):
            title = t.title
            artist = t.artist ?? ""
            albumArtist = t.albumArtist ?? ""
            trackNo = t.trackNo.map(String.init) ?? ""
            composer = t.composer ?? ""
            year = t.year.map(String.init) ?? ""
        case .album(let a):
            album = a.title
            albumArtist = a.artist
            // Per-track fields may disagree across the album — show a placeholder
            // rather than duplicating the album-artist into the Artist field.
            let tracks = await library.tracks(in: a)
            artist = uniform(tracks.map(\.artist)) ?? a.artist
            composer = uniform(tracks.map(\.composer)) ?? ""
            year = uniform(tracks.map { $0.year.map(String.init) }) ?? (a.year.map(String.init) ?? "")
        }
        initial = ["title": title, "artist": artist, "album": album,
                   "albumArtist": albumArtist, "trackNo": trackNo,
                   "composer": composer, "year": year]
        loaded = true
    }

    /// Returns true when the write succeeded; otherwise `errorMessage` is set.
    func save(to library: LibraryStore) async -> Bool {
        saving = true
        defer { saving = false }
        let e = edits()
        let error: String?
        switch scope {
        case .track(let t): error = await library.applyTrackEdits(e, to: t)
        case .album(let a): error = await library.applyAlbumEdits(e, to: a)
        }
        errorMessage = error
        return error == nil
    }

    /// The single shared value across `values`, "(Multiple Values)" if they
    /// disagree, or nil if none are set.
    private func uniform(_ values: [String?]) -> String? {
        let set = Set(values.map { ($0 ?? "").trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        if set.isEmpty { return nil }
        return set.count == 1 ? set.first : Self.multipleValues
    }

    /// Build TagEdits containing only fields the user actually changed.
    private func edits() -> TagEdits {
        func changed(_ key: String) -> String? {
            isChanged(key) ? value(for: key) : nil
        }
        var e = TagEdits()
        e.title = isTrack ? changed("title") : nil
        e.album = isTrack ? nil : changed("album")
        e.artist = changed("artist")
        e.albumArtist = changed("albumArtist")
        e.composer = changed("composer")
        if isTrack, let raw = changed("trackNo") {
            e.trackNo = Int(raw.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        if let raw = changed("year"),
           let y = Int(raw.trimmingCharacters(in: .whitespaces)), y > 0 {
            e.year = y
        }
        return e
    }
}
