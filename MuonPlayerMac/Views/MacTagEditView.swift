import SwiftUI

struct MacTagEditView: View {
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

        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Tags").font(.headline).padding([.top, .horizontal], 16)

            Form {
                if model.isTrack {
                    field("Title", "title", text: $model.title)
                    field("Track No.", "trackNo", text: $model.trackNo)
                } else {
                    field("Album", "album", text: $model.album)
                }
                field("Artist", "artist", text: $model.artist)
                field("Album Artist", "albumArtist", text: $model.albumArtist)
                field("Composer", "composer", text: $model.composer)
                field("Year", "year", text: $model.year)
            }
            .formStyle(.grouped)

            Text(model.isTrack
                 ? "Changes are written into this track's file (audio is untouched)."
                 : "Changes are written into every track's file in this album (audio is untouched).")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            Divider().padding(.top, 12)

            HStack {
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { if await model.save(to: library) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.saving)
            }
            .padding(16)
        }
        .frame(width: 440)
        .task { await model.load(from: library) }
    }

    /// A dot marks a field whose value differs from what was loaded — those are
    /// the only ones written on Save.
    private func field(_ label: String, _ key: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, text: text).labelsHidden()
                if model.isChanged(key) {
                    Circle().fill(player.accentColor).frame(width: 7, height: 7)
                }
            }
        }
    }
}
