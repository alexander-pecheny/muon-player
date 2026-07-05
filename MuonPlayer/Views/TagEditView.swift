import SwiftUI

/// Non-destructive tag editor. Edits are written into the source files' tags
/// (the audio is never re-encoded). Reachable from the album menu (album-wide
/// fields) and the track menu (per-track fields).
struct TagEditView: View {
    enum Scope {
        case track(Track)
        case album(Album)
    }

    /// Shown in a field when the tracks in an album disagree on its value. Left
    /// unchanged, it is never written back (see `edits()`).
    static let multipleValues = "(Multiple Values)"

    let scope: Scope
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    // Field state + the initial values, so only changed fields are written.
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var trackNo = ""
    @State private var composer = ""
    @State private var year = ""
    @State private var initial: [String: String] = [:]
    @State private var loaded = false
    @State private var saving = false
    @State private var errorMessage: String?

    private var isTrack: Bool { if case .track = scope { return true }; return false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isTrack {
                        field("Title", "title", text: $title)
                        field("Track No.", "trackNo", text: $trackNo, keyboard: .numberPad)
                    } else {
                        field("Album", "album", text: $album)
                    }
                    field("Artist", "artist", text: $artist)
                    field("Album Artist", "albumArtist", text: $albumArtist)
                    field("Composer", "composer", text: $composer)
                    field("Year", "year", text: $year, keyboard: .numberPad)
                } footer: {
                    Text(isTrack
                         ? "Changes are written into this track's file (audio is untouched)."
                         : "Changes are written into every track's file in this album (audio is untouched).")
                }
            }
            .navigationTitle("Edit Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                }
            }
            .task { await load() }
            .alert("Couldn't Save Tags", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    /// A labeled text field that shows a dot when its value differs from what was
    /// loaded (i.e. it will be overwritten on Save).
    private func field(_ label: String, _ key: String, text: Binding<String>,
                       keyboard: UIKeyboardType = .default) -> some View {
        let changed = loaded && text.wrappedValue != (initial[key] ?? "")
        return LabeledContent(label) {
            HStack(spacing: 6) {
                if changed {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                        .transition(.scale)
                }
                TextField(label, text: text)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(keyboard)
                    .autocorrectionDisabled()
                    .foregroundStyle(.primary)
            }
        }
    }

    private func load() async {
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
            artist = uniform(tracks.map { $0.artist }) ?? a.artist
            composer = uniform(tracks.map { $0.composer }) ?? ""
            year = uniform(tracks.map { $0.year.map(String.init) }) ?? (a.year.map(String.init) ?? "")
        }
        initial = ["title": title, "artist": artist, "album": album,
                   "albumArtist": albumArtist, "trackNo": trackNo,
                   "composer": composer, "year": year]
        loaded = true
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
        func changed(_ key: String, _ value: String) -> String? {
            value == (initial[key] ?? "") ? nil : value
        }
        var e = TagEdits()
        e.title = isTrack ? changed("title", title) : nil
        e.album = isTrack ? nil : changed("album", album)
        e.artist = changed("artist", artist)
        e.albumArtist = changed("albumArtist", albumArtist)
        e.composer = changed("composer", composer)
        if isTrack, let raw = changed("trackNo", trackNo) {
            e.trackNo = Int(raw.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        if let raw = changed("year", year),
           let y = Int(raw.trimmingCharacters(in: .whitespaces)), y > 0 {
            e.year = y
        }
        return e
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let e = edits()
        let error: String?
        switch scope {
        case .track(let t): error = await library.applyTrackEdits(e, to: t)
        case .album(let a): error = await library.applyAlbumEdits(e, to: a)
        }
        if let error { errorMessage = error } else { dismiss() }
    }
}
