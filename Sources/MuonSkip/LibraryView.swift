import SwiftUI
import MuonCore

/// The Android library: pick a folder, index it, browse the albums that came out,
/// play one. Indexing, tag reading, album grouping and playback are all the shared
/// core — this only shows what it produced.
struct LibraryView: View {
    @State var picking = false
    @State var albums: [AlbumItem] = []
    @State var status = "No folder chosen"
    @State var root = ""

    var body: some View {
        NavigationStack {
            Group {
                if albums.isEmpty {
                    emptyState
                } else {
                    albumList
                }
            }
            .navigationTitle("Library")
            .task { await restore() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Folder") { picking = true }
                }
            }
            .sheet(isPresented: $picking) {
                FolderPicker { path in
                    picking = false
                    Task { await open(path) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(status).foregroundStyle(.secondary)
            Button("Choose a folder") { picking = true }
        }
    }

    private var albumList: some View {
        List {
            Section(status) {
                ForEach(albums) { album in
                    NavigationLink(value: album.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                            Text("\(album.artist) · \(album.trackCount) tracks")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: Int.self) { id in
            AlbumView(albumID: id, albumTitle: albums.first { $0.id == id }?.title ?? "")
        }
    }

    private func restore() async {
        #if os(Android)
        await MuonCore.library.restore()
        albums = MuonCore.library.albumRows
        status = MuonCore.library.scanStatus
        #endif
    }

    private func open(_ path: String) async {
        root = path
        status = "Scanning \(path)…"
        albums = []
        #if os(Android)
        await MuonCore.library.openFolder(path)
        albums = MuonCore.library.albumRows
        status = MuonCore.library.scanStatus
        #endif
    }
}

/// Walks real directories rather than using the Storage Access Framework: SAF
/// returns content:// URLs, and the shared FileScanner walks a filesystem.
struct FolderPicker: View {
    let onPick: (String) -> Void
    @State var path = "/storage/emulated/0/Music"
    @State var entries: [String] = []
    @State var probe = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Current") {
                    Text(path).font(.footnote)
                    Text(probe).font(.footnote).foregroundStyle(.secondary)
                    Button("Index this folder") { onPick(path) }
                    Button("Diagnose") { Task { await diagnose() } }
                    if path != "/" {
                        Button("Up") { navigate(to: (path as NSString).deletingLastPathComponent) }
                    }
                }
                Section("Shortcuts") {
                    Button("Shared music") { navigate(to: "/storage/emulated/0/Music") }
                    Button("App files") { navigate(to: NSHomeDirectory() + "/files") }
                }
                Section("Folders") {
                    ForEach(entries, id: \.self) { entry in
                        Button((entry as NSString).lastPathComponent) { navigate(to: entry) }
                    }
                }
            }
            .navigationTitle("Choose folder")
        }
        .task { reload() }
    }

    private func navigate(to newPath: String) {
        path = newPath
        reload()
    }

    private func reload() {
        #if os(Android)
        entries = MuonCore.library.subfolders(of: path)
        probe = MuonCore.library.probe(path)
        #endif
    }

    private func diagnose() async {
        #if os(Android)
        probe = await MuonCore.library.diagnose(path)
        #endif
    }
}
