import SwiftUI

/// Non-destructive tag editor. Edits are stored as overrides in the library DB
/// (the source audio files are never modified). Reachable from the album menu
/// (album-wide fields) and the track menu (per-track fields).
struct TagEditView: View {
    enum Scope {
        case track(Track)
        case album(Album)
    }

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
    @State private var initial: [String: String] = [:]
    @State private var saving = false
    @State private var errorMessage: String?

    private var isTrack: Bool { if case .track = scope { return true }; return false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isTrack {
                        field("Title", text: $title)
                        field("Track No.", text: $trackNo, keyboard: .numberPad)
                    } else {
                        field("Album", text: $album)
                    }
                    field("Artist", text: $artist)
                    field("Album Artist", text: $albumArtist)
                    field("Composer", text: $composer)
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
            .onAppear(perform: load)
            .alert("Couldn't Save Tags", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        LabeledContent(label) {
            TextField(label, text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .foregroundStyle(.primary)
        }
    }

    private func load() {
        switch scope {
        case .track(let t):
            title = t.title
            artist = t.artist ?? ""
            albumArtist = t.albumArtist ?? ""
            trackNo = t.trackNo.map(String.init) ?? ""
            composer = t.composer ?? ""
        case .album(let a):
            album = a.title
            albumArtist = a.artist
            artist = a.artist
            composer = ""
        }
        initial = ["title": title, "artist": artist, "album": album,
                   "albumArtist": albumArtist, "trackNo": trackNo, "composer": composer]
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
