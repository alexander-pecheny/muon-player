import SwiftUI

/// The newest additions to the library. Cross-library search lives in the
/// always-visible toolbar field (see `MacRootView`), not here.
struct MacHomeView: View {
    @Environment(LibraryStore.self) private var library
    @State private var recent: [Album] = []

    var body: some View {
        Group {
            if recent.isEmpty {
                ContentUnavailableView("Library Is Empty", systemImage: "music.note.house",
                                       description: Text("Add a folder from the Library menu."))
            } else {
                AlbumGrid(albums: recent)
            }
        }
        .navigationTitle("Home")
        .task(id: library.version) { recent = await library.recentAlbums() }
    }
}
