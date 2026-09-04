import SwiftUI

/// A destructive action waiting on the user's answer.
///
/// The phone has no Trash, so the question is the only safety there is — which is why
/// deleting anything from the library goes through one of these rather than a swipe
/// that acts immediately.
struct PendingDelete: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let perform: () async -> Void
}

extension View {
    /// Ask before running `pending`, and clear it either way.
    func deleteConfirmation(_ pending: Binding<PendingDelete?>) -> some View {
        confirmationDialog(
            pending.wrappedValue?.title ?? "",
            isPresented: Binding(get: { pending.wrappedValue != nil },
                                 set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { request in
            Button("Delete", role: .destructive) {
                Task { await request.perform() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}

extension LibraryStore {
    /// Every track filed under an album-artist, for a delete that takes the whole
    /// discography.
    func tracks(byArtist artist: String) async -> [Track] {
        var all: [Track] = []
        for album in albums where album.artist == artist {
            all.append(contentsOf: await tracks(in: album))
        }
        return all
    }
}
