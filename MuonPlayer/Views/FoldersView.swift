import SwiftUI

/// A plain file-tree browser of the library folder (On My iPhone → MuonPlayer).
/// Folders drill in; audio files play with their folder as the context.
struct FoldersView: View {
    /// nil at the root — resolves to the library root folder.
    var directory: URL? = nil

    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var pendingDelete: PendingDelete?
    @State private var subfolders: [URL] = []
    @State private var trackFiles: [Track] = []
    @State private var loaded = false
    @State private var query = ""

    private var dir: URL { directory ?? library.rootURL }

    private var shownFolders: [URL] {
        guard !query.isEmpty else { return subfolders }
        return subfolders.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(query) }
    }
    private var shownTracks: [Track] {
        guard !query.isEmpty else { return trackFiles }
        return trackFiles.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if !shownFolders.isEmpty {
                Section {
                    ForEach(shownFolders, id: \.path) { folder in
                        NavigationLink(value: FolderRef(url: folder)) {
                            Label(folder.lastPathComponent, systemImage: "folder")
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = PendingDelete(
                                    title: "Delete “\(folder.lastPathComponent)”?",
                                    message: "The folder and everything inside it will be removed from this iPhone."
                                ) {
                                    await library.delete(folder: folder)
                                    await load()
                                }
                            } label: {
                                Label("Delete Folder", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if !shownTracks.isEmpty {
                Section {
                    ForEach(shownTracks) { track in
                        TrackRow(track: track, isCurrent: player.currentTrack?.url == track.url)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(track: track, context: trackFiles) }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    player.enqueue(track, context: trackFiles)
                                } label: { Label("Enqueue", systemImage: "text.append") }
                                .tint(player.accentColor)
                            }
                            .contextMenu {
                                Button {
                                    player.enqueue(track, context: trackFiles)
                                } label: { Label("Add Track to Queue", systemImage: "text.append") }
                            }
                    }
                }
            }
        }
        .listStyle(.plain)
        .deleteConfirmation($pendingDelete)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter this folder")
        .navigationTitle(directory == nil ? "Folders" : dir.lastPathComponent)
        .navigationBarTitleDisplayMode(directory == nil ? .large : .inline)
        .overlay {
            if loaded, subfolders.isEmpty, trackFiles.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .task(id: dir.path) { await load() }
    }

    private func load() async {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        subfolders = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        trackFiles = await library.folderTracks(in: dir)
        loaded = true
    }
}
