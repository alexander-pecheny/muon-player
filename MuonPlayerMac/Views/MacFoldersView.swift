import SwiftUI

/// A file-tree browser. At the top level it lists the library's root folders;
/// below that, the real directory contents.
struct MacFoldersView: View {
    /// nil at the top level, where the listing is the set of library roots.
    var directory: URL? = nil

    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @State private var subfolders: [URL] = []
    @State private var trackFiles: [Track] = []
    @State private var loaded = false
    @State private var query = ""

    private var isRoot: Bool { directory == nil }

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
                            Label(folder.lastPathComponent,
                                  systemImage: isRoot ? "folder.badge.gearshape" : "folder")
                        }
                        .contextMenu { RevealInFinderButton(url: folder) }
                    }
                }
            }
            if !shownTracks.isEmpty {
                Section {
                    ForEach(shownTracks) { track in
                        MacTrackRow(track: track, context: trackFiles, showFolder: false)
                    }
                }
            }
        }
        .listStyle(.inset)
        .searchable(text: $query, prompt: "Filter this folder")
        .navigationTitle(directory?.lastPathComponent ?? "Folders")
        .overlay {
            if loaded, subfolders.isEmpty, trackFiles.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .task(id: directory?.path ?? rootsKey) { await load() }
    }

    /// Re-run the top-level listing when the set of library roots changes.
    private var rootsKey: String { library.roots.map(\.path).joined(separator: "\u{1}") }

    private func load() async {
        guard let dir = directory else {
            subfolders = library.roots.map(\.url)
            trackFiles = []
            loaded = true
            return
        }
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
