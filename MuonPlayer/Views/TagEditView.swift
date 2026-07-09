import SwiftUI

/// Non-destructive tag editor. Edits are written into the source files' tags
/// (the audio is never re-encoded). Reachable from the album menu (album-wide
/// fields) and the track menu (per-track fields).
struct TagEditView: View {
    typealias Scope = TagEditModel.Scope

    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var model: TagEditModel

    init(scope: Scope) {
        _model = State(initialValue: TagEditModel(scope: scope))
    }

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    if model.isTrack {
                        field("Title", "title", text: $model.title)
                        field("Track No.", "trackNo", text: $model.trackNo, keyboard: .numberPad)
                    } else {
                        field("Album", "album", text: $model.album)
                    }
                    field("Artist", "artist", text: $model.artist)
                    field("Album Artist", "albumArtist", text: $model.albumArtist)
                    field("Composer", "composer", text: $model.composer)
                    field("Year", "year", text: $model.year, keyboard: .numberPad)
                } footer: {
                    Text(model.isTrack
                         ? "Changes are written into this track's file (audio is untouched)."
                         : "Changes are written into every track's file in this album (audio is untouched).")
                }
            }
            .navigationTitle("Edit Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await model.save(to: library) { dismiss() } }
                    }
                    .disabled(model.saving)
                }
            }
            .task { await model.load(from: library) }
            .alert("Couldn't Save Tags", isPresented: .constant(model.errorMessage != nil)) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    /// A labeled text field that shows a dot when its value differs from what was
    /// loaded (i.e. it will be overwritten on Save).
    private func field(_ label: String, _ key: String, text: Binding<String>,
                       keyboard: UIKeyboardType = .default) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                if model.isChanged(key) {
                    Circle().fill(player.accentColor).frame(width: 7, height: 7)
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
}
